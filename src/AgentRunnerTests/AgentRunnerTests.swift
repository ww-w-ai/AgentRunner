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

// MARK: - B. SessionManager regression tests (cumulative-bytes bug)

@Suite("B. SessionManager — nettop sampling correctness")
struct SessionManagerBytesTests {

    private static func makeManager() -> SessionManager {
        let registry = ProviderRegistry()
        // Inject a known IP→provider mapping for test determinism
        registry.testInjectStaticMapping(["10.0.0.1": "Anthropic"])
        return SessionManager(registry: registry)
    }

    /// Build a NettopEvent pair (process header + connection row).
    private static func feed(_ mgr: SessionManager,
                             pid: Int32 = 100,
                             name: String = "claude",
                             cumIn: UInt64,
                             cumOut: UInt64) {
        mgr.handleInternal(.process(name: name, pid: pid))
        mgr.handleInternal(.connection(
            proto: "tcp4",
            srcIP: "192.168.1.1", srcPort: 12345,
            dstIP: "10.0.0.1", dstPort: 443,
            state: "Established",
            bytesIn: cumIn, bytesOut: cumOut))
    }

    @Test("Same connection appearing twice in one tick window must NOT double-count cumulative bytes")
    func duplicateSnapshotDoesNotInflate() {
        let mgr = Self.makeManager()
        // Two nettop snapshots within one tick window for the same connection
        Self.feed(mgr, cumIn: 1_000, cumOut: 0)
        Self.feed(mgr, cumIn: 1_500, cumOut: 0)  // cumulative grew to 1500
        _ = mgr.runTick(now: at(3))

        let snap = mgr.sessionSnapshot()
        #expect(snap.count == 1)
        // Bug: would store 2500 (1000+1500). Correct: 1500 (latest).
        #expect(snap.first?.bytesIn == 1_500,
                "cumulative bytes from same connection must be max/latest, not summed")
    }

    @Test("Two snapshots then one snapshot — bytesInRate must not become 0 mid-stream")
    func mixedSnapshotWindowsKeepRateAlive() {
        let mgr = Self.makeManager()
        // Tick 1: 2 snapshots (cum 1000, 1500)
        Self.feed(mgr, cumIn: 1_000, cumOut: 0)
        Self.feed(mgr, cumIn: 1_500, cumOut: 0)
        _ = mgr.runTick(now: at(3))

        // Tick 2: 1 snapshot at cum 2000 — traffic still flowing (+500/3s ≈ 167 B/s)
        Self.feed(mgr, cumIn: 2_000, cumOut: 0)
        _ = mgr.runTick(now: at(6))

        let snap = mgr.sessionSnapshot()
        // With buggy summation: tick1 stored bytesIn=2500. tick2 sees max(2500, 2000)=2500.
        // dIn = 0 → bytesInRate = 0. WRONG.
        // With fix: tick1=1500, tick2=2000, dIn=500, rate≈167 B/s.
        #expect(snap.first?.bytesInRate ?? 0 > 0,
                "Live traffic must not yield bytesInRate=0 due to cumulative summation")
    }

    @Test("Multiple connections to same provider in one tick are summed correctly")
    func multipleConnectionsSummed() {
        let mgr = Self.makeManager()
        mgr.handleInternal(.process(name: "claude", pid: 100))
        // Connection A
        mgr.handleInternal(.connection(
            proto: "tcp4",
            srcIP: "192.168.1.1", srcPort: 1111,
            dstIP: "10.0.0.1", dstPort: 443,
            state: "Established",
            bytesIn: 1_000, bytesOut: 0))
        // Connection B (different src port — distinct connection, same provider)
        mgr.handleInternal(.connection(
            proto: "tcp4",
            srcIP: "192.168.1.1", srcPort: 2222,
            dstIP: "10.0.0.1", dstPort: 443,
            state: "Established",
            bytesIn: 500, bytesOut: 0))
        _ = mgr.runTick(now: at(3))
        let snap = mgr.sessionSnapshot()
        #expect(snap.first?.bytesIn == 1_500,
                "distinct connections in same snapshot must sum")
    }

    @Test("nettop counter reset (cumulative shrinks) does not bury session in stale max")
    func nettopResetGuard() {
        let mgr = Self.makeManager()
        Self.feed(mgr, cumIn: 10_000, cumOut: 0)
        _ = mgr.runTick(now: at(3))
        // Counter resets (e.g., nettop relaunch) — cumulative drops to 100
        Self.feed(mgr, cumIn: 100, cumOut: 0)
        _ = mgr.runTick(now: at(6))
        let snap = mgr.sessionSnapshot()
        // max() guard ensures stored bytesIn stays at 10000 (no underflow).
        // delta = 0, rate = 0 — acceptable (no false negative).
        #expect(snap.first?.bytesIn ?? 0 >= 10_000)
        #expect(snap.first?.bytesInRate ?? -1 >= 0, "rate must never be negative")
    }
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
