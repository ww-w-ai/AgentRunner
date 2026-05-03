# AgentRunner — Claude Code Working Guide

This file gives Claude Code (and any human contributor) the context needed to work productively on AgentRunner without re-discovering architectural decisions.

## Project Overview

**AgentRunner** — A 16-pixel hero lives in your macOS menu bar, animating in response to your AI agent's network traffic. RunCat for the AI agent era.

- **Language:** Swift / AppKit (no NSWindow — RunCat pattern)
- **Platform:** macOS 13+ (Ventura)
- **License:** Apache 2.0
- **Dependencies:** none — Swift standard library only
- **Pixel art:** rvros [Animated Pixel Hero](https://rvros.itch.io/animated-pixel-hero)

## Folder Structure

```
AgentRunner/                     # project root
├── src/                         # Xcode project (formerly AgentRunner/, renamed to avoid duplication)
│   ├── AgentRunner.xcodeproj
│   └── AgentRunner/             # target source folder (Xcode target name — do not rename)
│       ├── *.swift
│       └── Assets.xcassets/     # 50+ pixel sprite imagesets
├── docs/gifs/                   # README GIFs (hero + 8 animations)
├── scripts/
│   ├── build_release.sh         # Release build + DMG (ad-hoc signed, uses create-dmg)
│   ├── make_dmg_bg.py           # Generate docs/dmg_bg.png (drag-to-install hint)
│   └── make_gifs.py             # imageset → docs/gifs (project-internal paths only)
├── dist/                        # build artifacts (gitignored)
├── README.md                    # public English doc
└── LICENSE                      # Apache 2.0
```

## Core Architecture

### 1. NetworkFlowSource → Session → CharacterAnimator pipeline

```
NTStatFlowSource (in-process kernel control socket: ntstat private SPI)
  ↓ NetworkFlowEvent (.flowStarted / .flowUpdated / .flowEnded)
SessionManager.handle(event) [background queue]
  ↓ liveFlows[flowID] cumulative bytes; aggregated every 2s self-tick
Session.ingest() → bytesInRate / bytesOutRate → state machine evaluation
  ↓ on aggregate state change
CharacterAnimator.render(agg) [main thread]
  ↓ frame update
NSStatusItem.button.image
```

**Signal source is abstracted** behind the `NetworkFlowSource` protocol.
`SessionManager` knows nothing about ntstat — it consumes value-typed
`NetworkFlowEvent`s from any conformer. Tests inject `MockFlowSource`;
production wires `NTStatFlowSource(filter: .external)`.

**ntstat in-process, not nettop subprocess.** Pre-2.0 versions spawned
`/usr/bin/nettop -L 0 -t external -x -s 2` and parsed CSV. That hit
138% CPU on a developer Mac because nettop polls the full kernel flow
table every 2s. Since v2.0, AgentRunner talks to the same kernel
control (`com.apple.network.statistics`) directly — push semantics for
SRC_ADDED/REMOVED, periodic GET_UPDATE for byte counters, idle CPU near
zero. The vendored constants live in `NTStatProtocol.swift` (xnu
private API; see `docs/superpowers/specs/2026-05-02-ntstat-migration-design.md`).

**Subscription filter (v1.2.0):** uses `NStatFilter.externalProduction`
(`acceptCellular | acceptWiFi | acceptWired | useUpdateForAdd | providerNoZeroDeltas`)
per the migration spec. `useUpdateForAdd` makes the kernel deliver new
flows as a single SRC_UPDATE with descriptor inline, removing a
SRC_ADDED → getSrcDesc round-trip race that intermittently lost new
sessions in v1.1.x. The legacy round-trip path remains as fallback.

**Process name (v1.2.0):** descriptor's `pname[64]` field is unreliable
across xnu builds (sometimes empty, sometimes a version string set by
the userland process via `process.title`). `NTStatFlowSource` now calls
`proc_name(pid)` from libproc as the primary source and falls back to
the descriptor field on failure. Stable Apple API, robust against
descriptor layout drift.

### 2. Session state machine (`src/AgentRunner/Session.swift`)

| State     | Meaning                              | Entry condition                                                  |
| :-------- | :----------------------------------- | :--------------------------------------------------------------- |
| `idle`    | No activity                          | Initial / after sustained inactivity from any other state        |
| `running` | Active traffic                       | `bytesOutRate > 5000` (10 KB / 2s window) OR `bytesInRate > 200` |
| `scout`   | Data paused — peeking around         | `running` → 4s+ dip                                              |
| `tooling` | Wrap-up phase before idle            | `scout` → 15s+                                                   |

**Threshold rationale:** derived from analysis of 65 hours of transcripts across 4 projects (cache_read included on outbound):
- First LLM call outbound burst: 28~60 KB/s after compression
- Streaming inbound: p50 3~6 KB/s

`minHoldSeconds = 3.0` — every state except `idle` is held for 3 seconds before transitioning (prevents jitter).

### 3. CharacterAnimator (`src/AgentRunner/CharacterAnimator.swift`)

**Core principle: state and animation are decoupled.**

```swift
enum AnimID {
    // Loop animations (state-driven, can be replaced on state change)
    case idle, rest, scout, run
    // One-shot animations (uninterruptible — must play to completion)
    case jump, threeHit, supreme, toolingWrapUp
}
```

**Single entry point: `play(_ anim: AnimID)`.** All animation transitions go through this function — no other code path mutates the active animation.

**One-shot guarantee:**
- In `render(agg)`, if `currentAnim.isOneShot`, return immediately. State updates still happen, but the visual playback continues.
- When the one-shot finishes (frame index reaches the end), `onAnimationComplete()` reads the current state and decides the next animation.
- Therefore, once a jump / combo / ultimate / wrap-up starts, it always plays to the end.

**Loop boundary transition checks:**
- End of `run` cycle: `tryFireCombo()` (after 10s+ continuous running)
- End of `idle` cycle: `play(.rest)` after 30s+ accumulated idle

**Jump (idle→running entry):** 16 frames @ 167ms = **2.67s** (jump 4 + hold×5 + fall 2). 1.67s of airborne hover.

**Combo counter:**
- `activeSinceForCombo`: counts from running entry
- `enteringRunning = (oldState != .running && agg.state == .running)` — reset every time we enter `.running`. Prevents "sudden combo after scout→running" caused by stale accumulated counter.
- Jump entry pushes the counter forward by jump duration → combo first fires exactly 10s of running *after* the jump completes.

**Frame intervals:**
- `idle`: 0.25s | `rest`: 2.5s (5s full cycle) | `scout`: 0.30s
- `run`: 50~350ms (logarithmic mapping from `bytesInRate`)
- `jump`: 0.167s | `threeHit`: 0.10s | `supreme`: 0.12s | `toolingWrapUp`: 0.25s

**`extendToMinDuration`:** short one-shots (threeHit, supreme) are padded to ≥3s by holding the last frame. Never loop — looping creates a "double-play" feel that breaks immersion.

### 4. Provider matching (`src/AgentRunner/ProviderRegistry.swift`)

- Built-in 11: Anthropic, OpenAI, Google, OpenRouter, xAI, DeepSeek, Cohere, Mistral, Groq, Together, Perplexity
- User config: `~/Library/Application Support/AgentRunner/providers.jsonc` (JSONC format)
- **First launch:** seed file written via `writeSeedFile()`, in-memory `seedProviders` constant returned
- **Subsequent launches:** the file is the single source of truth. Edit + menu → Reload Providers (⌘R)
- **Parse failure:** falls back to seed providers, file untouched (so user can fix and reload)
- **IP matching:** `dig +short` resolves hostnames. Refresh triggers: app start, periodic timer, system wake (`AppDelegate.receiveWake` → `registry.refresh()`), and on network path change (NWPathMonitor inside `ProviderRegistry`, debounced 1s) — covers Wi-Fi switch, VPN toggle, LTE handoff. `isOnline` flag is also exposed for `UpdateChecker` to short-circuit when offline.
- **Refresh interval (v1.2.0):** dynamic fast/slow. Fast 60s while warming the cache, slow 600s in steady state. New install: 1 hour fast → slow. Warm install: 10 min fast → slow. Cumulative tracked in `UserDefaults` (`AgentRunner.cumulativeRefreshMinutes`, +1 per fast tick, +10 per slow). Doubles as a rough total-runtime indicator.
- **IP cache (v1.2.0):** disk-persisted at `~/Library/Application Support/AgentRunner/ip_cache.json`. 90-day TTL per entry. Hydrated on `start()` so cold-start doesn't miss flows whose IPs aren't yet in `dig` output. CDN IP rotation tolerated by the long TTL — re-seen IPs get their `expiresAt` extended.
- **⚠️ Adding new built-ins via `seedProviders` constant alone won't reach existing users** — their `providers.jsonc` was already written. A migration step (merge missing built-ins) would be needed.

### 5. SessionPopover (left-click) — race-free

- `SessionManager.sessionSnapshot()` copies state into `SessionSnapshot` value types **inside `queue.sync`** before returning
- The main thread never reads the `Session` reference type directly (this previously caused a torn-read race condition)

## Build / Release

```bash
# Debug build (verification)
xcodebuild -project src/AgentRunner.xcodeproj -scheme AgentRunner -configuration Debug build

# Release build + DMG
./scripts/build_release.sh --dmg
# Outputs: dist/AgentRunner.app, dist/AgentRunner-<version>.dmg

# Regenerate README GIFs
python3 scripts/make_gifs.py
```

**Code signing:** ad-hoc (`--sign -`) by default. Set `CODESIGN_IDENTITY` env var if you have an Apple Developer ID.

**Version:** `MARKETING_VERSION` in `src/AgentRunner.xcodeproj/project.pbxproj` (6 occurrences — keep in sync). Extracted via PlistBuddy in the build script.

## Coding Conventions

- Logging: `NSLog("AgentRunner: ...")` — visible in Console.app
- Bundle ID: see project settings; `SMAppService` / Login Item depend on it
- **Zero-dependency principle.** Adding a third-party library should be debated, not casual. Even auto-update (Sparkle) was deliberately avoided. `UpdateChecker` does a HEAD request against `https://github.com/<slug>/releases/latest` and reads the 302 `Location` header to extract the latest tag — avoids the GitHub REST API's 60/h per-IP rate limit (a real risk for users behind shared NAT). Asset URLs are constructed from naming convention (`AgentRunner-X.Y.Z.dmg`).
- `// MARK: -` for section headers in Swift files

## What NOT to Do

- **Never mutate animation state outside `play(_:)`.** Don't write `comboFrames = []` or any direct frame array assignment. The single-entry-point invariant is what guarantees one-shot animations are never cut short.
- **Never expose `Session` (reference type) to the main thread.** Always go through `sessionSnapshot()` which returns `SessionSnapshot` value copies.
- **Never commit build/release artifacts** (`dist/`, `*.dmg`, `*.app`) — they're in `.gitignore`.
- **Never hardcode absolute paths** (`/Users/...`). All paths in scripts must be derived from `__file__` (Python) or relative to script dir (shell).
- **Never leave a "shutdown" flag set after `stop()`.** Idempotent `stop()` + `start()` resets state — sleep/wake cycle relies on this. The historical bug (v1.0.9) was `NettopMonitor.isShuttingDown` not getting reset; the same pattern applies to `NTStatFlowSource.isShuttingDown` and any future signal source. Reset on the next `start()`, not at the end of `stop()`.

## FAQ — Decisions That Should Not Be Re-Litigated

- **Why network traffic to known LLM hosts?** Ground truth of agent activity. No permissions, no proxy, no certificates needed. Heuristics on file/clipboard/process activity would be both more invasive and less accurate. **Why ntstat directly instead of nettop subprocess?** Same data source, but in-process push semantics drop idle CPU from 138% to near-zero — see the design spec.
- **Why AppKit instead of SwiftUI?** Menu bar apps are NSStatusItem-native. AppKit gives precise control with ~20 MB idle memory footprint (flat regardless of session count). SwiftUI for menu bar would add overhead with no UX win.
- **Why no NSWindow / Preferences window?** RunCat-style minimalism. Pref windows add memory cost for a feature used rarely. The menu (right-click) handles all settings.
- **Why was the `enabled` field removed from providers.jsonc guidance?** Disabling = comment out the line with `//`. One mechanism is simpler than two. The struct still tolerates the field for backward compatibility.
- **Why is `transform_sprites.py` local-only?** Its input is outside the project (`~/Downloads/Adventurer-1.5/`), so it can't run on a clone. `make_gifs.py` (imageset → docs/gifs/) is project-internal and shipped.

## Starting a New Session

1. `git status` to see current state
2. Read this file's "What NOT to Do" before any animation/Session changes
3. For animation tweaks: experiment in `CharacterAnimator.swift` only, always via `play(_:)`
4. Run a Debug build before reporting changes complete
