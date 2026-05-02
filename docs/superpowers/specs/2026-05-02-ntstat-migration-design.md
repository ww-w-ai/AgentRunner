# Design Spec — Replace nettop subprocess with ntstat in-process client

**Date:** 2026-05-02
**Status:** Approved (brainstorming complete, ready for plan)
**Scope:** Single PR, full replacement

## 1. Problem

Current AgentRunner spawns `/usr/bin/nettop -L 0 -t external -x -s 2` as a subprocess and parses its CSV output to detect AI agent network activity. Measured behavior on a developer Mac (macOS 24.6, ~70 active ESTABLISHED connections):

| Metric                           | Value                               |
| -------------------------------- | ----------------------------------- |
| nettop CPU                       | 138% (1.38 cores sustained)         |
| AgentRunner self CPU             | 0.4%                                |
| AgentRunner 12h cumulative Power | **2,813** (vs iTerm2 88, Chrome 76) |

The monitor consumes more energy than every other app on the machine combined by a wide margin, defeating the project's "lightweight menu bar indicator" identity. Root cause: nettop is a polling tool that walks the full kernel flow table every `-s 2` interval and writes CSV to a pipe regardless of whether traffic occurred.

## 2. Goal

Replace the network signal source while preserving all user-facing functionality. Three governing principles:

1. **No hardcoding — clean, systematic architecture.** Signal source must be abstracted behind a protocol; domain layer must not depend on the concrete provider.
2. **No over-engineering.** Build only what is needed now. Future seams are fine; speculative features are not.
3. **No feature regression** + load reduction. Every existing capability (per-provider classification, popover, menu, jump trigger, state machine) must remain identical from the user's perspective.

### Success criteria

| Metric                     | Current        | Target       |
| -------------------------- | -------------- | ------------ |
| Idle CPU                   | 138%           | < 0.5%       |
| Active CPU (LLM streaming) | 138% sustained | 1–3% peak    |
| 12h Power                  | 2,813          | < 100        |
| Functional parity          | —              | 100%         |
| macOS support              | 13 / 14 / 15   | 13 / 14 / 15 |

### Non-goals

- FSEvents / transcript watching (rejected: loses IP-based universality of detection)
- Multi-agent transcript path config (rejected with above)
- Fallback paths for ntstat failure (rejected: hard fail acceptable; OS-update breakage is a known cost of private SPI)
- New UI surface

## 3. Approach

Use the macOS private SPI **`ntstat`** (the same kernel control interface that `/usr/bin/nettop` wraps) directly via in-process kernel control socket. ntstat is push-based: the kernel emits flow update messages only when flows change, so idle cost is effectively zero.

Rejected alternatives:

- **Keep nettop subprocess, lengthen `-s`** — halves CPU at best, fundamentally still a polling design (rejected as insufficient).
- **`proc_pid_rusage` polling** — public API, but per-process aggregate only, no destination IP, breaks provider classification.
- **NetworkExtension (NEFilterDataProvider)** — public, ideal cost profile, but requires System Extension installation, user approval, possible reboot. Mismatch with project's "drop the app in, no friction" identity.
- **FSEvents on transcripts** — light, but tool-specific (Claude Code only by default), loses ability to detect arbitrary new agents that hit known LLM provider IPs.
- **BPF / DTrace** — entitlement / SIP requirements; not viable for an unsigned-distributed menu bar app.

The cost of `ntstat`'s private status is accepted: `AgentRunner` already distributes via GitHub release DMG (not Mac App Store), so static private-symbol detection does not apply; the only real exposure is potential breakage on macOS minor updates. The user has explicitly chosen to accept this risk.

## 4. Architecture

### 4.1 Layering

```
┌─────────────────────────────────────────────────┐
│ Application Layer                                │
│   AppDelegate (lifecycle)                        │
│   CharacterAnimator (UI)                         │
│   SessionPopover (UI)                            │
└────────────────┬────────────────────────────────┘
                 │ SessionSnapshot (value type)
┌────────────────▼────────────────────────────────┐
│ Domain Layer                                     │
│   SessionManager (aggregation, state machine)    │
│   Session (per-PID×provider accumulation)        │
│   ProviderRegistry (IP → provider)               │
└────────────────┬────────────────────────────────┘
                 │ NetworkFlowEvent (value type)
┌────────────────▼────────────────────────────────┐
│ Signal Source Layer  ← protocol boundary         │
│   protocol NetworkFlowSource                     │
│     │                                            │
│     ├─ NTStatFlowSource (production)             │
│     └─ MockFlowSource (test only)                │
└──────────────────────────────────────────────────┘
```

