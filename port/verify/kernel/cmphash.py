#!/usr/bin/env python3
"""cmphash.py EMULOG PORTLOG: compare 'frame N hash H' lines; report matching frames and divergent runs."""
import sys, re
def load(p):
    h = {}
    for l in open(p, errors='replace'):
        m = re.search(r'frame (\d+) hash ([0-9a-f]+)', l)
        if m: h[int(m.group(1))] = m.group(2)
    return h
a, b = load(sys.argv[1]), load(sys.argv[2])
fr = sorted(set(a) & set(b)); bad = [f for f in fr if a[f] != b[f]]
print(f'{len(fr) - len(bad)}/{len(fr)} frames equal')
runs = []
for f in bad:
    if runs and runs[-1][1] == f - 1: runs[-1][1] = f
    else: runs.append([f, f])
for r in runs[:30]: print(f'  differ {r[0]}-{r[1]}')
