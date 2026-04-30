//
//  NettopEvent.swift
//  AgentRunner
//

import Foundation

enum NettopEvent {
    case process(name: String, pid: Int32)
    case connection(
        proto: String,        // "tcp4" | "tcp6" | "udp4" | "udp6"
        srcIP: String,
        srcPort: Int,
        dstIP: String,        // 호스트명일 수도 있음 (1e100.net 등)
        dstPort: Int,
        state: String,        // "Established" 등
        bytesIn: UInt64,
        bytesOut: UInt64
    )
    /// nettop 스냅샷 경계 — 이전 스냅샷의 모든 라인이 도착했음을 의미.
    /// SessionManager는 이 이벤트를 받자마자 pendingConns를 처리한다.
    case snapshotBoundary
}
