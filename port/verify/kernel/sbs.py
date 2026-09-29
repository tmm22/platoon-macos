#!/usr/bin/env python3
"""sbs.py RUNDIR OUT.png FRAME... : stack emu|port side by side for each frame (rows), 2x2 max width."""
import sys
from PIL import Image, ImageChops
d, out, frames = sys.argv[1], sys.argv[2], sys.argv[3:]
rows = []
for f in frames:
    a = Image.open(f'{d}/emu/f{int(f):06d}.png').convert('RGB'); b = Image.open(f'{d}/port/f{int(f):06d}.png').convert('RGB')
    rows.append((a, b))
w, h = rows[0][0].size
c = Image.new('RGB', (w * 2 + 4, (h + 4) * len(rows)), (255, 0, 255))
for i, (a, b) in enumerate(rows):
    c.paste(a, (0, i * (h + 4))); c.paste(b, (w + 4, i * (h + 4)))
c.save(out)
