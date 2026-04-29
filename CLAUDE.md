# AgentRunner — Claude Code Working Guide

This file gives Claude Code (and any human contributor) the context needed to work productively on AgentRunner without re-discovering architectural decisions.

## Project Overview

**AgentRunner** — A 16-pixel hero lives in your macOS menu bar, animating in response to your AI agent's network traffic. RunCat for the AI agent era.

- **Language:** Swift / AppKit (no NSWindow — RunCat pattern)
- **Platform:** macOS 13+ (Ventura)
- **License:** Apache 2.0 (matches RunCat)
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
│   ├── build_release.sh         # Release build + DMG (ad-hoc signed)
│   └── make_gifs.py             # imageset → docs/gifs (project-internal paths only)
├── dist/                        # build artifacts (gitignored)
├── README.md                    # public English doc
└── LICENSE                      # Apache 2.0
```

## Core Architecture

### 1. nettop → Session → CharacterAnimator pipeline

```
nettop (external process, 2s sampling)
  ↓ stdout lines
NettopParser.parse() → NettopEvent (.process / .connection)
  ↓
SessionManager.handle(event) [background queue]
  ↓ pendingSample accumulates, processed every 3s tick
Session.ingest() → bytesInRate / bytesOutRate → state machine evaluation
  ↓ on aggregate state change
CharacterAnimator.render(agg) [main thread]
  ↓ frame update
NSStatusItem.button.image
```

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
- **IP matching:** `dig +short` resolves hostnames, refreshed every 10 minutes
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

**Version:** `MARKETING_VERSION` in Build Settings (currently `1.0`). Extracted via PlistBuddy in the build script.

## Coding Conventions

- Logging: `NSLog("AgentRunner: ...")` — visible in Console.app
- Bundle ID: see project settings; `SMAppService` / Login Item depend on it
- **Zero-dependency principle.** Adding a third-party library should be debated, not casual. Even auto-update (Sparkle) was deliberately avoided in favor of direct GitHub Releases API calls.
- `// MARK: -` for section headers in Swift files

## What NOT to Do

- **Never mutate animation state outside `play(_:)`.** Don't write `comboFrames = []` or any direct frame array assignment. The single-entry-point invariant is what guarantees one-shot animations are never cut short.
- **Never expose `Session` (reference type) to the main thread.** Always go through `sessionSnapshot()` which returns `SessionSnapshot` value copies.
- **Never commit build/release artifacts** (`dist/`, `*.dmg`, `*.app`) — they're in `.gitignore`.
- **Never hardcode absolute paths** (`/Users/...`). All paths in scripts must be derived from `__file__` (Python) or relative to script dir (shell).

## FAQ — Decisions That Should Not Be Re-Litigated

- **Why nettop?** It's an OS tool — no permissions, no proxy, no certificates needed. Network traffic to known LLM hosts is the ground truth of agent activity. Heuristics on file/clipboard/process activity would be both more invasive and less accurate.
- **Why AppKit instead of SwiftUI?** Menu bar apps are NSStatusItem-native. AppKit gives precise control with ~25–30 MB memory footprint. SwiftUI for menu bar would add overhead with no UX win.
- **Why no NSWindow / Preferences window?** RunCat-style minimalism. Pref windows add memory cost for a feature used rarely. The menu (right-click) handles all settings.
- **Why was the `enabled` field removed from providers.jsonc guidance?** Disabling = comment out the line with `//`. One mechanism is simpler than two. The struct still tolerates the field for backward compatibility.
- **Why is `transform_sprites.py` local-only?** Its input is outside the project (`~/Downloads/Adventurer-1.5/`), so it can't run on a clone. `make_gifs.py` (imageset → docs/gifs/) is project-internal and shipped.
- **Why Apache 2.0?** Matches RunCat (our ancestor). The patent grant clause better protects OSS contributors than MIT.

## Starting a New Session

1. `git status` to see current state
2. Read this file's "What NOT to Do" before any animation/Session changes
3. For animation tweaks: experiment in `CharacterAnimator.swift` only, always via `play(_:)`
4. Run a Debug build before reporting changes complete
