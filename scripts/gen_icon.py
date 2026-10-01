#!/usr/bin/env python3
"""Regenerates Resources/AppIcon.png (1024x1024). Needs Pillow. Only for editing the icon; the .icns is built by make_app.sh."""
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 2                                   # supersample for smooth edges
W = S * SS

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# background: macOS-style rounded square with a vertical gradient
bg = Image.new("RGB", (W, W))
px = ImageDraw.Draw(bg)
top, bottom = (58, 64, 92), (24, 27, 44)
for y in range(W):
    px.line([(0, y), (W, y)], fill=lerp(top, bottom, y / W))
mask = Image.new("L", (W, W), 0)
margin = int(W * 0.055)
ImageDraw.Draw(mask).rounded_rectangle([margin, margin, W - margin, W - margin], radius=int(W * 0.225), fill=255)

icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
icon.paste(bg, (0, 0), mask)
d = ImageDraw.Draw(icon)

# three "status" bars: green / yellow / red, like the classification rows
colors = [(72, 199, 116), (250, 204, 21), (239, 83, 80)]
x0, x1 = int(W * 0.24), int(W * 0.76)
bar_h, gap = int(W * 0.085), int(W * 0.045)
y = int(W * 0.50)
for i, c in enumerate(colors):
    yy = y + i * (bar_h + gap)
    length = [1.0, 0.78, 0.55][i]
    d.rounded_rectangle([x0, yy, x0 + int((x1 - x0) * length), yy + bar_h], radius=bar_h // 2, fill=c)

# drop arrow above the bars
cx = W // 2
shaft_w = int(W * 0.07)
d.rounded_rectangle([cx - shaft_w // 2, int(W * 0.17), cx + shaft_w // 2, int(W * 0.37)], radius=shaft_w // 3, fill=(235, 238, 250))
d.polygon([(cx - int(W * 0.13), int(W * 0.34)), (cx + int(W * 0.13), int(W * 0.34)), (cx, int(W * 0.46))], fill=(235, 238, 250))

icon.resize((S, S), Image.LANCZOS).save("Resources/AppIcon.png")
print("wrote Resources/AppIcon.png")
