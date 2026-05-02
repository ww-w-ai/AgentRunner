//
//  AgentRunnerTests.swift
//  AgentRunnerTests
//
//  State machine + nettop sampling regression tests.
//

import Testing
import Foundation
@testable import AgentRunner

// MARK: - Helpers

private func makeSession() -> Session {
    Session(key: SessionKey(pid: 100, provider: "Anthropic"),
            processName: "claude")
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

/// Drive a session into running with a strong initial burst.
private func driveRunning(_ s: Session, startingOut: UInt64 = 0, startingIn: UInt64 = 0) {
    // Start with a clean prev sample at t0
    s.ingest(totalBytesIn: startingIn, totalBytesOut: startingOut, at: at(0))
    // Big outbound burst → enter running (out > 5 KB/s)
    s.ingest(totalBytesIn: startingIn,
             totalBytesOut: startingOut + 50_000,
             at: at(2))
}

/// Force a session into scout state at the given time (>= 12s).
/// Strategy: 2 low-inbound ingests separated by >= 4s → dipAge passes runningDipHold.
private func forceScout(_ s: Session, atTime t: Double) {
    precondition(t >= 12, "forceScout needs t >= 12 (driveRunning ends at 2, dip needs 4s+)")
    driveRunning(s)
    s.ingest(totalBytesIn: 0, totalBytesOut: 51_000, at: at(t - 5))   // dipStartedAt
    s.ingest(totalBytesIn: 0, totalBytesOut: 52_000, at: at(t))       // dipAge = 5 → scout
}

// MARK: - A. Session state machine

@Suite("A. Session state machine")
struct SessionStateMachineTests {

    @Test("idle → running: outbound burst (>5 KB/s) enters running immediately")
    func outboundBurstEntersRunning() {
        let s = makeSession()
        s.ingest(totalBytesIn: 0, totalBytesOut: 0, at: at(0))
        #expect(s.state == .idle)

        // 30 KB over 2s = 15 KB/s outbound — well above 5 KB/s threshold
        s.ingest(totalBytesIn: 0, totalBytesOut: 30_000, at: at(2))
        #expect(s.state == .running)
    }

    @Test("idle → running: heavy inbound (>200 B/s) enters running")
    func inboundEntersRunning() {
        let s = makeSession()
        s.ingest(totalBytesIn: 0, totalBytesOut: 0, at: at(0))
        // 1 KB over 2s = 500 B/s inbound — above 200 B/s threshold
        s.ingest(totalBytesIn: 1_000, totalBytesOut: 0, at: at(2))
        #expect(s.state == .running)
    }

    @Test("running → 짧은 dip (<4s) absorbed, stays running")
    func shortDipAbsorbed() {
        let s = makeSession()
        driveRunning(s)
        #expect(s.state == .running)

        // Inbound silence for 3s — under runningDipHold(4s)
        s.ingest(totalBytesIn: 0, totalBytesOut: 51_000, at: at(5))
        #expect(s.state == .running, "3s dip should be absorbed")
    }

    @Test("running → scout: 4s+ dip in inbound triggers scout (NOT before)")
    func scoutTriggersAtFourSeconds() {
        let s = makeSession()
        driveRunning(s)
        #expect(s.state == .running)

        // First low sample at t=4: dipStartedAt set, but dipAge=0, still running
        s.ingest(totalBytesIn: 0, totalBytesOut: 51_000, at: at(4))
        #expect(s.state == .running)

        // 3s later (dipAge=3s, still <4) — running
        s.ingest(totalBytesIn: 0, totalBytesOut: 52_000, at: at(7))
        #expect(s.state == .running, "dipAge 3s must NOT trigger scout")

        // dipAge = 4.5s → scout
        s.ingest(totalBytesIn: 0, totalBytesOut: 53_000, at: at(8.5))
        #expect(s.state == .scout, "dipAge 4.5s must trigger scout")
    }

    @Test("scout → running: inbound resumes")
    func scoutResumesToRunning() {
        let s = makeSession()
        forceScout(s, atTime: 12)  // scout entered at at(12)
        #expect(s.state == .scout)

        // Wait minHold(3s) so transition can fire, then strong inbound resumes
        s.ingest(totalBytesIn: 5_000, totalBytesOut: 53_000, at: at(16))
        #expect(s.state == .running)
    }

    @Test("scout → tooling: 15s of inactivity")
    func scoutToToolingAfter15s() {
        let s = makeSession()
        forceScout(s, atTime: 12)  // lastActivity = at(12)
        #expect(s.state == .scout)

        // scoutToToolingTimeout = 15s, measured against lastActivity = at(12)
        s.tick(now: at(20))
        #expect(s.state == .scout, "8s into scout, still scout")
        s.tick(now: at(28))
        #expect(s.state == .tooling, "16s past lastActivity → tooling")
    }

    @Test("tooling → idle: 5s of inactivity (after minHold)")
    func toolingToIdleAfter5s() {
        let s = makeSession()
        forceScout(s, atTime: 12)
        s.tick(now: at(28))
        #expect(s.state == .tooling)
        // tooling entered at at(28). toolingToIdleTimeout=5s vs lastActivity (at 12),
        // BUT applyTransition needs heldFor in tooling >= minHold(3s).
        s.tick(now: at(32))
        #expect(s.state == .idle, "tooling held > minHold + since > toolingToIdleTimeout → idle")
    }

    @Test("tooling → running: traffic resumes (after minHold tooling state)")
    func toolingResumesToRunning() {
        let s = makeSession()
        forceScout(s, atTime: 12)
        s.tick(now: at(28))
        #expect(s.state == .tooling)

        // Inbound resumes after minHold(3s) elapsed in tooling
        s.ingest(totalBytesIn: 5_000, totalBytesOut: 53_000, at: at(32))
        #expect(s.state == .running)
    }

    @Test("minHoldSeconds(3s): non-idle states held min 3s before transition")
    func minHoldQueuesPrematureTransition() {
        let s = makeSession()
        forceScout(s, atTime: 12)  // scout entered at at(12), stateEnteredAt=at(12)
        #expect(s.state == .scout)

        // Inbound resume at at(13.5) — only 1.5s into scout.
        s.ingest(totalBytesIn: 5_000, totalBytesOut: 53_000, at: at(13.5))
        // heldFor=1.5s < 3s → queued, state still scout
        #expect(s.state == .scout, "premature transition must be queued, not applied")

        // Tick after hold expires
        s.tick(now: at(16))
        #expect(s.state == .running, "queued transition applies after minHold")
    }
}

// MARK: - B. SessionManager — flow ingestion correctness

@Suite("B. SessionManager — NetworkFlowEvent ingestion")
struct SessionManagerFlowTests {

    /// Builds a SessionManager wired to a MockFlowSource so we can drive
    /// deterministic event sequences without touching the kernel.
    private static func makeManager() -> (SessionManager, MockFlowSource) {
        let registry = ProviderRegistry()
        registry.testInjectStaticMapping(["10.0.0.1": "Anthropic"])
        let source = MockFlowSource()
        let mgr = SessionManager(registry: registry, flowSource: source)
        return (mgr, source)
    }

    private static func descriptor(flowID: UInt64,
                                   pid: Int32 = 100,
                                   name: String = "claude",
                                   remoteHost: String = "10.0.0.1",
                                   remotePort: UInt16 = 443,
                                   srcPort: UInt16 = 12345) -> FlowDescriptor {
        FlowDescriptor(
            flowID: flowID,
            pid: pid,
            processName: name,
            proto: IPPROTO_TCP,
            local: SocketAddress(host: "192.168.1.1", port: srcPort),
            remote: SocketAddress(host: remoteHost, port: remotePort)
        )
    }

    private static func started(_ d: FlowDescriptor, at t: Double) -> NetworkFlowEvent {
        NetworkFlowEvent(kind: .flowStarted(d), timestamp: at(t))
    }

    private static func updated(flowID: UInt64, bIn: UInt64, bOut: UInt64,
                                at t: Double) -> NetworkFlowEvent {
        NetworkFlowEvent(kind: .flowUpdated(flowID: flowID,
                                            bytesIn: bIn,
                                            bytesOut: bOut),
                         timestamp: at(t))
    }

    private static func ended(flowID: UInt64, at t: Double) -> NetworkFlowEvent {
        NetworkFlowEvent(kind: .flowEnded(flowID: flowID), timestamp: at(t))
    }

    @Test("flowUpdated: cumulative bytes are recorded as max — not summed")
    func cumulativeBytesNotSummed() {
        let (mgr, _) = Self.makeManager()
        let d = Self.descriptor(flowID: 1)
        mgr.handleInternal(Self.started(d, at: 0))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 1_000, bOut: 0, at: 0.5))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 1_500, bOut: 0, at: 1.0))
        _ = mgr.runTick(now: at(3))
        let snap = mgr.sessionSnapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.bytesIn == 1_500,
                "Latest cumulative — must not double up to 2500")
    }

    @Test("Multiple flows to the same provider sum bytes for the session")
    func multipleFlowsSumPerSession() {
        let (mgr, _) = Self.makeManager()
        let a = Self.descriptor(flowID: 1, srcPort: 1111)
        let b = Self.descriptor(flowID: 2, srcPort: 2222)
        mgr.handleInternal(Self.started(a, at: 0))
        mgr.handleInternal(Self.started(b, at: 0))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 1_000, bOut: 0, at: 0.5))
        mgr.handleInternal(Self.updated(flowID: 2, bIn: 500, bOut: 0, at: 0.5))
        _ = mgr.runTick(now: at(3))
        let snap = mgr.sessionSnapshot()
        #expect(snap.count == 1, "both flows roll up to one (PID, provider) Session")
        #expect(snap.first?.bytesIn == 1_500)
    }

    @Test("Cumulative growth across ticks produces a non-zero rate")
    func ratePersistsAcrossTicks() {
        let (mgr, _) = Self.makeManager()
        let d = Self.descriptor(flowID: 1)
        mgr.handleInternal(Self.started(d, at: 0))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 1_500, bOut: 0, at: 1))
        _ = mgr.runTick(now: at(3))

        mgr.handleInternal(Self.updated(flowID: 1, bIn: 2_000, bOut: 0, at: 4))
        _ = mgr.runTick(now: at(6))
        let snap = mgr.sessionSnapshot()
        #expect((snap.first?.bytesInRate ?? 0) > 0,
                "Continued cumulative growth must yield a positive rate")
    }

    @Test("Blocked process names never produce a Session")
    func blocklistFiltersFlows() {
        let (mgr, _) = Self.makeManager()
        let blocked = Self.descriptor(flowID: 1, name: "Google Chrome")
        mgr.handleInternal(Self.started(blocked, at: 0))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 50_000, bOut: 0, at: 1))
        _ = mgr.runTick(now: at(3))
        #expect(mgr.sessionSnapshot().isEmpty,
                "Blocklist must short-circuit before Session creation")
    }

    @Test("Flows whose remote IP doesn't match any provider are dropped")
    func unknownRemoteIPDropped() {
        let (mgr, _) = Self.makeManager()
        let d = Self.descriptor(flowID: 1, remoteHost: "1.2.3.4")
        mgr.handleInternal(Self.started(d, at: 0))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 50_000, bOut: 0, at: 1))
        _ = mgr.runTick(now: at(3))
        #expect(mgr.sessionSnapshot().isEmpty)
    }

    @Test("Updates arriving for a never-started flow are dropped")
    func updateWithoutStartIgnored() {
        let (mgr, _) = Self.makeManager()
        // No flowStarted — descriptor was never registered.
        mgr.handleInternal(Self.updated(flowID: 99, bIn: 1_000, bOut: 0, at: 1))
        _ = mgr.runTick(now: at(3))
        #expect(mgr.sessionSnapshot().isEmpty)
    }

    @Test("flowEnded removes the flow from the live map")
    func flowEndedRemovesSlot() {
        let (mgr, _) = Self.makeManager()
        let d = Self.descriptor(flowID: 1)
        mgr.handleInternal(Self.started(d, at: 0))
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 1_500, bOut: 0, at: 0.5))
        mgr.handleInternal(Self.ended(flowID: 1, at: 1))
        // No further updates — Session retains historical bytes but new
        // updates for this flowID would be ignored.
        mgr.handleInternal(Self.updated(flowID: 1, bIn: 9_999, bOut: 0, at: 2))
        _ = mgr.runTick(now: at(3))
        let snap = mgr.sessionSnapshot()
        // The Session may exist with the bytes captured before flowEnded,
        // but the post-end update must NOT have been ingested.
        if let s = snap.first {
            #expect(s.bytesIn <= 1_500,
                    "Update after flowEnded must not be ingested")
        }
    }
}

