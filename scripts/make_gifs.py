#!/usr/bin/env python3
"""Generate animated GIFs for README from sprite imagesets.

Each GIF is upscaled 4x (nearest) for crisp pixels on GitHub.
Frame timings match CharacterAnimator.swift logic.
"""
import os
from PIL import Image

# Resolve paths relative to this script — works in any clone location.
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "src", "AgentRunner", "Assets.xcassets")
OUT = os.path.join(ROOT, "docs", "gifs")
HERO = os.path.join(ROOT, "docs", "gifs", "hero.gif")
SCALE = 2   # 2x of source pixels — README readability without dominating the page

os.makedirs(OUT, exist_ok=True)


def load(prefix, n):
    out = []
    for i in range(n):
        p = os.path.join(ASSETS, f"{prefix}_{i}.imageset", f"{prefix}_{i}.png")
        out.append(Image.open(p).convert("RGBA"))
    return out


UNIFORM_H = 60   # all GIFs use this canvas height (60 = 56 char + 4 pad) — uniform row height in README


def normalize_canvas(frames, pad=2, target_h=UNIFORM_H):
    """Center horizontally + bottom-align on a uniform canvas.
    target_h forces a consistent height across animations so README rows match."""
    w = max(f.width for f in frames) + pad * 2
    h = max(target_h, max(f.height for f in frames) + pad * 2)
    out = []
    for f in frames:
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        x = (w - f.width) // 2
        y = h - f.height - pad
        canvas.paste(f, (x, y), f)
        out.append(canvas)
    return out


def upscale(frames, factor=SCALE):
    return [f.resize((f.width * factor, f.height * factor), Image.NEAREST) for f in frames]


def save_gif(name, frames, duration_ms):
    """Save with transparent background. duration is per-frame ms."""
    path = os.path.join(OUT, f"{name}.gif")
    converted = []
    for f in frames:
        p = f.convert("RGBA")
        alpha = p.split()[3]
        rgb = p.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=255)
        # Build alpha mask without using Image.eval (hook blocks eval-named API).
        mask = alpha.point(lambda a: 255 if a <= 8 else 0)
        rgb.paste(255, mask)
        rgb.info["transparency"] = 255
        converted.append(rgb)

    converted[0].save(
        path,
        save_all=True,
        append_images=converted[1:],
        duration=duration_ms,
        loop=0,
        disposal=2,
        transparency=255,
        optimize=False,
    )
    print(f"  -> {path} ({len(frames)} frames @ {duration_ms}ms)")


def make(name, frames, duration_ms):
    print(f"{name}: base {frames[0].size} x{len(frames)}")
    frames = normalize_canvas(frames)
    frames = upscale(frames)
    save_gif(name, frames, duration_ms)


# Base states
make("idle",     load("runner_idle", 4),  250)
make("running",  load("runner_run", 6),   100)
make("tooling",  load("runner_dig", 8),   500)
make("thinking", load("runner_climb", 4), 300)   # already rotated -> crawl
make("rest",     load("runner_rest", 2),  2500)

# Jump (thinking 애니메이션) — up 0→3, hover loop 0↔1 ×3, down 3→0
jump_up = load("runner_trick_jump", 4)
jump_hold = load("runner_trick_jump_hold", 2)
jump_down = list(reversed(jump_up))
jump_frames = jump_up + jump_hold * 3 + jump_down
make("jump", jump_frames, 167)

# Combos (only three-hit remains)
make("three-hit", load("runner_combo_3hit", 17), 100)

# Ultimate (only supreme remains) — hold last frame ~1s for finisher impact
supreme_frames = load("runner_ultimate_supreme", 25)
supreme_frames = supreme_frames + [supreme_frames[-1]] * 8
make("supreme", supreme_frames, 120)

# Hero (top of README) — same 2x scale as the rest
hero = upscale(normalize_canvas(load("runner_run", 6)), factor=SCALE)
hero_conv = []
for f in hero:
    p = f.convert("RGBA")
    alpha = p.split()[3]
    rgb = p.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=255)
    mask = alpha.point(lambda a: 255 if a <= 8 else 0)
    rgb.paste(255, mask)
    rgb.info["transparency"] = 255
    hero_conv.append(rgb)
hero_conv[0].save(
    HERO,
    save_all=True,
    append_images=hero_conv[1:],
    duration=120,
    loop=0,
    disposal=2,
    transparency=255,
    optimize=False,
)
print(f"hero -> {HERO}")
