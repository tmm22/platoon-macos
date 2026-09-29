#!/usr/bin/env python3
"""Compare Python replayer register writes against an emulator --reglog.
usage: compare.py REGLOG RAMIMAGE|ADF START_FRAME END_FRAME [events...]
events: "F:music:N", "F:sfx:D0" (kernel wrappers, applied after that frame's vblank play), "F:ram:DUMP" not needed.
Only driver writes (pc in $2800-$4100) of audio regs are compared."""
import sys, re, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from replayer import Driver, load_ram_from_adf

def parse_reglog(path, f0, f1):
    out = {}
    rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
    for line in open(path):
        mm = rx.match(line)
        if not mm: continue
        f, v, reg, val, pc = int(mm[1]), int(mm[2]), int(mm[3], 16), int(mm[4], 16), int(mm[5], 16)
        if not (0x2800 <= pc < 0x4100): continue
        if not (reg == 0x96 or reg == 0x9e or 0xa0 <= reg < 0xe0): continue
        if f0 <= f <= f1:
            out.setdefault(f, []).append((reg, val, v, pc))
    return out

def run(reglog, ram_src, f0, f1, events, verbose=True):
    ram = load_ram_from_adf(ram_src) if ram_src.endswith('.adf') else bytearray(open(ram_src, 'rb').read())
    d = Driver(ram)
    ev = {}
    for e in events:
        f, kind, arg = e.split(':')
        ev.setdefault(int(f), []).append((kind, int(arg, 0)))
    emu = parse_reglog(reglog, f0, f1)
    bad = 0; total = 0
    for f in range(f0, f1 + 1):
        d.frame = f
        d.log = []
        if f != f0 or not ev.get(f): pass
        # vblank play first (unless this is the init frame and caller says init happens before)
        pre = [x for x in ev.get(f, []) if x[0].startswith('pre')]
        for kind, arg in pre:
            if kind == 'premusic': d.k_music(arg)
            elif kind == 'presfx': d.k_sfx(arg)
        if f > f0 or not ev.get(f): d.play()
        for kind, arg in ev.get(f, []):
            if kind == 'music': d.k_music(arg)
            elif kind == 'sfx': d.k_sfx(arg)
            elif kind == 'rawsfx': d.sfx(arg)
            elif kind == 'fade': d.k_fade()
            elif kind == 'off': d.k_music_off()
        mine = [(r, v) for (_, r, v) in d.log if r >= 0]
        theirs = [(r, v) for (r, v, _, _) in emu.get(f, [])]
        total += len(theirs)
        if mine != theirs:
            bad += 1
            if verbose and bad <= 5:
                print('frame', f, 'MISMATCH')
                print('  py :', ' '.join('%03x=%04x' % x for x in mine))
                print('  emu:', ' '.join('%03x=%04x' % (r, v) for (r, v, _, _) in emu.get(f, [])))
    print('frames %d..%d: %d emu writes, %d mismatching frames' % (f0, f1, total, bad))
    return bad

if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5:])