// MARK: - B'. MockFlowSource sanity

@Suite("B'. MockFlowSource")
struct MockFlowSourceTests {

    @Test("emit before start does nothing")
    func emitWithoutStartNoop() {
        let m = MockFlowSource()
        m.emit(NetworkFlowEvent(
            kind: .flowEnded(flowID: 0),
            timestamp: Date()))
        // No crash, no observable side effect.
    }

    @Test("startError causes start() to throw")
    func startErrorThrows() {
        let m = MockFlowSource()
        m.startError = .kernelControlUnavailable(errno: 1)
        var threw = false
        do {
            try m.start(eventHandler: { _ in }, failureHandler: { _ in })
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test("fail() invokes failureHandler exactly once")
    func failInvokesHandler() {
        let m = MockFlowSource()
        let counter = FailCounter()
        try? m.start(eventHandler: { _ in },
                     failureHandler: { _ in counter.bump() })
        m.fail(NetworkFlowSourceError.sourceClosed)
        m.fail(NetworkFlowSourceError.sourceClosed)
        #expect(counter.value == 1, "post-fail re-fail must not re-invoke")
    }
}

/// Reference-typed counter — keeps the closure's mutation off `inout` /
/// captured-var semantics that Swift 6 strict concurrency rejects.
private final class FailCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

// MARK: - C. CharacterAnimator

@Suite("C. CharacterAnimator")
struct CharacterAnimatorTests {

    @Test("runIntervalForRate: ≤50 B/s → 350ms (slow walk)")
    func runIntervalSlow() {
        #expect(abs(CharacterAnimator.runIntervalForRate(50) - 0.350) < 0.001)
        #expect(abs(CharacterAnimator.runIntervalForRate(0) - 0.350) < 0.001)
    }

    @Test("runIntervalForRate: ≥50 KB/s → 50ms (sprint)")
    func runIntervalFast() {
        #expect(abs(CharacterAnimator.runIntervalForRate(50_000) - 0.050) < 0.001)
        #expect(abs(CharacterAnimator.runIntervalForRate(500_000) - 0.050) < 0.001)
    }

    @Test("runIntervalForRate: monotonic — higher rate yields shorter interval")
    func runIntervalMonotonic() {
        let r100 = CharacterAnimator.runIntervalForRate(100)
        let r1k = CharacterAnimator.runIntervalForRate(1_000)
        let r10k = CharacterAnimator.runIntervalForRate(10_000)
        #expect(r100 > r1k)
        #expect(r1k > r10k)
    }

    @Test("AnimID one-shot classification matches expected set")
    func oneShotSet() {
        #expect(CharacterAnimator.AnimID.jump.isOneShot)
        #expect(CharacterAnimator.AnimID.threeHit.isOneShot)
        #expect(CharacterAnimator.AnimID.supreme.isOneShot)
        #expect(CharacterAnimator.AnimID.toolingWrapUp.isOneShot)
        #expect(!CharacterAnimator.AnimID.idle.isOneShot)
        #expect(!CharacterAnimator.AnimID.rest.isOneShot)
        #expect(!CharacterAnimator.AnimID.scout.isOneShot)
        #expect(!CharacterAnimator.AnimID.run.isOneShot)
    }
}

// MARK: - D. ntstat sockaddr parser regression tests
//
// History: parseSockaddrUnion's AF_INET branch once called inet_ntop
// via `withUnsafePointer(to: &addrBytes)` where addrBytes was a Swift
// Array. That handed inet_ntop a pointer to the Array struct header
// (buffer pointer + count metadata) instead of the 4 IP bytes,
// producing nondeterministic garbage IPs that never matched
// ProviderRegistry. The character stayed lying down forever.
//
// These tests pin the dotted-quad behavior so the bug can't recur.

@Suite("D. NTStat sockaddr parser")
struct SockaddrParserTests {

    /// Build a sockaddr_in starting at byte 0 of a buffer with optional
    /// leading padding. Returns the buffer + offset for the parser.
    private static func makeIPv4Buffer(
        leading: Int = 0,
        addr: (UInt8, UInt8, UInt8, UInt8),
        port: UInt16
    ) -> (Data, Int) {
        var data = Data(count: leading)
        data.append(0x10)               // sin_len = 16
        data.append(2)                  // sin_family = AF_INET (2)
        data.append(UInt8(port >> 8))   // sin_port hi
        data.append(UInt8(port & 0xff)) // sin_port lo
        data.append(addr.0)
        data.append(addr.1)
        data.append(addr.2)
        data.append(addr.3)
        for _ in 0..<8 { data.append(0) } // sin_zero[8]
        // Padding to fill the 28-byte union slot
        for _ in 0..<12 { data.append(0) }
        return (data, leading)
    }

    private static func makeIPv6Buffer(
        leading: Int = 0,
        addr: [UInt8],
        port: UInt16
    ) -> (Data, Int) {
        precondition(addr.count == 16)
        var data = Data(count: leading)
        data.append(0x1c)               // sin6_len = 28
        data.append(30)                 // sin6_family = AF_INET6 (30)
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xff))
        for _ in 0..<4 { data.append(0) } // sin6_flowinfo
        data.append(contentsOf: addr)
        for _ in 0..<4 { data.append(0) } // sin6_scope_id
        return (data, leading)
    }

