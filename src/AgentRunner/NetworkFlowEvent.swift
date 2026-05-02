//
//  NetworkFlowEvent.swift
//  AgentRunner
//
//  Source-agnostic flow event types. Domain layer consumes only these —
//  never the underlying signal source's wire format.
//

import Foundation

struct SocketAddress: Sendable, Equatable {
    /// Canonical IPv4 dotted-quad or IPv6 expanded form. No port, no brackets.
    let host: String
    let port: UInt16
}

struct FlowDescriptor: Sendable, Equatable {
    /// Source-assigned unique ID for this flow's lifetime. Stable across
    /// updates; reused only after `flowEnded`.
    let flowID: UInt64
    let pid: Int32
    /// Process name as the source reports it (may be truncated).
    let processName: String
    /// IPPROTO_TCP (6) or IPPROTO_UDP (17).
    let proto: Int32
    let local: SocketAddress
    let remote: SocketAddress
}

struct NetworkFlowEvent: Sendable {
    enum Kind: Sendable {
        case flowStarted(FlowDescriptor)
        /// Cumulative byte counters since flow start. Consumers compute deltas.
        case flowUpdated(flowID: UInt64, bytesIn: UInt64, bytesOut: UInt64)
        case flowEnded(flowID: UInt64)
    }

    let kind: Kind
    let timestamp: Date
}
