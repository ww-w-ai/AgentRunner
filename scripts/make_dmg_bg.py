#!/usr/bin/env python3
"""Generate DMG background image with drag-to-install hint.

Output: docs/dmg_bg.png — 600×400 with arrow + instructions.
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "docs", "dmg_bg.png")

W, H = 600, 460
BOTTOM_SAFE = 56  # Finder pathbar/statusbar reserves ~28px on modern macOS — keep margin
BG = (250, 250, 252, 255)
ACCENT = (90, 100, 120, 255)
ACCENT_LIGHT = (90, 100, 120, 80)
TEXT = (60, 70, 90, 255)

img = Image.new("RGBA", (W, H), BG)
d = ImageDraw.Draw(img)


def font(size, bold=False):
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


# Title
title = "Install AgentRunner"
f_title = font(26, bold=True)
tw, th = d.textbbox((0, 0), title, font=f_title)[2:]
d.text(((W - tw) / 2, 36), title, fill=TEXT, font=f_title)

# Subtitle
subtitle = "Drag the app icon onto the Applications folder"
f_sub = font(14)
sw, sh = d.textbbox((0, 0), subtitle, font=f_sub)[2:]
d.text(((W - sw) / 2, 72), subtitle, fill=ACCENT, font=f_sub)

# Arrow (between icon positions)
# Icons will be placed at ~ (150, 240) and (450, 240) in a 600x460 window
arrow_y = 240
arrow_start_x = 230
arrow_end_x = 370
shaft_thickness = 6

# Shaft
d.rectangle(
    [(arrow_start_x, arrow_y - shaft_thickness // 2),
     (arrow_end_x - 18, arrow_y + shaft_thickness // 2)],
    fill=ACCENT,
)
# Head (filled triangle)
d.polygon(
    [(arrow_end_x - 24, arrow_y - 18),
     (arrow_end_x, arrow_y),
     (arrow_end_x - 24, arrow_y + 18)],
    fill=ACCENT,
)

# Footer — how to launch (the trickiest step for menu bar apps).
# Stack upward from BOTTOM_SAFE so Finder's pathbar/statusbar can't clip text.
f_hint = font(10)
hint = "Look for the pixel character in your menu bar (top-right)"
hw = d.textbbox((0, 0), hint, font=f_hint)[2]
hint_y = H - BOTTOM_SAFE
d.text(((W - hw) / 2, hint_y), hint, fill=ACCENT, font=f_hint)

f_kbd = font(14, bold=True)
launch_step = "⌘ + Space  →  type \"AgentRunner\"  →  Enter"
lsw = d.textbbox((0, 0), launch_step, font=f_kbd)[2]
kbd_y = hint_y - 26
d.text(((W - lsw) / 2, kbd_y), launch_step, fill=TEXT, font=f_kbd)

f_launch = font(13)
launch_title = "After install — open with Spotlight:"
ltw = d.textbbox((0, 0), launch_title, font=f_launch)[2]
d.text(((W - ltw) / 2, kbd_y - 22), launch_title, fill=TEXT, font=f_launch)

img.save(OUT)
print(f"DMG bg → {OUT} ({W}x{H})")
