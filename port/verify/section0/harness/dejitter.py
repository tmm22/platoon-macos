#!/usr/bin/env python3
"""Move script input events away from 'knife edges': an event at frame e is seen by the first joystick/keyboard read
after the start of frame e (read = PC $19f3e, after the HUD update in read_input). If that read or the previous one lies
within a few raster lines of the frame start, a +-2..3-line timing difference of the port would change which tick sees
the event. For every input event pick the frame e' (e-2..e+2) that is seen by the same read in the emulator and whose
start is farthest from both neighbouring reads. Then check that the emulator tickdumps are unchanged.
usage: dejitter.py NAME FRAMES  -> writes sc/NAME_dj.txt"""
import sys, subprocess, os, re, filecmp
E = '/Users/deborahmangan/Projects/Platoon/tools/amiga/emu'
ADF = '/Users/deborahmangan/Projects/Platoon/re/platoon_port.adf'
BOOT = ['300 fire 1', '305 fire 0', '350 poke 12e4c 0 2', '600 fire 1', '605 fire 0']
LPF = 313
name, frames = sys.argv[1], int(sys.argv[2])
W = f'/tmp/verify-section0/dj/{name}'; os.makedirs(W, exist_ok=True)
ev = []
for l in open(f'/tmp/verify-section0/sc/{name}.txt'):
    l = l.split('#')[0].strip()
    if l: p = l.split(); ev.append([int(p[0]), ' '.join(p[1:])])

def run(evs, tag, bp=True):
    s = sorted(evs, key=lambda x: x[0])
    open(f'{W}/{tag}.txt', 'w').write('\n'.join(BOOT + [f'{f} {c}' for f, c in s]) + '\n')
    for n in ('a', 'b', 'c', 's'):
        if os.path.exists(f'{W}/{tag}_{n}.bin'): os.remove(f'{W}/{tag}_{n}.bin')
    cmd = [E, '--adf', ADF, '--frames', str(frames), '--script', f'{W}/{tag}.txt', '--out', W, '--deterministic',
           '--tickdump', '17186', '5f880', '1c', f'{W}/{tag}_a.bin', '--tickdump', '17186', '60c24', 'a0', f'{W}/{tag}_b.bin',
           '--tickdump', '17186', '12dde', '78', f'{W}/{tag}_c.bin', '--tickdump', '19772', '12dde', '78', f'{W}/{tag}_s.bin']
    if bp: cmd += ['--bp', '410', '--events', f'{W}/{tag}_ev.txt']
    subprocess.run(cmd, capture_output=True)
    reads = []
    if bp:
        for l in open(f'{W}/{tag}_ev.txt'):
            m = re.match(r'\[f(\d+) v(\d+)\] BP 000410', l)
            if m: reads.append(int(m[1]) * LPF + int(m[2]))
    return sorted(set(reads))

reads = run(ev, 'orig')
import bisect
def seen_by(frame):
    i = bisect.bisect_left(reads, frame * LPF)
    return i
moved = 0
for e in ev:
    f, c = e
    if not c.split()[0] in ('up', 'down', 'left', 'right', 'fire', 'fire0'): continue
    i = seen_by(f)
    if i >= len(reads): continue
    best, bscore = f, None
    for g in range(f - 3, f + 4):
        if seen_by(g) != i: continue
        s = g * LPF
        d0 = s - reads[i - 1] if i > 0 else 10**6
        d1 = reads[i] - s
        sc = min(d0, d1)
        if bscore is None or sc > bscore or (sc == bscore and g == f): best, bscore = g, sc
    if best != f: e[0] = best; moved += 1
run(ev, 'dj', bp=False)
same = all(filecmp.cmp(f'{W}/orig_{n}.bin', f'{W}/dj_{n}.bin', shallow=False) for n in ('a', 'b', 'c', 's'))
open(f'/tmp/verify-section0/sc/{name}_dj.txt', 'w').write('\n'.join(f'{f} {c}' for f, c in sorted(ev, key=lambda x: x[0])) + '\n')
print(f'{name}: {len(reads)} reads, moved {moved} events; emulator tickdumps unchanged: {same}')
