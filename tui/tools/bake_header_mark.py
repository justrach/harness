#!/usr/bin/env python3
"""Bake assets/codegraff-mark.svg into braille rows for the TUI session header.

Usage: bake_header_mark.py <rasterized-mark.png> [cols] [rows]

Rasterize the SVG first (macOS: qlmanage -t -s 512 -o out assets/codegraff-mark.svg).
Prints one braille string per row; dots are square, so use cols*2 == rows*4.
"""
import sys

from PIL import Image

src = sys.argv[1]
cols = int(sys.argv[2]) if len(sys.argv) > 2 else 6
rows = int(sys.argv[3]) if len(sys.argv) > 3 else 3

im = Image.open(src).convert("L")
dark = im.point(lambda v: 255 if v < 140 else 0)
x0, y0, x1, y1 = dark.getbbox()
side = max(x1 - x0, y1 - y0)
cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
dark = dark.crop((int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2)))
w, h = cols * 2, rows * 4
small = dark.resize((w, h), Image.BOX)

BITS = [(0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08), (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80)]
for r in range(rows):
    line = ""
    for c in range(cols):
        m = 0
        for dx, dy, bit in BITS:
            if small.getpixel((c * 2 + dx, r * 4 + dy)) >= 90:
                m |= bit
        line += chr(0x2800 + m)
    print(line)
