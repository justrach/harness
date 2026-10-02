#!/usr/bin/env python3
"""Bake the Codegraff logo into a character grid for the TUI welcome art.

Usage: bake_mark.py <codegraff-logo.png> [width] > art.txt

Classes: '#' ring stroke, 'c' the </> glyph, 'o' orange squares, 'g' gray squares.
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

src = sys.argv[1]
width = int(sys.argv[2]) if len(sys.argv) > 2 else 112

im = np.array(Image.open(src).convert("RGBA"))
alpha = im[..., 3]
mask = alpha > 100
ys, xs = np.nonzero(mask)
x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
r, g, b = (im[..., i].astype(int) for i in range(3))

# 8-connected components.
label = np.zeros(mask.shape, dtype=np.int32)
comps = []
for y, x in zip(*np.nonzero(mask)):
    if label[y, x]:
        continue
    n = len(comps) + 1
    q = deque([(y, x)])
    label[y, x] = n
    pts = []
    while q:
        cy, cx = q.popleft()
        pts.append((cy, cx))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not label[ny, nx]:
                    label[ny, nx] = n
                    q.append((ny, nx))
    comps.append(pts)

ring = max(range(len(comps)), key=lambda i: len(comps[i]))
rp = np.array(comps[ring])
cy, cx = (rp[:, 0].min() + rp[:, 0].max()) / 2, (rp[:, 1].min() + rp[:, 1].max()) / 2
span = max(rp[:, 0].max() - rp[:, 0].min(), rp[:, 1].max() - rp[:, 1].min())

cls = np.zeros(mask.shape, dtype="U1")
cls[:] = " "
for i, pts in enumerate(comps):
    p = np.array(pts)
    if i == ring:
        c = "#"
    else:
        mr, mg, mb = r[p[:, 0], p[:, 1]].mean(), g[p[:, 0], p[:, 1]].mean(), b[p[:, 0], p[:, 1]].mean()
        if mr > 140 and mr - mb > 50:
            c = "o"
        elif np.hypot(p[:, 0].mean() - cy, p[:, 1].mean() - cx) < span * 0.22:
            c = "c"
        else:
            c = "g"
    cls[p[:, 0], p[:, 1]] = c

# Box-downsample; each cell takes the class with the most coverage.
scale = (x1 - x0) / width
height = round((y1 - y0) / scale)
out = []
for j in range(height):
    row = ""
    for i in range(width):
        ya, yb = int(y0 + j * scale), max(int(y0 + (j + 1) * scale), int(y0 + j * scale) + 1)
        xa, xb = int(x0 + i * scale), max(int(x0 + (i + 1) * scale), int(x0 + i * scale) + 1)
        block = cls[ya:yb, xa:xb].ravel()
        area = block.size
        counts = {k: int((block == k).sum()) for k in "#coG".replace("G", "g")}
        best = max(counts, key=counts.get)
        row += best if counts[best] / area >= 0.35 else " "
    out.append(row.rstrip())
print("\n".join(out))
