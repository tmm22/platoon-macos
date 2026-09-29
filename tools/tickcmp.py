#!/usr/bin/env python3
"""Compare two tick dumps (emu --tickdump vs platoon-headless --tickdump).
usage: tickcmp.py A B HEXLEN [--base HEXADDR] [--skip-a N] [--skip-b N] [--ignore HEXOFF[-HEXOFF],...] [--max N]
Records are [u32 frame][LEN bytes]. Ticks are aligned by index (after skips). Prints the first differing ticks
with the differing byte addresses (base + offset) and values."""
import sys, argparse, struct
ap = argparse.ArgumentParser()
ap.add_argument('a'); ap.add_argument('b'); ap.add_argument('len')
ap.add_argument('--base', default='0'); ap.add_argument('--skip-a', type=int, default=0); ap.add_argument('--skip-b', type=int, default=0)
ap.add_argument('--ignore', default=''); ap.add_argument('--max', type=int, default=5)
o = ap.parse_args()
L = int(o.len, 16); base = int(o.base, 16)
ign = set()
for part in filter(None, o.ignore.split(',')):
    lo, _, hi = part.partition('-'); lo = int(lo, 16); hi = int(hi, 16) if hi else lo
    ign.update(range(lo, hi + 1))
def recs(p):
    d = open(p, 'rb').read(); n = len(d) // (4 + L)
    return [(struct.unpack('<I', d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]
A = recs(o.a)[o.skip_a:]; B = recs(o.b)[o.skip_b:]
print(f'{len(A)} ticks in A, {len(B)} ticks in B')
shown = 0
for i, ((fa, da), (fb, db)) in enumerate(zip(A, B)):
    diff = [k for k in range(L) if da[k] != db[k] and k not in ign]
    if diff:
        print(f'tick {i}: frame A {fa} / B {fb}: {len(diff)} bytes differ')
        for k in diff[:24]: print(f'   ${base+k:06x} (+{k:x}): A={da[k]:02x} B={db[k]:02x}')
        shown += 1
        if shown >= o.max: break
if not shown: print('all compared ticks identical')
