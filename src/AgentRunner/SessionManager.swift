//
//  SessionManager.swift
//  AgentRunner
//
//  Session들을 관리. nettop 이벤트 받아서 (PID, provider) 단위로 합산.
//  Snapshot boundary 이벤트(매 nettop 스냅샷 = 2s)에 맞춰 상태 머신 갱신 + GC + publish.
//  이전엔 별도 3s 타이머가 있었으나 nettop 주기와 어긋나 부풀림/지연을 유발해서 제거됨.
//

import Foundation

final class SessionManager {

    private let registry: ProviderRegistry
    private(set) var sessions: [SessionKey: Session] = [:]

    /// Tick 윈도우(3s) 동안 본 connection별 최신 cumulative bytes.
    /// Key는 (PID, provider) + 5-tuple — 같은 connection이 여러 nettop 스냅샷에 등장해도
    /// 누적 바이트가 부풀려지지 않도록 max(latest)만 유지. tick 시 (PID, provider)별로 합산.
    private struct ConnKey: Hashable {
        let session: SessionKey
        let proto: String
        let srcIP: String
        let srcPort: Int
        let dstIP: String
        let dstPort: Int
    }
    private var pendingConns: [ConnKey: (name: String, bIn: UInt64, bOut: UInt64)] = [:]

    /// nettop은 process 헤더 → 그 connection들 순서로 출력. 현재 process 추적.
    private var currentProcessName: String = ""
    private var currentProcessPID: Int32 = 0

    private let queue = DispatchQueue(label: "ai.ww-w.AgentRunner.session")

    /// 집계 상태 변경 시 호출 (메인 큐로 보냄)
    var onAggregateChange: ((AggregateState) -> Void)?

    private var lastAggregate: AggregateState = AggregateState(state: .idle, bytesInRate: 0, sessionCount: 0)

    init(registry: ProviderRegistry) {
        self.registry = registry
    }

    func start() {
        // 상태 갱신은 NettopMonitor가 보내는 .snapshotBoundary 이벤트로 트리거.
        // 별도 타이머 불필요 — nettop이 살아있으면 2s마다 boundary가 도착함.
    }

    func stop() {
        // No-op — 타이머 없음. 호환을 위해 시그니처만 유지.
    }

    /// nettop 이벤트 흡수 (NettopMonitor 콜백에서 호출). thread-safe.
    func handle(event: NettopEvent) {
        queue.async { [weak self] in
            self?.handleInternal(event)
        }
    }

    internal func handleInternal(_ event: NettopEvent) {
        switch event {
        case .snapshotBoundary:
            // 한 nettop 스냅샷의 모든 라인이 도착했음 → 즉시 처리/publish.
            let agg = runTick(now: Date())
            if agg != lastAggregate {
                lastAggregate = agg
                DispatchQueue.main.async { [weak self] in
                    self?.onAggregateChange?(agg)
                }
            }

        case .process(let name, let pid):
            currentProcessName = name.trimmingCharacters(in: .whitespaces)
            currentProcessPID = pid

        case .connection(let proto, let srcIP, let srcPort,
                         let dstIP, let dstPort, _,
                         let bytesIn, let bytesOut):
            // Layer 1: 블록리스트
            if Blocklist.isBlocked(currentProcessName) { return }
            // Layer 2: provider 매칭 (현재는 IP 매칭만)
            guard let provider = registry.providerName(forIP: dstIP) else { return }

            let sKey = SessionKey(pid: currentProcessPID, provider: provider)
            let cKey = ConnKey(session: sKey,
                               proto: proto,
                               srcIP: srcIP, srcPort: srcPort,
                               dstIP: dstIP, dstPort: dstPort)
            // nettop은 cumulative bytes를 보고함. 한 윈도우 내 같은 connection이
            // 여러 스냅샷에 등장하면 최신값만 유지 (max로 단조 증가 보장).
            if let existing = pendingConns[cKey] {
                pendingConns[cKey] = (existing.name,
                                      max(existing.bIn, bytesIn),
                                      max(existing.bOut, bytesOut))
            } else {
                pendingConns[cKey] = (currentProcessName, bytesIn, bytesOut)
            }
        }
    }

    /// Snapshot boundary 처리 본체 — testable, synchronous, deterministic time.
    @discardableResult
    internal func runTick(now: Date) -> AggregateState {
        // 1. connection별 최신 cumulative → (PID, provider) 단위로 합산해 session에 흡수
        var perSession: [SessionKey: (name: String, bIn: UInt64, bOut: UInt64)] = [:]
        for (cKey, conn) in pendingConns {
            if let existing = perSession[cKey.session] {
                perSession[cKey.session] = (existing.name,
                                            existing.bIn + conn.bIn,
                                            existing.bOut + conn.bOut)
            } else {
                perSession[cKey.session] = conn
            }
        }
        for (key, sample) in perSession {
            let session = sessions[key] ?? Session(key: key, processName: sample.name)
            session.ingest(totalBytesIn: sample.bIn, totalBytesOut: sample.bOut, at: now)
            sessions[key] = session
        }
        pendingConns.removeAll(keepingCapacity: true)

        // 2. 모든 세션 tick
        for session in sessions.values {
            session.tick(now: now)
        }

        // 3. GC: 30초 idle 세션 제거
        sessions = sessions.filter { !$0.value.isStale(now: now) }

        // 4. 집계 상태 계산
        return computeAggregate()
    }

    private func computeAggregate() -> AggregateState {
        guard !sessions.isEmpty else {
            return AggregateState(state: .idle, bytesInRate: 0, sessionCount: 0)
        }

        // 우선순위 max
        let maxState = sessions.values.map { $0.state }.max() ?? .idle
        // 활성 세션 중 max bytes_in_rate
        let maxRate = sessions.values
            .filter { $0.state == maxState && maxState == .running }
            .map { $0.bytesInRate }
            .max() ?? 0

        return AggregateState(
            state: maxState,
            bytesInRate: maxRate,
            sessionCount: sessions.count
        )
    }

    /// 외부 조회: 현재 세션 스냅샷 (팝오버 UI에서 사용).
    /// queue 안에서 값 타입(SessionSnapshot)으로 복사 → 메인 스레드 race-free.
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

/// 메인 스레드 안전 — 값 타입으로 복사된 세션 스냅샷.
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
