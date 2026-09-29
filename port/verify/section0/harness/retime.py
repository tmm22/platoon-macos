#!/usr/bin/env python3
"""Tick-aligned input for the port: make every joystick event reach the port's read_input in the SAME read (index) as
it reaches the emulator's, even where the port's frame pacing is one frame off for a stretch of ticks.
Emulator reads: PC $19f3a (jsr r_joy_read inside read_input). Port reads: S0DEBUG trace '019f3e' (printed in
s0ReadInput right before r_joystick). Iterates until the port script is stable.
usage: retime.py NAME FRAMES   (uses sc/NAME.txt; writes sc/NAME.port.txt used by h.py for the port)"""
import sys, subprocess, os, re, bisect
E = '/Users/deborahmangan/Projects/Platoon/tools/amiga/emu'
P = '/tmp/pbuild-section0/release/platoon-headless'
ADF = '/Users/deborahmangan/Projects/Platoon/re/platoon_port.adf'
BOOT = ['300 fire 1', '305 fire 0', '350 poke 12e4c 0 2', '600 fire 1', '605 fire 0']
OFF = 114; LPF = 313
name, frames = sys.argv[1], int(sys.argv[2])
W = f'/tmp/verify-section0/rt/{name}'; os.makedirs(W, exist_ok=True)
ev = []
for l in open(f'/tmp/verify-section0/sc/{name}.txt'):
    l = l.split('#')[0].strip()
    if l: p = l.split(); ev.append((int(p[0]), ' '.join(p[1:])))
ev.sort(key=lambda x: x[0])
open(f'{W}/e.txt', 'w').write('\n'.join(BOOT + [f'{f} {c}' for f, c in ev]) + '\n')
subprocess.run([E, '--adf', ADF, '--frames', str(frames), '--script', f'{W}/e.txt', '--out', W, '--deterministic',
                '--bp', '19f3a', '--bp', '171aa', '--bp', '17de4', '--events', f'{W}/eev.txt'], capture_output=True)
ER = []; EK = []
for l in open(f'{W}/eev.txt'):
    m = re.match(r'\[f(\d+) v(\d+)\] BP 0(19f3a|171aa|17de4)', l)
    if m: (ER if m[3] == '19f3a' else EK).append(int(m[1]) * LPF + int(m[2]))
ER.sort(); EK.sort()
KD = 100 + 3      # key delivered by the keyboard interrupt at line 100 of the event frame (both tools)
JOY = ('up', 'down', 'left', 'right', 'fire', 'fire0')
# read index that first sees each joystick event in the emulator
kidx = [bisect.bisect_left(ER, f * LPF) if c.split()[0] in JOY else None for f, c in ev]
kkid = [bisect.bisect_left(EK, f * LPF + KD) if c.split()[0] == 'key' else None for f, c in ev]
pev = [(f - OFF, c) for f, c in ev]
env = dict(os.environ); env['S0DEBUG'] = '1'; env['PLATOON_ENH'] = 'originalCredits=0'
for it in range(8):
    open(f'{W}/p.txt', 'w').write('\n'.join(f'{f} {c}' for f, c in sorted(pev, key=lambda x: x[0]) if f >= 0) + '\n')
    out = subprocess.run([P, '--adf', ADF, '--start-section', '0', '--deterministic', '--frames', str(frames - OFF),
                          '--script', f'{W}/p.txt', '--out', W], capture_output=True, text=True, env=env).stdout
    PR = sorted(int(m[1]) * LPF + int(m[2]) for m in re.finditer(r'^019f3e f(\d+) v(\d+)', out, re.M))
    PK = sorted(int(m[2]) * LPF + int(m[3]) for m in re.finditer(r'^01(71aa|7de4) f(\d+) v(\d+)', out, re.M))
    new = []
    for (f, c), (pf, _), k, kk in zip(ev, pev, kidx, kkid):
        if kk is not None and kk < len(PK):
            lo = PK[kk - 1] if kk > 0 else -10**9; hi = PK[kk]
            cands = [g for g in range(f - OFF - 4, f - OFF + 5) if lo < g * LPF + KD <= hi]
            if cands:
                g = max(cands, key=lambda g: (min(g * LPF + KD - lo, hi - g * LPF - KD), -abs(g - (f - OFF))))
                new.append((g, c)); continue
        if k is None or k >= len(PR): new.append((pf, c)); continue
        lo = PR[k - 1] if k > 0 else -10**9; hi = PR[k]
        cands = [g for g in range(f - OFF - 4, f - OFF + 5) if lo < g * LPF <= hi]
        if not cands: new.append((pf, c)); continue
        g = max(cands, key=lambda g: (min(g * LPF - lo, hi - g * LPF), -abs(g - (f - OFF))))
        new.append((g, c))
    changed = sum(1 for a, b in zip(new, pev) if a != b)
    shifted = sum(1 for (g, c), (f, _) in zip(new, ev) if g != f - OFF)
    print(f'iteration {it}: {len(ER)} emu reads, {len(PR)} port reads, {changed} events changed, {shifted} differ from f-OFF', flush=True)
    pev = new
    if changed == 0: break
open(f'/tmp/verify-section0/sc/{name}.port.txt', 'w').write('\n'.join(f'{f} {c}' for f, c in sorted(pev, key=lambda x: x[0]) if f >= 0) + '\n')
