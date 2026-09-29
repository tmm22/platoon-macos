#!/usr/bin/env python3
"""Section-0 lockstep harness: emu (full boot) vs platoon-headless --start-section 0, both --deterministic.
usage: h.py NAME FRAMES [--shots K] [--noshots] [--from-state]   scenario file /tmp/verify-section0/sc/NAME.txt
Scenario lines: 'FRAME cmd args' with EMULATOR absolute frames (>= 800); the boot part is prepended for the emu and
events are shifted by OFF (= emu first tick 813 - port first tick 699 = 114) for the port. Shots every K frames
(names s_<emuframe>). Compares tickdumps at $17186 (player/enemy, section vars, a6 globals, tables, bridge map),
Paula driver register stream (reglog) and screenshots."""
import sys, os, struct, subprocess, re
from PIL import Image, ImageChops
E = '/Users/deborahmangan/Projects/Platoon/tools/amiga/emu'
P = '/tmp/pbuild-section0/release/platoon-headless'
ADF = '/Users/deborahmangan/Projects/Platoon/re/platoon_port.adf'
TC = '/Users/deborahmangan/Projects/Platoon/tools/tickcmp.py'
OFF = 114
BOOT = ['300 fire 1', '305 fire 0', '350 poke 12e4c 0 2', '600 fire 1', '605 fire 0']
REGIONS = [('a', '5f880', '1c'), ('b', '60c24', 'a0'), ('c', '12dde', '78'), ('d', '1aaf4', '56'), ('m', '1b200', '10')]
TPC = os.environ.get('TPC', '17186')
if os.environ.get('REGS'): REGIONS = [r for r in REGIONS if r[0] in os.environ['REGS']]

