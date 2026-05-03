//
//  Session.swift
//  AgentRunner
//
//  세션 = (PID, provider). 자체 상태 머신 보유.
//

import Foundation

enum SessionState: Int, Comparable {
    case idle = 0
    case scout = 1     // 데이터 흐르다 멈춘 상태 — 캐릭터가 살피는 모션
    case tooling = 2   // scout → idle 전환기 (무기 점검 wrap-up)
    case running = 3   // 가장 우선순위 높음

    static func < (lhs: SessionState, rhs: SessionState) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

struct SessionKey: Hashable {
    let pid: Int32
    let provider: String
}

final class Session {
    let key: SessionKey
    let processName: String

    // 최신 누적 bytes (모든 connection 합산)
    private(set) var bytesIn: UInt64 = 0
    private(set) var bytesOut: UInt64 = 0

    // 직전 sample 값 (delta 계산용)
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var prevSampleAt: Date?

    // 실시간 rate (bytes/sec)
    private(set) var bytesInRate: Double = 0
    private(set) var bytesOutRate: Double = 0

    // 마지막 활동 시각 (GC용)
    private(set) var lastActivity: Date

    // 상태 머신
    private(set) var state: SessionState = .idle
    private var stateEnteredAt: Date = Date()
    private var queuedState: SessionState?
    private let minHoldSeconds: TimeInterval = 3.0

    /// running → scout dip hold — 짧은 도구(85% < 2s)는 run에 흡수.
    private let runningDipHold: TimeInterval = 4.0
    private var dipStartedAt: Date?

    /// scout → tooling 전환 — 데이터 멈춘 지 충분히 길어지면 wrap-up 진입.
    /// 트래픽 기준으로 보기로 했으니 단순히 무활동이 지속되면 idle 단계로.
    private let scoutToToolingTimeout: TimeInterval = 15.0

    /// tooling → idle — wrap-up 애니메이션 4s 끝난 후.
    private let toolingToIdleTimeout: TimeInterval = 5.0

    init(key: SessionKey, processName: String) {
        self.key = key
        self.processName = processName
        self.lastActivity = Date()
    }

    /// 새 nettop 샘플 흡수. 한 PID/provider의 여러 connection bytes를 합산해서 1번에 호출.
    func ingest(totalBytesIn: UInt64, totalBytesOut: UInt64, at now: Date) {
        // 누적값이라 단순 max(이전, 현재). nettop 가끔 리셋되는 경우 방지.
        let bin = max(bytesIn, totalBytesIn)
        let bout = max(bytesOut, totalBytesOut)

        if let prev = prevSampleAt {
            let dt = now.timeIntervalSince(prev)
            if dt > 0.1 {
                let dIn  = Double(bin.subtractingReportingOverflow(prevBytesIn).0)
                let dOut = Double(bout.subtractingReportingOverflow(prevBytesOut).0)
                bytesInRate  = max(0, dIn  / dt)
                bytesOutRate = max(0, dOut / dt)
                prevBytesIn = bin
                prevBytesOut = bout
                prevSampleAt = now
            }
        } else {
            prevBytesIn = bin
            prevBytesOut = bout
            prevSampleAt = now
        }

        bytesIn = bin
        bytesOut = bout

        if bytesInRate > 0 || bytesOutRate > 0 {
            lastActivity = now
        }

        evaluateStateMachine(now: now)
    }

    /// 상태 머신 평가 — 트래픽 분석 기반.
    /// 데이터 분석 결과 (4개 프로젝트, 65시간 트랜스크립트):
    ///   - 첫 LLM 호출 outbound burst: 압축 후 28~60 KB/s
    ///   - Streaming inbound: p50 3~6 KB/s, dip 시 ~0
    /// 따라서 OUT_NEW = 5 KB/s (= 10 KB / 2s window) 가 안전.
    private func evaluateStateMachine(now: Date) {
        // 임계값 (B/s — 2초 윈도우 평균)
        let inLive: Double = 200      // streaming 시작
        let inDead: Double = 50       // 데이터 멈춤
        let outNew: Double = 5000     // 새 LLM 호출 burst

        let target: SessionState

        switch state {
        case .idle:
            // out spike 또는 in이 강하게 들어오면 → running (캐릭터는 jump 1회 후 sprint)
            if bytesOutRate > outNew || bytesInRate > inLive {
                target = .running
            } else {
                target = .idle
            }

        case .running:
            // 짧은 dip(<4s)은 run에 흡수. 4s+ 지속 = 데이터 멈춤 → scout.
            if bytesInRate >= inDead {
                dipStartedAt = nil
                target = .running
            } else {
                if dipStartedAt == nil { dipStartedAt = now }
                let dipAge = now.timeIntervalSince(dipStartedAt ?? now)
                target = dipAge >= runningDipHold ? .scout : .running
            }

        case .scout:
            // 데이터 재개 → running 복귀. 그 외엔 30s 후 tooling (tick).
            if bytesInRate >= inDead {
                dipStartedAt = nil
                target = .running
            } else {
                target = .scout
            }

        case .tooling:
            // wrap-up 진행 중 — tick이 4-5s 후 idle로 전환. 그 사이 데이터 재개 시 running.
            if bytesInRate >= inDead {
                target = .running
            } else {
                target = .tooling
            }
        }

#if DEBUG
        if bytesInRate > 0 || bytesOutRate > 0 {
            NSLog("[SESSION %d/%@] in=%.0fB/s out=%.0fB/s state=%@→%@",
                  key.pid, key.provider,
                  bytesInRate, bytesOutRate,
                  String(describing: state),
                  String(describing: target))
        }
#endif

        applyTransition(to: target, now: now)
    }

    private func applyTransition(to target: SessionState, now: Date) {
        if target == state { return }

        let heldFor = now.timeIntervalSince(stateEnteredAt)

        // IDLE에서 다른 상태로는 즉시. 그 외엔 3초 hold.
        if state == .idle || heldFor >= minHoldSeconds {
            state = target
            stateEnteredAt = now
            queuedState = nil
        } else {
            queuedState = target
        }
    }

    /// 외부 tick에서 호출 (1초마다). hold 만료된 큐 시그널 적용 + idle 회수.
    func tick(now: Date) {
        // 큐 적용
        if let queued = queuedState,
           now.timeIntervalSince(stateEnteredAt) >= minHoldSeconds {
            state = queued
            stateEnteredAt = now
            queuedState = nil
        }

        // 활동 끊긴 지 오래되면 단계적 전환: running → scout → tooling → idle
        let since = now.timeIntervalSince(lastActivity)
        switch state {
        case .running where since > runningDipHold:
            applyTransition(to: .scout, now: now)
        case .scout where since > scoutToToolingTimeout:
            applyTransition(to: .tooling, now: now)
        case .tooling where since > toolingToIdleTimeout:
            applyTransition(to: .idle, now: now)
        default:
            break
        }
    }

    /// GC 대상 여부: 30초 idle.
    func isStale(now: Date) -> Bool {
        return now.timeIntervalSince(lastActivity) > 30
    }
}
