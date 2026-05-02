//
//  SessionManager.swift
//  AgentRunner
//
//  Domain-layer aggregator. Consumes source-agnostic NetworkFlowEvents,
//  groups bytes by (PID, provider), runs the per-session state machine,
//  and publishes aggregate state to the UI on a 2s self-tick.
//
//  Pre-2.0 versions consumed nettop's CSV snapshot boundary as the
//  publish trigger. The new push model has no fixed cadence, so this
//  class owns its own DispatchSourceTimer for periodic publish + GC.
//

import Foundation

/// Marked `@unchecked Sendable` because all mutable state is confined
/// to `queue` (a serial DispatchQueue). Closures captured by handlers
/// also use `[weak self]` — see `start()` and `handle(event:)`.
final class SessionManager: @unchecked Sendable {

    private let registry: ProviderRegistry
    private let flowSource: NetworkFlowSource

    private(set) var sessions: [SessionKey: Session] = [:]

    /// Tick window — must match the rate window the state machine
    /// thresholds were calibrated against (5000 B/s outbound burst).
    private let tickInterval: TimeInterval = 2.0

    /// Per-flow latest cumulative bytes since the last tick. Keyed by
    /// flowID (srcref from ntstat) so 5-tuple reuse never doubles up.
    private struct FlowSlot {
        let session: SessionKey
        let processName: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }
    private var liveFlows: [UInt64: FlowSlot] = [:]

    private let queue = DispatchQueue(label: "ai.ww-w.AgentRunner.session")
    private var tickTimer: DispatchSourceTimer?

    /// Aggregate state changes are published on the main queue.
    var onAggregateChange: ((AggregateState) -> Void)?

    /// Called once if the underlying flow source dies after start.
    /// AppDelegate uses this to switch to an "unavailable" menu.
    var onSourceFailure: ((Error) -> Void)?

    private var lastAggregate: AggregateState =
        AggregateState(state: .idle, bytesInRate: 0, sessionCount: 0)

    init(registry: ProviderRegistry, flowSource: NetworkFlowSource) {
        self.registry = registry
        self.flowSource = flowSource
    }

    // MARK: - Lifecycle