The protocol boundary is the key architectural seam: domain layer depends only on `NetworkFlowSource`, never on a concrete implementation. Tests substitute a mock; future replacements (if ntstat is ever blocked) plug in a new conforming type without touching domain code.

### 4.2 Protocol — `NetworkFlowSource`

```swift
protocol NetworkFlowSource: AnyObject {
    /// Begin delivering events. Throws if the source cannot initialize
    /// (e.g., ntstat kernel control unavailable on this macOS version).
    /// `eventHandler` is invoked from an arbitrary background queue —
    /// the consumer is responsible for its own synchronization.
    /// `failureHandler` is invoked at most once if the source dies
    /// post-start (e.g., socket closed by kernel). After it fires the
    /// source has self-stopped; consumers should treat it like an
    /// init-time throw and transition to an unavailable state.
    func start(
        eventHandler: @escaping @Sendable (NetworkFlowEvent) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws

    /// Stop delivering events. Idempotent.
    func stop()
}
```

### 4.3 Value types — `NetworkFlowEvent`

```swift
struct NetworkFlowEvent: Sendable {
    enum Kind: Sendable {
        case flowStarted(FlowDescriptor)
        case flowUpdated(flowID: UInt64, bytesIn: UInt64, bytesOut: UInt64)
        case flowEnded(flowID: UInt64)
    }
    let kind: Kind
    let timestamp: Date
}

struct FlowDescriptor: Sendable {
    let flowID: UInt64        // source-assigned unique ID per flow lifetime
    let pid: pid_t
    let processName: String
    let proto: Int32          // IPPROTO_TCP / IPPROTO_UDP
    let local: SocketAddress
    let remote: SocketAddress
}

struct SocketAddress: Sendable {
    let host: String          // canonical IPv4 dotted / IPv6 expanded
    let port: UInt16
}
```

Byte values in `flowUpdated` are cumulative (matching ntstat semantics and the existing `Session.ingest` behavior of `max(prev, current)`). Delta calculation stays in `Session`.

### 4.4 Concrete impl — `NTStatFlowSource`

```swift
final class NTStatFlowSource: NetworkFlowSource {
    init(filter: FlowFilter = .external)
    func start(handler: @escaping @Sendable (NetworkFlowEvent) -> Void) throws
    func stop()
}

enum FlowFilter {
    case all          // debug / dev only
    case external     // production default — equivalent to nettop -t external
}
```

Internal responsibilities:

