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
}
