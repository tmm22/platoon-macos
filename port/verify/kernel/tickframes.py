#!/usr/bin/env python3
"""tickframes.py A B HEXLEN: list tick frame numbers side by side where they differ."""
import sys, struct
L = int(sys.argv[3], 16)
def fr(p):
    d = open(p, 'rb').read(); return [struct.unpack('<I', d[i:i+4])[0] for i in range(0, len(d) - L - 3, L + 4)]
a, b = fr(sys.argv[1]), fr(sys.argv[2])
n = min(len(a), len(b)); bad = [(i, a[i], b[i]) for i in range(n) if a[i] != b[i]]
print(f'{len(a)}/{len(b)} ticks; {n-len(bad)} same frame; first ticks A {a[:6]} B {b[:6]}')
for x in bad[:20]: print('  tick %d: A f%d B f%d' % x)
