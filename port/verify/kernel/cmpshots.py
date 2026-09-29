#!/usr/bin/env python3
"""cmpshots.py DIRA DIRB [--quiet]: compare same-named PNGs; print per-file differing pixel count, summary."""
import sys, os
from PIL import Image, ImageChops
a, b = sys.argv[1], sys.argv[2]
quiet = '--quiet' in sys.argv
names = sorted(n for n in os.listdir(a) if n.endswith('.png') and os.path.exists(os.path.join(b, n)))
same = 0; bad = []
for n in names:
    ia = Image.open(os.path.join(a, n)).convert('RGB'); ib = Image.open(os.path.join(b, n)).convert('RGB')
    if ia.size != ib.size: bad.append((n, -1)); continue
    d = ImageChops.difference(ia, ib).convert('L').point(lambda v: 255 if v else 0)
    c = 0 if d.getbbox() is None else d.histogram()[255]
    if c == 0: same += 1
    else: bad.append((n, c))
print(f'{same}/{len(names)} identical')
for n, c in bad[: (1000 if not quiet else 20)]: print(f'  DIFF {n}: {c} px')
