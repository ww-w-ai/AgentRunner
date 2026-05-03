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

    /// Flows whose process passes the blocklist but whose remote IP
    /// wasn't yet in `ProviderRegistry` at flowStarted time. Held so a
    /// later registry refresh (10-min cycle, NWPathMonitor, system
    /// wake) can rescue them. Without this, a flow opened before its
    /// host's DNS lookup completes is permanently invisible — the
    /// regression that v1.0.11's IP-accumulation fix addressed under
    /// the old nettop pipeline. Aged out after `pendingMaxAge` so we
    /// don't grow unbounded on a busy machine.
    private struct PendingFlow {
        let descriptor: FlowDescriptor
        let firstSeen: Date
        var lastBytesIn: UInt64
        var lastBytesOut: UInt64
    }
    private var pendingFlows: [UInt64: PendingFlow] = [:]
    private let pendingMaxAge: TimeInterval = 5 * 60

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

    /// PENDING 로그 노이즈 필터. AI 트래픽일 가능성이 0인 시스템 서비스 / 메신저는
    /// PENDING 자체는 등록하되 (혹시 모를 IP 매칭 기회를 위해) 로그는 안 남긴다.
    /// 진단 시점에 정말 봐야 할 후보 flow만 콘솔에 노출하기 위함.
    private static let pendingLogNoisePatterns: [String] = [
        "rapportd", "identityservicesd", "IPNExtension", "mDNSResponder",
        "trustd", "apsd", "sharingd", "nsurlsessiond", "cloudd", "bird",
        "KakaoTalk", "Telegram", "WhatsApp",
        // Apple 개발 도구 — Akamai/Apple 다운로드 트래픽이 전부.
        // 향후 Apple Intelligence cloud endpoint 추가 시 재검토.
        "Xcode", "CrossEXService",
    ]
    private static func isLogWorthyPending(_ desc: FlowDescriptor) -> Bool {
        let lower = desc.processName.lowercased()
        return !pendingLogNoisePatterns.contains { lower.contains($0.lowercased()) }
    }

    /// Layer 0 필터. Provider IP는 모두 public이므로 loopback/link-local/
    /// unspecified는 어떤 provider 캐시에도 매칭될 수 없다.
    private static func isUnreachableForProviderMatch(_ host: String) -> Bool {
        if host.isEmpty { return true }
        if host == "0.0.0.0" || host == "::" { return true }
        if host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("127.") { return true }   // 127.0.0.0/8
        if host.hasPrefix("fe80:") { return true }  // IPv6 link-local
        return false
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
            ingestStart(desc, at: event.timestamp)
        case .flowUpdated(let id, let bIn, let bOut):
            ingestUpdate(flowID: id, bytesIn: bIn, bytesOut: bOut)
        case .flowEnded(let id):
            liveFlows.removeValue(forKey: id)
            pendingFlows.removeValue(forKey: id)
        }
    }

    private func ingestStart(_ desc: FlowDescriptor, at now: Date) {
        // Layer 0: loopback / link-local / unspecified — 절대 AI provider 매칭
        // 후보가 될 수 없으므로 ingest 단계에서 drop. pendingFlows 슬롯과
        // reclassifyPending 비용을 아낌.
        if Self.isUnreachableForProviderMatch(desc.remote.host) { return }
        // Layer 1: blocklist (browsers / chat clients that hit LLM IPs
        // but aren't AI agents themselves).
        if Blocklist.isBlocked(desc.processName) { return }
        // Layer 2: provider classification by remote IP.
        if let provider = registry.providerName(forIP: desc.remote.host) {
            NSLog("AgentRunner: flow MATCH ip=\(desc.remote.host) pname=\(desc.processName) provider=\(provider)")
            liveFlows[desc.flowID] = FlowSlot(
                session: SessionKey(pid: desc.pid, provider: provider),
                processName: desc.processName,
                bytesIn: 0,
                bytesOut: 0
            )
        } else {
            if Self.isLogWorthyPending(desc) {
                NSLog("AgentRunner: flow PENDING ip=\(desc.remote.host) pname=\(desc.processName) pid=\(desc.pid)")
            }
            // No match yet — defer in case the registry catches up
            // (DNS refresh, network change, system wake). Re-evaluated
            // on each tick. Critical because ntstat emits SRC_DESC for
            // existing flows the moment we subscribe — typically a few
            // seconds before ProviderRegistry's first DNS refresh
            // completes.
            pendingFlows[desc.flowID] = PendingFlow(
                descriptor: desc,
                firstSeen: now,
                lastBytesIn: 0,
                lastBytesOut: 0
            )
        }
    }

    private func ingestUpdate(flowID: UInt64, bytesIn: UInt64, bytesOut: UInt64) {
        // Fast path: already-classified flow.
        if var slot = liveFlows[flowID] {
            slot.bytesIn = max(slot.bytesIn, bytesIn)
            slot.bytesOut = max(slot.bytesOut, bytesOut)
            liveFlows[flowID] = slot
            return
        }
        // Pending path: keep latest counters so promotion later carries
        // accurate cumulative totals.
        if var pending = pendingFlows[flowID] {
            pending.lastBytesIn = max(pending.lastBytesIn, bytesIn)
            pending.lastBytesOut = max(pending.lastBytesOut, bytesOut)
            pendingFlows[flowID] = pending
        }
    }

    /// Called from runTick. Re-tests every pending flow against the
    /// (possibly updated) ProviderRegistry. Promotes matches to
    /// liveFlows. Drops entries older than `pendingMaxAge`.
    private func reclassifyPending(now: Date) {
        var promotedKeys: [UInt64] = []
        var staleKeys: [UInt64] = []
        for (id, p) in pendingFlows {
            if let provider = registry.providerName(forIP: p.descriptor.remote.host) {
                liveFlows[id] = FlowSlot(
                    session: SessionKey(pid: p.descriptor.pid, provider: provider),
                    processName: p.descriptor.processName,
                    bytesIn: p.lastBytesIn,
                    bytesOut: p.lastBytesOut
                )
                promotedKeys.append(id)
            } else if now.timeIntervalSince(p.firstSeen) > pendingMaxAge {
                staleKeys.append(id)
            }
        }
        for k in promotedKeys { pendingFlows.removeValue(forKey: k) }
        for k in staleKeys    { pendingFlows.removeValue(forKey: k) }
    }

    // MARK: - Tick (publish + GC)

    /// Synchronous, deterministic. Consolidates flow byte sums into
    /// Sessions, runs the state machine, returns the new aggregate.
    @discardableResult
    internal func runTick(now: Date) -> AggregateState {
        // 0. Pending → live promotion sweep. Catches flows whose remote
        //    IP only became registry-known after flowStarted fired.
        reclassifyPending(now: now)

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
