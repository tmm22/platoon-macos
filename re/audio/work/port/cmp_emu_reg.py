#!/usr/bin/env python3
"""Compare the driver's Paula register stream of an emulator run (emu --reglog) with the port
(platoon-headless --audio-test --script S --reglog, S replaying the same API calls at the same frame numbers).
Only writes made by driver code ($2800-$40ff) are compared, in order. Frame check: writes made by `play`
($2990-$2d7f, $3eb4-$3ff8) must land in the same frame; writes made by API calls from main code or from the F10
handler after play (init/stop/sfx trigger) in emulator frame F are expected in port frame F+1 (the port applies
script events before the frame's vblank).
For a full-game port run (calls made by the translated kernel on the game thread during frame F) set CALLSHIFT=0.
usage: [CALLSHIFT=0] cmp_emu_reg.py EMUREG PORTREG N [FIRSTFRAME]"""
import sys, re, os
CS = int(os.environ.get('CALLSHIFT', '1'))
emureg, portreg, N = sys.argv[1], sys.argv[2], int(sys.argv[3])
F1 = int(sys.argv[4]) if len(sys.argv) > 4 else 0
rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
def playside(pc): return 0x2990 <= pc < 0x2d80 or 0x3eb4 <= pc < 0x4000
def load(p, emu):
    out = []
    for l in open(p):
        m = rx.match(l)
        if not m: continue
        f, reg, val, pc = int(m[1]), int(m[3], 16), int(m[4], 16), int(m[5], 16)
        if emu:
            if not (0x2800 <= pc < 0x4100): continue
            if not playside(pc): f += CS
        if not (reg in (0x96, 0x9e) or 0xa0 <= reg < 0xe0): continue
        if F1 <= f < N: out.append((f, reg, val))
    return out
E, P = load(emureg, True), load(portreg, False)
n = min(len(E), len(P))
first = next((i for i in range(n) if E[i][1:] != P[i][1:]), None)
frd = [i for i in range(n) if E[i][0] != P[i][0]]
same = first is None and len(E) == len(P)
print('emu %d writes, port %d writes; first (reg,value) difference: %s; writes landing in a different frame: %d%s' % (
    len(E), len(P), 'none' if same else '#%s emu=%s port=%s' % (first, E[first] if first is not None and first < len(E) else None,
    P[first] if first is not None and first < len(P) else None), len(frd), '' if not frd else ' (first: emu %s port %s)' % (E[frd[0]], P[frd[0]])))
print('RESULT', 'IDENTICAL' if same and not frd else 'DIFFERENT')
