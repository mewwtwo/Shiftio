#!/usr/bin/env python3
"""Draws dmg-background.png: the plain picture behind the app and the Applications shortcut in the installer window.
The window is 480 x 300 points; the picture is 2x (960 x 600, 144 dpi) so it is sharp on Retina screens."""
from PIL import Image, ImageDraw, ImageFont

S = 2
W, H = 480 * S, 300 * S
img = Image.new("RGB", (W, H), (246, 246, 248))
d = ImageDraw.Draw(img)
ink = (160, 160, 168)

# A thin arrow between the two icons (their centres are at x = 130 and 350, y = 150 points).
y = 150 * S
x0, x1 = 198 * S, 282 * S
d.line((x0, y, x1, y), fill=ink, width=2 * S)
d.line((x1 - 10 * S, y - 10 * S, x1, y), fill=ink, width=2 * S)
d.line((x1 - 10 * S, y + 10 * S, x1, y), fill=ink, width=2 * S)

def font(size, bold=False):
    for path, index in (("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0), ("/Library/Fonts/Arial Bold.ttf" if bold else "/Library/Fonts/Arial.ttf", 0)):
        try:
            return ImageFont.truetype(path, size * S, index=index)
        except OSError:
            continue
    return ImageFont.load_default()

text = "Drag Shiftio to Applications"
f = font(13, bold=True)
w = d.textlength(text, font=f)
d.text(((W - w) / 2, 44 * S), text, font=f, fill=(128, 128, 136))

img.save("dmg-background.png", dpi=(144, 144))
print("dmg-background.png", img.size)
