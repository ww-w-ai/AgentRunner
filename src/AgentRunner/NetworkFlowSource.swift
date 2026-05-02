//
//  NetworkFlowSource.swift
//  AgentRunner
//
//  Protocol boundary between the domain layer (SessionManager) and the
//  signal supplier (ntstat in production, mock in tests). Domain code
//  depends only on this protocol — never on a concrete implementation.
//

import Foundation

enum NetworkFlowSourceError: Error, CustomStringConvertible {
    case kernelControlUnavailable(errno: Int32)
    case subscriptionFailed(errno: Int32)
    case protocolDecodeFailure(reason: String)
    case sourceClosed

    var description: String {
        switch self {
        case .kernelControlUnavailable(let e):
            return "Kernel control 'com.apple.network.statistics' unavailable (errno \(e))"
        case .subscriptionFailed(let e):
            return "ntstat subscription failed (errno \(e))"
        case .protocolDecodeFailure(let r):
            return "ntstat protocol decode failure: \(r)"
        case .sourceClosed:
            return "Network flow source closed unexpectedly"
        }
    }
}

protocol NetworkFlowSource: AnyObject {
    /// Begin delivering events. Throws if the source cannot initialize
    /// (e.g., ntstat kernel control unavailable on this macOS version).
    ///
    /// `eventHandler` is invoked from an arbitrary background queue —
    /// the consumer is responsible for its own synchronization.
    ///
    /// `failureHandler` is invoked at most once if the source dies
    /// after a successful start (e.g., socket closed by kernel). After
    /// it fires the source has self-stopped; consumers should treat
    /// it like an init-time throw and transition to an unavailable state.
    func start(
        eventHandler: @escaping @Sendable (NetworkFlowEvent) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws

    /// Stop delivering events. Idempotent.
    func stop()
}
