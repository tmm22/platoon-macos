#!/usr/bin/env python3
"""Checks a PLATOON_S2SLIDE_DUMP directory of the M25 room slide (owner: section2).
PASS when (1) a slide happened (sliding -> waitSwap -> idle in slide.log), (2) no slide frame has a dark seam
(a column inside the picture area x 16..304 that is < 30 % lit), (3) the frame after the overlay is removed shows
the game's own picture (not black) and (4) the last slide image equals that game frame except where things moved
(< 2 % of the pixels)."""
import os, re, sys
from PIL import Image
import numpy as np

d = sys.argv[1]
log = open(os.path.join(d, 'slide.log')).read().splitlines()
phases = [(int(re.match(r'f(\d+)', l).group(1)), l.split()[2]) for l in log]
ok = True
slides = [f for f, p in phases if p != 'idle']
idle = [f for f, p in phases if p == 'idle' and slides and f > slides[-1]]
if not slides or not idle:
    print('FAIL no complete slide in', d); sys.exit(1)
seams = []
for f in slides:
    p = os.path.join(d, 'f%d_slide.png' % f)
    if not os.path.exists(p): continue
    a = np.array(Image.open(p).convert('RGB')).astype(int).sum(2)
    lit = (a > 0).mean(0)
    dark = [x for x in range(16, 305) if lit[x] < 0.3]
    if dark: seams.append((f, dark[:4]))
if seams: ok = False; print('FAIL dark seams', seams[:5])
last = max(f for f in slides if os.path.exists(os.path.join(d, 'f%d_slide.png' % f)))
s = np.array(Image.open(os.path.join(d, 'f%d_slide.png' % last)).convert('RGB')).astype(int)
g = np.array(Image.open(os.path.join(d, 'f%d_game.png' % idle[0])).convert('RGB')).astype(int)
lit = (g.sum(2) > 0).mean()
diff = (np.abs(s - g).sum(2) > 0).mean()
if lit < 0.5: ok = False; print('FAIL game frame f%d after the slide is dark (%.0f %% lit)' % (idle[0], 100 * lit))
if diff > 0.02: ok = False; print('FAIL last slide image f%d vs game f%d: %.1f %% differ' % (last, idle[0], 100 * diff))
right = 'right true' in log[0]
print('%s %s slide f%d..f%d (%d frames), hand-over at f%d, last image vs game %.2f %% differ, game %.0f %% lit'
      % ('PASS' if ok else 'FAIL', 'right' if right else 'left', slides[0], slides[-1], len(slides), idle[0],
         100 * diff, 100 * lit))
sys.exit(0 if ok else 1)