1. Open `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)` and connect to control name `com.apple.network.statistics`.
2. Send the appropriate `nstat_msg_add_all_srcs` request to subscribe.
3. Read incoming `nstat_msg_*` messages on a dedicated `DispatchSourceRead` (or background thread).
4. Decode message structures (per `<net/ntstat.h>`, vendored from Apple's open-source `xnu` headers — see §5) into `NetworkFlowEvent` and invoke the handler.
5. On `stop()`: send `nstat_msg_rem_all_srcs`, close socket, mark idempotent flag, release handler.

`FlowFilter.external` filters out loopback flows, matching `nettop -t external`.

### 4.5 SessionManager changes

Current code uses nettop's snapshot boundary (every 2 s) as the publish trigger. ntstat is push-based with no fixed boundary, so SessionManager gains an internal `DispatchSourceTimer` ticking every 2 s:

```
[ntstat]  push event ─┐
                      ├→ SessionManager.handle(event)
[ntstat]  push event ─┤   - flowID → Session mapping
                      │   - cumulative bytes update
[ntstat]  push event ─┘

[Timer 2s]    tick ───→ SessionManager.tickPublish()
                          - rate calc (2s window)
                          - state machine evaluation
                          - aggregate state publish
                          - dead session GC
```

State machine thresholds (`bytesOutRate > 5000`, `bytesInRate > 200`, `minHoldSeconds = 3.0`) are unchanged: the published rate retains its "bytes per 2 s window" semantic.

### 4.6 Wiring (DI)

```swift
// AppDelegate
let flowSource: NetworkFlowSource = NTStatFlowSource(filter: .external)
let sessionManager = SessionManager(flowSource: flowSource)

do {
    try sessionManager.start { [weak self] error in
        // failureHandler — invoked if the source dies after a successful start
        self?.transitionToUnavailable(error: error)
    }
} catch {
    transitionToUnavailable(error: error)
    return
}
```

`SessionManager` owns the `NetworkFlowSource` and manages its lifecycle. `AppDelegate` does not see the concrete type.

## 5. xnu headers strategy

`<net/ntstat.h>` is not in the public macOS SDK. Vendor a minimal copy from a stable Apple open-source release:

- Source: <https://github.com/apple-oss-distributions/xnu> at the `xnu-11215.61.5` tag (matching macOS Sequoia 15.x; verify struct compatibility with macOS 13/14 by inspection).
- Path in repo: `src/AgentRunner/private/ntstat.h` (clearly marked as vendored private API, with source URL/tag in a header comment).
- Only include the symbols actually used (struct definitions for `nstat_msg_hdr`, `nstat_msg_src_added`, `nstat_msg_src_counts`, `nstat_msg_src_removed`, the relevant `NSTAT_MSG_TYPE_*` and `NSTAT_SRC_REF_*` constants).

This is preferable to dynamic loading at runtime: structures are POD and stable enough across versions that a compile-time copy is reliable, and it keeps the build hermetic.

## 6. Error handling

- **Init failure** (`socket()`, `connect()`, or initial subscribe rejected) → `start()` throws → propagated to `AppDelegate` → menu shows "Network monitor unavailable", icon stays idle. No retry.
- **Runtime decode failure** (single message malformed) → log, drop the message, continue.
- **Socket death after start** → source self-stops and invokes `failureHandler` (see §4.2). SessionManager forwards to AppDelegate, which transitions to the unavailable menu state.
- **Sleep/wake** → reuse the v1.0.9 invariant: `stop()` is idempotent; `start()` resets all internal flags before opening a new socket. Apply the same pattern to `NTStatFlowSource`.

## 7. Removed code

The following files are deleted:

- `src/AgentRunner/NettopMonitor.swift`
- `src/AgentRunner/NettopParser.swift`
- `src/AgentRunner/NettopEvent.swift`
- `src/AgentRunner/Blocklist.swift` (only used by NettopParser; verify no other callers before deletion)

`AppDelegate` references to `nettop` (start, stop, sleep/wake handlers) replaced with `sessionManager.start()/stop()`.

## 8. Testing

### Unit tests (XCTest)

`MockFlowSource` injected into `SessionManager`:

- Single PID, single provider: flow started → cumulative bytes grow → state machine `idle → running` after rate threshold + `minHoldSeconds`.
- Multi PID × multi provider: each tracked independently, aggregate state reflects union.
- 5-tuple reuse: same `local/remote/proto` with different `flowID` produces independent Sessions.
- Flow ended: byte counts retained until 2 s tick GC sweeps stale sessions.

### Integration test

`NTStatFlowSource` running for ≥ 5 s on macOS 13 / 14 / 15 must emit at least one `flowStarted` event when traffic to a known LLM provider is generated.

### Performance regression

`xcrun xctrace record --template "Time Profiler" --launch ...` for a 5-minute idle window: cumulative CPU time of AgentRunner process must be < 2 s.

## 9. Migration plan

Single PR. The branch deletes nettop code and adds ntstat code in one commit (or a small commit series within one PR). git history serves as rollback path.

## 10. Out of scope (explicit non-goals)

- FSEvents / transcript watching
- Multi-agent transcript path config
- Provider-IP-only filter mode (future addition only if measured noise from `external` filter is excessive)
- Auto-update / Sparkle integration changes
- UI redesign

## 11. Open implementation details (deferred to plan phase)

- Exact subscription request flags for `nstat_msg_add_all_srcs` (TCP only? UDP also? `NSTAT_FILTER_*` choice).
- Whether to use `DispatchSourceRead` on the control socket vs a dedicated thread.
- Mapping from ntstat process-name truncation to a stable string for ProviderRegistry consumers.
- Exact `flowID` source — `nstat_src_ref_t` is the obvious choice; verify it does not get reused within a session.

These are answered in the implementation plan, not here.
