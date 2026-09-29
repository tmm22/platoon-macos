#!/usr/bin/env python3
"""diffbox.py A.png B.png: bounding box + per-row-band count of differing pixels (canvas coords)."""
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]).convert('RGB'); b = Image.open(sys.argv[2]).convert('RGB')
d = ImageChops.difference(a, b).convert('L').point(lambda v: 255 if v else 0)
print('bbox', d.getbbox())
w, h = d.size; px = d.load()
for y0 in range(0, h, 10):
    c = sum(1 for y in range(y0, min(h, y0 + 10)) for x in range(w) if px[x, y])
    if c: print(f'  rows {y0}-{y0+9}: {c}')
