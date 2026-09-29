#!/usr/bin/env python3
"""Checks a run that travelled back in time (M9 rewind / M8 checkpoint retry) against the uninterrupted run.
usage: travelcheck.py BASEDIR TESTDIR
Both dirs come from roundtrip.sh-style runs (hash.txt = 'frame N hash H' per frame of ALL chip RAM, t<pc>.bin /
v<pc>.bin tick dumps of 4+$78 / 4+$40 byte records). After a jump back to frame F the test run replays the same
script, so EVERY frame hash it prints must equal the base run's hash of that frame, and each tick dump must be
base[:i] + base[j:] (the ticks before the jump, then the base's ticks again from the snapshot's frame)."""
import sys, os, struct
base, test = sys.argv[1], sys.argv[2]
ok = True
B = {}
for l in open(f'{base}/hash.txt'):
    p = l.split(); B[int(p[1])] = p[3]
n = jumps = 0; last = -1
for l in open(f'{test}/hash.txt'):
    p = l.split(); f, h = int(p[1]), p[3]; n += 1
    if f <= last: jumps += 1
    last = f
    if B.get(f) != h:
        print(f'hash mismatch at frame {f}'); ok = False; break
print(f'{n} frame hashes checked, {jumps} jump(s) back, {"all equal to the base run" if ok else "MISMATCH"}')
for fn in sorted(os.listdir(test)):
    if not fn.endswith('.bin'): continue
    L = 0x78 if fn.startswith('t') else 0x40
    def recs(p):
        d = open(p, 'rb').read(); k = len(d) // (4 + L)
        return [(struct.unpack('<I', d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(k)]
    b, t = recs(f'{base}/{fn}'), recs(f'{test}/{fn}')
    if not b and not t: continue
    splits = [i for i in range(1, len(t)) if t[i][0] < t[i-1][0]]
    good = True; pos = 0; seg_start = 0; segs = []
    # walk segments: each segment of t must be a contiguous run of b starting at the first b record of its frame
    bounds = [0] + splits + [len(t)]
    for s, e in zip(bounds, bounds[1:]):
        if s == e: continue
        f0 = t[s][0]
        cands = [j for j in range(len(b)) if b[j][0] == f0 and b[j][1] == t[s][1]]
        if not cands: good = False; break
        j = cands[0]
        if b[j:j + (e - s)] != t[s:e]: good = False; break
        segs.append((s, e, j))
    last_seg = segs[-1] if segs else None
    if good and last_seg and last_seg[2] + (last_seg[1] - last_seg[0]) != len(b): good = False   # ends with the base
    print(f'{fn}: {len(t)} ticks in {len(segs)} segment(s) {"match the base run" if good else "MISMATCH"}')
    ok = ok and good
print('PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