    @Test("AF_INET: dotted quad (regression: don't pass Array to inet_ntop)")
    func ipv4DottedQuad() {
        let (data, offset) = Self.makeIPv4Buffer(
            addr: (160, 79, 104, 10), port: 443)
        data.withUnsafeBytes { raw in
            let parsed = parseSockaddrUnion(raw.baseAddress!,
                                            offset: offset,
                                            totalLength: data.count)
            #expect(parsed?.host == "160.79.104.10",
                    "AF_INET parser must produce canonical dotted-quad")
            #expect(parsed?.port == 443)
        }
    }

    @Test("AF_INET: parser produces deterministic strings on repeat")
    func ipv4Deterministic() {
        // Original bug surfaced as different garbage IPs across calls
        // because Array struct memory shifted. Make sure same input
        // yields same output.
        let (data, offset) = Self.makeIPv4Buffer(
            addr: (1, 2, 3, 4), port: 80)
        var seen: Set<String> = []
        for _ in 0..<10 {
            data.withUnsafeBytes { raw in
                if let p = parseSockaddrUnion(raw.baseAddress!,
                                              offset: offset,
                                              totalLength: data.count) {
                    seen.insert(p.host)
                }
            }
        }
        #expect(seen == ["1.2.3.4"],
                "AF_INET parse must be deterministic — got \(seen)")
    }

    @Test("AF_INET: works at non-zero descriptor offsets (real layouts)")
    func ipv4AtTCPRemoteOffset() {
        // TCP descriptor places `remote` union at offset 152.
        let (data, offset) = Self.makeIPv4Buffer(
            leading: 152, addr: (34, 149, 66, 137), port: 443)
        data.withUnsafeBytes { raw in
            let parsed = parseSockaddrUnion(raw.baseAddress!,
                                            offset: offset,
                                            totalLength: data.count)
            #expect(parsed?.host == "34.149.66.137")
        }
    }

    @Test("AF_INET6: canonical compressed form")
    func ipv6Canonical() {
        // 2607:6bc0::10 = bytes 26 07 6b c0 followed by zeros, then 0010
        let addrBytes: [UInt8] = [
            0x26, 0x07, 0x6b, 0xc0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0x00, 0x10,
        ]
        let (data, offset) = Self.makeIPv6Buffer(
            addr: addrBytes, port: 443)
        data.withUnsafeBytes { raw in
            let parsed = parseSockaddrUnion(raw.baseAddress!,
                                            offset: offset,
                                            totalLength: data.count)
            #expect(parsed?.host == "2607:6bc0::10")
            #expect(parsed?.port == 443)
        }
    }

    @Test("Unknown family returns nil")
    func unknownFamilyReturnsNil() {
        var data = Data([0x10, 0xFF /* unknown family */, 0, 0,
                         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        for _ in 0..<12 { data.append(0) }
        data.withUnsafeBytes { raw in
            let parsed = parseSockaddrUnion(raw.baseAddress!,
                                            offset: 0,
                                            totalLength: data.count)
            #expect(parsed == nil)
        }
    }
}