def main():
    a = sys.argv[1:]
    name, frames = a[0], int(a[1])
    shots = 0
    if '--shots' in a: shots = int(a[a.index('--shots') + 1])
    W = f'/tmp/verify-section0/run/{name}'
    os.makedirs(W + '/eo', exist_ok=True); os.makedirs(W + '/po', exist_ok=True)
    for d in ('eo', 'po'):
        for f in os.listdir(f'{W}/{d}'): os.remove(f'{W}/{d}/{f}')
    ev = []
    for l in open(f'/tmp/verify-section0/sc/{name}.txt'):
        l = l.split('#')[0].strip()
        if not l: continue
        p = l.split(); ev.append((int(p[0]), ' '.join(p[1:])))
    if shots:
        for f in range(820, frames, shots): ev.append((f, f'shot s_{f:05d}'))
    ev.sort(key=lambda x: x[0])
    open(f'{W}/e.txt', 'w').write('\n'.join(BOOT + [f'{f} {c}' for f, c in ev]) + '\n')
    pf = f'/tmp/verify-section0/sc/{name}.port.txt'
    if os.path.exists(pf) and '--noport' not in a:   # tick-aligned port inputs made by retime.py
        pe = [(int(l.split()[0]), ' '.join(l.split()[1:])) for l in open(pf) if l.strip()]
        pe += [(f - OFF, c) for f, c in ev if c.startswith('shot')]
        pe.sort(key=lambda x: x[0])
        open(f'{W}/p.txt', 'w').write('\n'.join(f'{f} {c}' for f, c in pe if f >= 0) + '\n')
    else:
        open(f'{W}/p.txt', 'w').write('\n'.join(f'{f-OFF} {c}' for f, c in ev if f - OFF >= 0) + '\n')
    etd, ptd = [], []
    EXTRA = [(pc, f'w{pc}', lo, ln) for pc in os.environ.get('XPCS', '19772,17dae,1986c').split(',') if pc
             for lo, ln in (('12dde', '78'),)]
    for pc, n, lo, ln in EXTRA:
        for s, lst in (('e', etd), ('p', ptd)):
            fn = f'{W}/{s}_{n}.bin'
            if os.path.exists(fn): os.remove(fn)
            lst += ['--tickdump', pc, lo, ln, fn]
    for n, lo, ln in REGIONS:
        for s, lst in (('e', etd), ('p', ptd)):
            fn = f'{W}/{s}_{n}.bin'
            if os.path.exists(fn): os.remove(fn)
            lst += ['--tickdump', TPC, lo, ln, fn]
    ecmd = [E, '--adf', ADF, '--frames', str(frames), '--script', f'{W}/e.txt', '--out', f'{W}/eo', '--deterministic',
            '--reglog', f'{W}/erl.txt', '--bp', '19946', '--bp', '19b16', '--events', f'{W}/eev.txt'] + etd
    pcmd = [P, '--adf', ADF, '--start-section', '0', '--deterministic', '--frames', str(frames - OFF), '--script', f'{W}/p.txt',
            '--out', f'{W}/po', '--reglog', f'{W}/prl.txt'] + ptd
    pe = subprocess.Popen(ecmd, stdout=open(f'{W}/e.log', 'w'), stderr=subprocess.STDOUT)
    env = dict(os.environ); env['PLATOON_ENH'] = 'originalCredits=0'     # pure original (kernel enhancement off)
    pp = subprocess.Popen(pcmd, stdout=open(f'{W}/p.log', 'w'), stderr=subprocess.STDOUT, env=env)
    pe.wait(); pp.wait()
    rep = []
    for n, lo, ln in REGIONS:
        r = subprocess.run(['python3', TC, f'{W}/e_{n}.bin', f'{W}/p_{n}.bin', ln, '--base', lo, '--max', '2'],
                           capture_output=True, text=True).stdout.strip()
        rep.append(f'[{n} ${lo}+${ln}] ' + r.replace('\n', '\n   '))
    for pc, n, lo, ln in EXTRA:
        if not os.path.exists(f'{W}/e_{n}.bin') and not os.path.exists(f'{W}/p_{n}.bin'): continue
        r = subprocess.run(['python3', TC, f'{W}/e_{n}.bin', f'{W}/p_{n}.bin', ln, '--base', lo, '--max', '2'],
                           capture_output=True, text=True).stdout.strip()
        if r.startswith('0 ticks in A, 0 ticks in B'): continue
        rep.append(f'[pc {pc} ${lo}+${ln}] ' + r.replace('\n', '\n   '))
    # tick frame pacing
    L = int('1c', 16)
    def fr(p):
        d = open(p, 'rb').read(); k = len(d) // (4 + L); return [struct.unpack('<I', d[i*(4+L):i*(4+L)+4])[0] for i in range(k)]
    fa, fb = fr(f'{W}/e_a.bin'), fr(f'{W}/p_a.bin')
    bad = [(i, x, y + OFF) for i, (x, y) in enumerate(zip(fa, fb)) if x != y + OFF]
    rep.append(f'tick frames: {len(fa)} emu / {len(fb)} port ticks; frame mismatches {len(bad)} {bad[:5]}')
    # audio register stream
    rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
    def load(p, emu):
        out = []
        for l in open(p):
            m = rx.match(l)
            if not m: continue
            f, reg, val, pc = int(m[1]), int(m[3], 16), int(m[4], 16), int(m[5], 16)
            if emu:
                if not (0x2800 <= pc < 0x4100): continue
                f -= OFF
            if not (reg in (0x96, 0x9e) or 0xa0 <= reg < 0xe0): continue
            if f >= 705: out.append((f, reg, val))
        return out
    EA, PA = load(f'{W}/erl.txt', True), load(f'{W}/prl.txt', False)
    import difflib
    sm = difflib.SequenceMatcher(None, [x[1:] for x in EA], [x[1:] for x in PA], autojunk=False)
    ops = [o for o in sm.get_opcodes() if o[0] != 'equal']
    fd = [(EA[i][0], PA[j][0]) for tag, i1, i2, j1, j2 in sm.get_opcodes() if tag == 'equal'
          for i, j in zip(range(i1, i2), range(j1, j2)) if EA[i][0] != PA[j][0]]
    rep.append(f'audio: emu {len(EA)} port {len(PA)} driver writes; value-sequence edits {len(ops)} '
               f'({sum(max(o[2]-o[1], o[4]-o[3]) for o in ops)} writes) {ops[:3]}; aligned writes in another frame {len(fd)} {fd[:3]}')
    # screenshots
    tot = 0; bads = []
    names = sorted(x for x in os.listdir(f'{W}/eo') if x.startswith('s_'))
    for nm in names:
        if not os.path.exists(f'{W}/po/{nm}'): bads.append((nm, 'missing')); continue
        A = Image.open(f'{W}/eo/{nm}').convert('RGB'); B = Image.open(f'{W}/po/{nm}').convert('RGB')
        if A.size != B.size: bads.append((nm, 'size')); continue
        d = ImageChops.difference(A, B); bb = d.getbbox()
        if bb:
            cnt = sum(1 for px in d.getdata() if px != (0, 0, 0)); bads.append((nm, cnt, bb))
    # dissolve intervals (emu frames): shots taken while a dissolve runs (+1 frame) are classified separately
    iv = []; st = None
    for l in open(f'{W}/eev.txt'):
        m = re.match(r'\[f(\d+) v\d+\] BP 0(19946|19b16)', l)
        if not m: continue
        if m[2] == '19946': st = int(m[1])
        elif st is not None: iv.append((st, int(m[1]) + 1)); st = None
    indis = lambda nm: any(a <= int(nm[2:7]) <= b for a, b in iv)
    bd = [b for b in bads if indis(b[0])]; bo = [b for b in bads if not indis(b[0])]
    rep.append(f'shots: {len(names)} compared, {len(bads)} differ: {len(bd)} during dissolves, {len(bo)} other {bo[:8]}')
    s = f'== {name} ({frames} emu frames)\n' + '\n'.join(rep)
    print(s)
    open(f'{W}/report.txt', 'w').write(s + '\n')

main()
