#!/usr/bin/env python3
"""Generate DMG background image with drag-to-install hint.

Output: docs/dmg_bg.png — 600×400 with arrow + instructions.
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "docs", "dmg_bg.png")

W, H = 600, 400
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
# Icons will be placed at ~ (150, 220) and (450, 220) in a 600x400 window
arrow_y = 220
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

# Footer hint
hint = "First launch: right-click the app → Open (Gatekeeper bypass)"
f_hint = font(11)
hw, hh = d.textbbox((0, 0), hint, font=f_hint)[2:]
d.text(((W - hw) / 2, H - 36), hint, fill=ACCENT, font=f_hint)

img.save(OUT)
print(f"DMG bg → {OUT} ({W}x{H})")
