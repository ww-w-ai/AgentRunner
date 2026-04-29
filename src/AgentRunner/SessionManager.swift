//
//  SessionManager.swift
//  AgentRunner
//
//  Session들을 관리. nettop 이벤트 받아서 (PID, provider) 단위로 합산.
//  1초 tick으로 상태 머신 갱신 + GC. 집계 상태를 외부에 publish.
//

import Foundation

final class SessionManager {

    private let registry: ProviderRegistry
    private(set) var sessions: [SessionKey: Session] = [:]

    /// 1 sample(1초) 동안 임시 누적: (pid, provider, processName) → (bytesIn, bytesOut)
    private var pendingSample: [SessionKey: (name: String, bIn: UInt64, bOut: UInt64)] = [:]

    /// nettop은 process 헤더 → 그 connection들 순서로 출력. 현재 process 추적.
    private var currentProcessName: String = ""
    private var currentProcessPID: Int32 = 0

    private var tickTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ai.ww-w.AgentRunner.session")

    /// 집계 상태 변경 시 호출 (메인 큐로 보냄)
    var onAggregateChange: ((AggregateState) -> Void)?

    private var lastAggregate: AggregateState = AggregateState(state: .idle, bytesInRate: 0, sessionCount: 0)

    init(registry: ProviderRegistry) {
        self.registry = registry
    }

    func start() {
        // RunCat 패턴: 상태 평가는 3초 주기. 시각 갱신(프레임 애니)은 별도 timer.
        // 너무 자주 체크하면 timer reschedule + state 진동 비용만 증가.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    func stop() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    /// nettop 이벤트 흡수 (NettopMonitor 콜백에서 호출). thread-safe.
    func handle(event: NettopEvent) {
        queue.async { [weak self] in
            self?.handleInternal(event)
        }
    }

    private func handleInternal(_ event: NettopEvent) {
        switch event {
        case .process(let name, let pid):
            currentProcessName = name.trimmingCharacters(in: .whitespaces)
            currentProcessPID = pid

        case .connection(_, _, _, let dstIP, _, _, let bytesIn, let bytesOut):
            // Layer 1: 블록리스트
            if Blocklist.isBlocked(currentProcessName) { return }
            // Layer 2: provider 매칭 (현재는 IP 매칭만)
            guard let provider = registry.providerName(forIP: dstIP) else { return }

            let key = SessionKey(pid: currentProcessPID, provider: provider)
            // 같은 sample 안에서 같은 (PID, provider)로 가는 다중 connection 합산
            if let existing = pendingSample[key] {
                pendingSample[key] = (existing.name,
                                      existing.bIn + bytesIn,
                                      existing.bOut + bytesOut)
            } else {
                pendingSample[key] = (currentProcessName, bytesIn, bytesOut)
            }
        }
    }

    /// 1초마다 호출. pending sample을 session에 흡수, 상태머신 tick, GC, 집계.
    private func tick() {
        let now = Date()

        // 1. pending sample → session에 흡수
        for (key, sample) in pendingSample {
            let session = sessions[key] ?? Session(key: key, processName: sample.name)
            session.ingest(totalBytesIn: sample.bIn, totalBytesOut: sample.bOut, at: now)
            sessions[key] = session
        }
        pendingSample.removeAll(keepingCapacity: true)

        // 2. 모든 세션 tick
        for session in sessions.values {
            session.tick(now: now)
        }

        // 3. GC: 30초 idle 세션 제거
        sessions = sessions.filter { !$0.value.isStale(now: now) }

        // 4. 집계 상태 계산
        let agg = computeAggregate()
        if agg != lastAggregate {
            lastAggregate = agg
            DispatchQueue.main.async { [weak self] in
                self?.onAggregateChange?(agg)
            }
        }
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
