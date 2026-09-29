#!/usr/bin/env python3
"""Helper used during the RE work: run the emulator from a state with a script and sample the
section-0 variables every N frames (via dumpr), print a table.

usage: probe.py STATE FRAMES EVERY "script line;script line;..." [extra emu args]
"""
import sys, os, subprocess, struct, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EMU = os.path.join(HERE, '..', '..', 'tools', 'amiga', 'emu')
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')

VARS = [  # name, addr, size
    ('px', 0x5f880, 2), ('py', 0x5f882, 2), ('pfr', 0x5f884, 2), ('pfa', 0x5f886, 2), ('pst', 0x5f89a, 2),
    ('est', 0x5f888, 2), ('ex', 0x5f88a, 2), ('ey', 0x5f88c, 2), ('efr', 0x5f88e, 2), ('efa', 0x5f890, 2),
    ('T', 0x60c24, 2), ('lvl', 0x60c26, 2), ('col', 0x60c28, 2), ('c34', 0x60c34, 2), ('cb0', 0x60cb0, 2),
    ('c30', 0x60c30, 2), ('noise', 0x60cae, 2), ('trap', 0x60c7a, 2), ('trapx', 0x60c76, 2),
    ('bomb', 0x60c7c, 2), ('bridge', 0x60c9c, 2), ('crate', 0x60c86, 2),
    ('mor', 0x12dde + 0x2e, 2), ('gren', 0x12dde + 0, 2), ('ammo', 0x12dde + 2, 2), ('hits', 0x12dde + 4, 2),
    ('man', 0x12dde + 0x22, 2), ('msgs', 0x12dde + 0x48, 2),
]


def run(state, frames, every, script, extra=()):
    os.makedirs(os.path.join(HERE, 'tmp'), exist_ok=True)
    d = tempfile.mkdtemp(prefix='probe', dir=os.path.join(HERE, 'tmp'))
    lines = [l.strip() for l in script.split(';') if l.strip()]
    for f in range(0, frames, every):
        lines.append('%d dumpr 5f880 20 p%06d_a.bin' % (f, f))
        lines.append('%d dumpr 60c24 a0 p%06d_b.bin' % (f, f))
        lines.append('%d dumpr 12dde 80 p%06d_c.bin' % (f, f))
    lines.sort(key=lambda t: int(t.split()[0]))
    sp = os.path.join(d, 'script.txt')
    open(sp, 'w').write('\n'.join(lines) + '\n')
    subprocess.run([EMU, '--adf', ADF, '--load-state', state, '--frames', str(frames), '--script', sp,
                    '--out', d] + list(extra), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rows = []
    for f in range(0, frames, every):
        mem = {}
        for suf, base in (('a', 0x5f880), ('b', 0x60c24), ('c', 0x12dde)):
            p = os.path.join(d, 'p%06d_%s.bin' % (f, suf))
            if not os.path.exists(p):
                continue
            b = open(p, 'rb').read()
            for i, v in enumerate(b):
                mem[base + i] = v
        row = {'f': f}
        for n, a, s in VARS:
            if a in mem and a + 1 in mem:
                v = (mem[a] << 8) | mem[a + 1]
                row[n] = v - 0x10000 if v & 0x8000 and n in ('c34', 'py') else v
        rows.append(row)
    return rows, d


if __name__ == '__main__':
    st, fr, ev, sc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    cols = sys.argv[5].split(',') if len(sys.argv) > 5 else [v[0] for v in VARS]
    rows, d = run(st, fr, ev, sc)
    print(' '.join('%6s' % c for c in ['f'] + cols))
    for r in rows:
        print(' '.join('%6s' % (('%x' % r[c]) if c in r and c not in ('f',) else r.get(c, '')) for c in ['f'] + cols))
