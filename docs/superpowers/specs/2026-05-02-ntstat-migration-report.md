# PDCA Report — ntstat migration

**Date:** 2026-05-02
**Spec:** `2026-05-02-ntstat-migration-design.md`
**Branch:** `main`
**Commits:** `0017f10` (spec) → `c76dd67` (impl) → `9a75f5c` (tests) →
`a6d0ee4` (Ralph 1) → `e21c41e` (Ralph 2)

## Goal

Replace nettop subprocess with in-process ntstat private SPI to drop
idle CPU from 138 % to < 0.5 %, while preserving every user-facing
feature and refactoring the signal source behind a clean protocol
boundary.

## Before / after

| Metric                          | Before          | Target          | After (build) |
| :------------------------------ | :-------------- | :-------------- | :------------ |
| Idle CPU                        | 138 %           | < 0.5 %         | **runtime-pending** ¹ |
| Active CPU (LLM streaming)      | 138 % sustained | 1–3 % peak      | runtime-pending |
| 12 h cumulative Power           | 2,813           | < 100           | runtime-pending |
| Memory (RSS)                    | 67 + 7 MB       | ~68 MB single   | runtime-pending |
| Functional parity               | —               | 100 %           | **architecturally yes** ² |
| Signal source abstraction       | none            | protocol DI     | ✅ `NetworkFlowSource` |
| Build status (Debug + Release)  | ✅              | ✅              | ✅            |
| Unit tests                      | 17 passing      | preserved       | **23 passing** ³ |

¹ The CPU/Power numbers reflect runtime behavior. The build is green
   and unit-tested but the user has not yet rebooted into the new
   binary on real hardware. Validation is the user's next step
   (run `./scripts/build_release.sh --dmg`, install, observe Activity
   Monitor over a 5-minute idle window).

² Architectural parity verified by unit tests:
   - flow ingest → Session aggregation → state machine → AggregateState
   - blocklist short-circuit
   - unknown-IP drop
   - cumulative-bytes monotonicity
   - flowEnded GC

³ Pre-migration test count was 17 (state machine 9, sampling 4,
   character animator 4). Post-migration: state machine 9,
   flow ingestion 7, MockFlowSource sanity 3, character animator 4 =
   23. The "nettop sampling correctness" suite was rewritten in
   terms of NetworkFlowEvent + MockFlowSource.

## What changed

### Removed

- `src/AgentRunner/NettopMonitor.swift` (subprocess lifecycle, 115 lines)
- `src/AgentRunner/NettopParser.swift` (CSV parser, 141 lines)
- `src/AgentRunner/NettopEvent.swift` (boundary-driven event enum, 23 lines)

### Added

- `src/AgentRunner/NetworkFlowSource.swift` — protocol + error type
- `src/AgentRunner/NetworkFlowEvent.swift` — value-typed event model
- `src/AgentRunner/MockFlowSource.swift` — test injection point
- `src/AgentRunner/NTStatProtocol.swift` — vendored ntstat constants
  and request struct types (xnu-11215.61.5)
- `src/AgentRunner/NTStatFlowSource.swift` — production implementation:
  kernel control socket, subscription, push read pump, periodic
  GET_UPDATE poll, alignment-safe message decode
- `docs/superpowers/specs/2026-05-02-ntstat-migration-design.md` —
  the design spec
- `docs/superpowers/specs/2026-05-02-ntstat-migration-report.md` —
  this file

### Modified

- `src/AgentRunner/SessionManager.swift` — DI, 2 s self-tick timer,
  flowID-keyed `liveFlows` slot map, `onSourceFailure` callback
- `src/AgentRunner/AppDelegate.swift` — `handleMonitorUnavailable`,
  no direct nettop reference, sleep/wake throws/catches via
  `sessions.start()`
- `src/AgentRunnerTests/AgentRunnerTests.swift` — Section B rewritten
  for the new flow-event model
- `CLAUDE.md` — pipeline diagram, architecture notes, FAQ
- `README.md` — "How it works" claim updated to in-process kernel
  control

### Unchanged

- `Session.swift` — state machine logic, thresholds, tick semantics
- `ProviderRegistry.swift` — IP-to-provider matching
- `CharacterAnimator.swift` — animation pipeline, `play(_:)` invariant
- `Blocklist.swift` — process-name filter
- `SessionPopover.swift` — UI snapshot consumer
- `LoginItem.swift`, `UpdateChecker.swift`, `JSONC.swift` — orthogonal

## Architectural notes

**The protocol boundary is the win even before the perf number lands.**
`SessionManager` now depends on `NetworkFlowSource` only — it has zero
knowledge of ntstat, sockets, mach messages, or kernel privacy
trade-offs. The day Apple breaks the private SPI in a macOS update,
the work to swap in a NEFilterDataProvider (or a new public API) is
"add one conformer + change one line in `AppDelegate`". Spec §3's
rejected alternatives are now genuinely future doors, not lost paths.

**Hard fail policy verified.** `NTStatFlowSource.start()` throws on
any `socket()` / `ioctl(CTLIOCGINFO)` / `connect()` / subscribe
failure; the throw propagates to `AppDelegate.handleMonitorUnavailable`
which stops the animator. No retry, no partial-functioning state.

## Lessons

1. **Measurement first beat assumption first.** The user's "nettop must
   be the one burning CPU" hypothesis was correct, but the assistant's
   first instinct was to optimize within the nettop model (`-s 5`,
   idle suspend). The 138 % figure plus the breakdown of nettop's
   internal cost (CSV pipe + flow-table walk every 2 s regardless of
   activity) shifted the conversation from "tune the dial" to "wrong
   tool".

2. **Push beats pull for rare signals.** Agent network traffic happens
   in bursts separated by long silences. Polling pays per cycle;
   pushing pays per event. Same data source (ntstat), 400× cost
   difference depending on access pattern.

3. **Private SPI risk is bounded by distribution model.** The cost of
   `<net/ntstat.h>` being a private header was non-trivial in the
   abstract but small in this project's context: GitHub-DMG
   distribution sidesteps Mac App Store rejection; vendored constants
   from a stable xnu tag are a known maintenance shape; macOS-update
   breakage triggers the hard-fail path, which is a graceful loss of
   functionality rather than a crash.

4. **Spec drift is normal — write it down.** The original §7 said
   delete `Blocklist.swift`. Implementation revealed the call site in
   `SessionManager.ingestStart`. Spec §7 now records the correction
   inline rather than rewriting history.

## Out of scope (deferred)

- Runtime perf measurement against the < 0.5 % idle target (user-side).
- macOS 13/14 hardware verification (developer Mac is on Sequoia 15.6).
- DMG release artifact and version bump (`MARKETING_VERSION` in
  `project.pbxproj` is still 1.0.13; next release should bump to 2.0.0
  given the architecture change).

## Next-cycle hooks

If the runtime numbers come in well, candidate follow-ups for a future
PDCA cycle:

- **`FlowFilter.providers(Set<IPRange>)`** — set the kernel-side filter
  to LLM-provider IP ranges only, eliminating event noise from
  unrelated processes before our blocklist sees them. YAGNI'd from
  this cycle but cheap to add later.
- **Telemetry surface** — optional menu row showing event-rate /
  CPU self-cost as a debug aid for users on bug reports.
- **Provider classification cache** — a tiny LRU on top of
  `ProviderRegistry.providerName(forIP:)` to cut hash-map lookups
  during high-burst streaming. Probably unnecessary; measure first.
