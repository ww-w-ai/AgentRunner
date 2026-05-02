//
//  MockFlowSource.swift
//  AgentRunner
//
//  Test-only flow source. Lets unit tests inject deterministic event
//  sequences into SessionManager without touching the kernel.
//

import Foundation

final class MockFlowSource: NetworkFlowSource {

    private let lock = NSLock()
    private var eventHandler: (@Sendable (NetworkFlowEvent) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?

    /// If set, `start()` throws this error instead of succeeding.
    var startError: NetworkFlowSourceError?

    func start(
        eventHandler: @escaping @Sendable (NetworkFlowEvent) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        if let err = startError { throw err }
        lock.lock()
        defer { lock.unlock() }
        self.eventHandler = eventHandler
        self.failureHandler = failureHandler
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        eventHandler = nil
        failureHandler = nil
    }

    /// Test driver: emit a synthetic event.
    func emit(_ event: NetworkFlowEvent) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(event)
    }

    /// Test driver: simulate post-start failure.
    func fail(_ error: Error) {
        lock.lock()
        let handler = failureHandler
        eventHandler = nil
        failureHandler = nil
        lock.unlock()
        handler?(error)
    }
}