    /// Start consuming events. Throws if the underlying flow source
    /// can't initialize — caller (AppDelegate) handles by transitioning
    /// to an unavailable UI state.
    func start() throws {
        try flowSource.start(
            eventHandler: { [weak self] event in
                self?.handle(event: event)
            },
            failureHandler: { [weak self] error in
                guard let self else { return }
                DispatchQueue.main.async { self.onSourceFailure?(error) }
            }
        )

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickInterval,
                       repeating: tickInterval,
                       leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let agg = self.runTick(now: Date())
            if agg != self.lastAggregate {
                self.lastAggregate = agg
                DispatchQueue.main.async { [weak self] in
                    self?.onAggregateChange?(agg)
                }
            }
        }
        tickTimer = timer
        timer.resume()
    }

    func stop() {
        tickTimer?.cancel()
        tickTimer = nil
        flowSource.stop()
    }

    // MARK: - Event ingest

    /// Thread-safe entry point — flow source handler may run on any queue.
    func handle(event: NetworkFlowEvent) {
        queue.async { [weak self] in
            self?.handleInternal(event)
        }
    }

    internal func handleInternal(_ event: NetworkFlowEvent) {
        switch event.kind {
        case .flowStarted(let desc):
            ingestStart(desc)
        case .flowUpdated(let id, let bIn, let bOut):
            ingestUpdate(flowID: id, bytesIn: bIn, bytesOut: bOut)
        case .flowEnded(let id):
            liveFlows.removeValue(forKey: id)
        }
    }

    private func ingestStart(_ desc: FlowDescriptor) {
        // Layer 1: blocklist (browsers / chat clients that hit LLM IPs
        // but aren't AI agents themselves).
        if Blocklist.isBlocked(desc.processName) { return }
        // Layer 2: provider classification by remote IP.
        guard let provider = registry.providerName(forIP: desc.remote.host) else {
            return
        }
        let session = SessionKey(pid: desc.pid, provider: provider)
        liveFlows[desc.flowID] = FlowSlot(
            session: session,
            processName: desc.processName,
            bytesIn: 0,
            bytesOut: 0
        )
    }

    private func ingestUpdate(flowID: UInt64, bytesIn: UInt64, bytesOut: UInt64) {
        guard var slot = liveFlows[flowID] else { return }
        // Cumulative counters: monotonically grow within a flow lifetime.
        slot.bytesIn = max(slot.bytesIn, bytesIn)
        slot.bytesOut = max(slot.bytesOut, bytesOut)
        liveFlows[flowID] = slot
    }

    // MARK: - Tick (publish + GC)

    /// Synchronous, deterministic. Consolidates flow byte sums into
    /// Sessions, runs the state machine, returns the new aggregate.
    @discardableResult
    internal func runTick(now: Date) -> AggregateState {
        // 1. Flow → session aggregation. A single (PID, provider) pair
        //    can have multiple concurrent flows (parallel HTTP/2 streams,
        //    OpenAI's separate conn for tool calls, etc.).
        var perSession: [SessionKey: (name: String, bIn: UInt64, bOut: UInt64)] = [:]
        for (_, slot) in liveFlows {
            if let existing = perSession[slot.session] {
                perSession[slot.session] = (existing.name,
                                            existing.bIn + slot.bytesIn,
                                            existing.bOut + slot.bytesOut)
            } else {
                perSession[slot.session] = (slot.processName,
                                            slot.bytesIn,
                                            slot.bytesOut)
            }
        }
        for (key, sample) in perSession {
            let session = sessions[key] ?? Session(key: key, processName: sample.name)
            session.ingest(totalBytesIn: sample.bIn,
                           totalBytesOut: sample.bOut, at: now)
            sessions[key] = session
        }

        // 2. Tick every session (handles state transitions on inactivity).
        for session in sessions.values {
            session.tick(now: now)
        }

        // 3. GC stale sessions.
        sessions = sessions.filter { !$0.value.isStale(now: now) }

        return computeAggregate()
    }

    private func computeAggregate() -> AggregateState {
        guard !sessions.isEmpty else {
            return AggregateState(state: .idle, bytesInRate: 0, sessionCount: 0)
        }
        let maxState = sessions.values.map { $0.state }.max() ?? .idle
        let maxRate = sessions.values
            .filter { $0.state == maxState && maxState == .running }
            .map { $0.bytesInRate }
            .max() ?? 0
        return AggregateState(state: maxState,
                              bytesInRate: maxRate,
                              sessionCount: sessions.count)
    }

    // MARK: - UI snapshot

    /// Race-free snapshot for the popover. Copies into value types
    /// inside the queue so the main thread never reads `Session` refs.
    func sessionSnapshot() -> [SessionSnapshot] {
        var snap: [SessionSnapshot] = []
        queue.sync {
            snap = sessions.values.map { s in
                SessionSnapshot(
                    pid: s.key.pid,
                    provider: s.key.provider,
                    processName: s.processName,
                    state: s.state,
                    bytesIn: s.bytesIn,
                    bytesOut: s.bytesOut,
                    bytesInRate: s.bytesInRate,
                    bytesOutRate: s.bytesOutRate
                )
            }
        }
        return snap
    }
}

// MARK: - Value types exposed to the UI layer

struct SessionSnapshot {
    let pid: Int32
    let provider: String
    let processName: String
    let state: SessionState
    let bytesIn: UInt64
    let bytesOut: UInt64
    let bytesInRate: Double
    let bytesOutRate: Double
}

struct AggregateState: Equatable {
    let state: SessionState
    let bytesInRate: Double
    let sessionCount: Int
}
