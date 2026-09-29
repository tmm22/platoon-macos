#!/usr/bin/env python3
"""foxhole RE helper: run the emulator from a state with a script and sample section-2 object slots
and variables every N frames.

usage: probe.py STATE FRAMES EVERY "frame cmd;frame cmd;..." [--slots 0,4,10] [--shots]
Prints per sample: frame, tick counter-ish vars, and for the chosen slots: act,anim,x,y,frame,e.
"""
import sys, os, subprocess, struct, tempfile, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
EMU = os.path.join(HERE, '..', '..', 'tools', 'amiga', 'emu')
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')
SLOT0 = 0x57e22
A6 = 0x12dde


def run(state, frames, every, script, shots=False, extra=()):
    os.makedirs(os.path.join(HERE, 'work', 'tmp'), exist_ok=True)
    d = tempfile.mkdtemp(prefix='probe', dir=os.path.join(HERE, 'work', 'tmp'))
    lines = [l.strip() for l in script.split(';') if l.strip()]
    for f in range(0, frames, every):
        lines.append('%d dumpr 57e20 180 p%06d_a.bin' % (f, f))
        lines.append('%d dumpr 12dde 80 p%06d_c.bin' % (f, f))
        lines.append('%d dumpr 18f1c 4 p%06d_d.bin' % (f, f))
        lines.append('%d dumpr 19012 4 p%06d_e.bin' % (f, f))
        if shots:
            lines.append('%d shot s%06d' % (f, f))
    lines.sort(key=lambda t: int(t.split()[0]))
    sp = os.path.join(d, 'script.txt')
    open(sp, 'w').write('\n'.join(lines) + '\n')
    subprocess.run([EMU, '--adf', ADF, '--load-state', state, '--frames', str(frames), '--script', sp,
                    '--out', d] + list(extra), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    samples = []
    for f in range(0, frames, every):
        mem = {}
        for suf, base in (('a', 0x57e20), ('c', A6), ('d', 0x18f1c), ('e', 0x19012)):
            p = os.path.join(d, 'p%06d_%s.bin' % (f, suf))
            if not os.path.exists(p):
                continue
            for i, v in enumerate(open(p, 'rb').read()):
                mem[base + i] = v
        samples.append((f, mem))
    return samples, d


def w(mem, a):
    return (mem.get(a, 0) << 8) | mem.get(a + 1, 0)


def sw(mem, a):
    v = w(mem, a)
    return v - 0x10000 if v & 0x8000 else v


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('state'); ap.add_argument('frames', type=int); ap.add_argument('every', type=int)
    ap.add_argument('script'); ap.add_argument('--slots', default='0,4,7,10')
    ap.add_argument('--shots', action='store_true')
    a = ap.parse_args()
    slots = [int(s) for s in a.slots.split(',')]
    samples, d = run(a.state, a.frames, a.every, a.script, a.shots)
    print('# outdir', d)
    for f, m in samples:
        if not m:
            continue
        s = 'f%5d mor=%04x gr=%d am=%02x wd=%d man=%d T=%04x room=%02x kind=%d scale=%d f54=%d f5a=%d |' % (
            f, w(m, A6 + 0x2e), w(m, A6 + 0), w(m, A6 + 2), w(m, A6 + 4), w(m, A6 + 0x22), w(m, A6 + 0x6c),
            m.get(0x18f1c, 0), m.get(0x57f44, 0), sw(m, 0x19012), m.get(0x57f54, 0), sw(m, 0x57f5a))
        for k in slots:
            b = SLOT0 + 0x12 * k
            s += ' s%d:%02x/%02x %d,%d fr%d e%d' % (k, m.get(b, 0), m.get(b + 1, 0), sw(m, b + 2), sw(m, b + 4),
                                                     m.get(b + 0x10, 0), sw(m, b + 0xe))
        print(s)
