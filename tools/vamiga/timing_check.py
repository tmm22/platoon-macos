#!/usr/bin/env python3
"""Real-A500 timing check of the port against the cycle-exact vAmiga (see port/verify/timing.md).

For each scenario the original game runs in tools/amiga/emu (--deterministic, tick dumps), the per-tick joystick
input is reconstructed from the dumps, and the SAME inputs are then fed per tick (not per frame) to vAmiga
(tools/vamiga/drv) and to the port with its default real-A500 timing (platoon-headless --tickinput). All three then
play the identical game (checked: the tick dumps must be byte-identical), so the frame length of every tick can be
compared directly between the port and vAmiga.

usage: timing_check.py [--bin PLATOON_HEADLESS] [--drv DRV] [--only REGEX]
vAmiga and emulator outputs are cached in /tmp/timing-cache (keyed by binary + inputs).
"""
import argparse, collections, hashlib, os, re, struct, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EMU = f'{ROOT}/tools/amiga/emu'
ADF = f'{ROOT}/re/platoon_port.adf'
SC0 = f'{ROOT}/port/verify/section0/harness/sc'
S0BOOT = ['300 fire 1', '305 fire 0', '350 poke 12e4c 0 2', '600 fire 1', '605 fire 0']
CACHE = '/tmp/timing-cache'
ROMS = '/tmp/vamiga/Resources/Assets.xcassets/Binary'

def lines(path): return [l.strip() for l in open(path) if l.strip() and not l.startswith('#')]

def sh(cmd, env=None):
    e = dict(os.environ); e.update(env or {})
    subprocess.run(cmd, env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

def key(*parts):
    h = hashlib.sha1()
    for p in parts:
        h.update(open(p, 'rb').read() if os.path.isfile(p) else str(p).encode())
    return h.hexdigest()[:16]

def ticks(path, n):
    d = open(path, 'rb').read()
    return [(struct.unpack('<I', d[i:i + 4])[0], d[i + 4:i + 4 + n]) for i in range(0, len(d), 4 + n)]

# scenarios: name, script lines, emu frames, tick pc, dump lo, dump len, align (emu frame of the first tick),
# entry (emu frame of $17000), port args, input reconstruction ('s0' = from $60cc1 + script fire, None = no input)
def scenarios():
    def s0(n, fr):
        ev = sorted(S0BOOT + lines(f'{SC0}/{n}.txt'), key=lambda l: int(l.split()[0]))
        return dict(name=f's0_{n}', script=ev, frames=fr, pc='17186', lo='60c24', ln=0xa0, align=813, entry=717,
                    port=['--start-section', '0'], inputs='s0', extra=[])
    nap = lines(f'{ROOT}/port/verify/section2/napalm.txt')
    return [s0('jungle_route3_dj', 9000), s0('honest_village_dj', 12600),
            dict(name='s2_napalm', script=nap, frames=7100, pc='17118', lo='57e22', ln=0x270, align=924, entry=761,
                 port=[], inputs=None, extra=['6 poke 17d68 4e75 2'])]

def tick_inputs(sc, emu_td):
    t = ticks(emu_td, sc['ln'])
    out = list(sc['extra'])
    if sc['inputs'] == 's0':
        off = 0x60cc1 - 0x60c24
        bits = {'down': 1, 'right': 2, 'up': 4, 'left': 8, 'fire': 0x80}
        ev = sorted(((int(l.split()[0]), l.split()[1:]) for l in sc['script']), key=lambda e: e[0])
        S = []; cur = dict.fromkeys(bits, 0); j = 0
        for F in range(sc['frames'] + 10):
            while j < len(ev) and ev[j][0] <= F:
                if ev[j][1][0] in cur: cur[ev[j][1][0]] = int(ev[j][1][1])
                j += 1
            S.append(sum(bits[k] for k in cur if cur[k]))
        for k in range(len(t) - 1):
            act = t[k + 1][1][off] & 0x0f; F = t[k][0]       # directions as the game read them, fire from the script
            fire = S[F] & 0x80 if S[F] & 15 == act else (S[F + 1] & 0x80 if S[F + 1] & 15 == act else S[F] & 0x80)
            out.append(f'{k} in {act | fire:02x}')
        for f, a in ev:
            if a[0] == 'poke' and f >= sc['align']:
                out.append(f'{next(i for i in range(len(t)) if t[i][0] >= f)} poke {" ".join(a[1:])}')
    return out

def run(sc, args):
    os.makedirs(CACHE, exist_ok=True)
    w = f'{CACHE}/{sc["name"]}'
    os.makedirs(w, exist_ok=True)
    script = f'{w}/script.txt'; open(script, 'w').write('\n'.join(sc['script']) + '\n')
    emu_td = f'{w}/emu.{key(EMU, script)}.td'
    if not os.path.exists(emu_td):
        sh([EMU, '--adf', ADF, '--deterministic', '--frames', str(sc['frames']), '--script', script, '--out', f'{w}/emu',
            '--tickdump', sc['pc'], sc['lo'], f'{sc["ln"]:x}', emu_td])
    tin = f'{w}/tickin.txt'; open(tin, 'w').write('\n'.join(tick_inputs(sc, emu_td) or ['999999 in 00']) + '\n')
    va = f'{w}/va.{key(args.drv, script, tin)}'
    if not os.path.exists(va + '.td'):
        sh([args.drv, ADF, f'{ROMS}/aros-20260820-rom.dataset/aros-20260820-rom.bin', script,
            str(sc['frames'] * 2 + 3000), va, str(sc['align']), '90'],
           env=dict(EXTROM=f'{ROMS}/aros-20260820-ext.dataset/aros-20260820-ext.bin', TICKIN=tin, TICKPC=sc['pc'],
                    TICKPCS=sc['pc'], ALIGNPC=sc['pc'], TDLO=sc['lo'], TDLEN=f'{sc["ln"]:x}', ENTRY=str(sc['entry']),
                    DEDUPTIME='1'))
    port_script = f'{w}/port_script.txt'
    pre = [l for l in sc['script'] if int(l.split()[0]) < sc['align']] if not sc['port'] else []
    open(port_script, 'w').write('\n'.join(pre) + '\n')
    pt = f'{w}/port.td'
    if os.path.exists(pt): os.remove(pt)
    sh([args.bin, '--adf', ADF, '--deterministic', '--frames', str(sc['frames'] * 2), '--script', port_script,
        '--out', f'{w}/port', '--tickinput', sc['pc'], tin, '--tickdump', sc['pc'], sc['lo'], f'{sc["ln"]:x}', pt]
       + sc['port'], env={'PLATOON_ENH': 'originalCredits=0,referenceEmulator=0'})
    E, V, P = ticks(emu_td, sc['ln']), ticks(va + '.td', sc['ln']), ticks(pt, sc['ln'])
    n = min(len(E), len(V), len(P)) - 1
    same_ram = all(E[i][1] == P[i][1] for i in range(n)) if sc['inputs'] else all(V[i][1] == P[i][1] for i in range(n))
    va_ram = all(E[i][1] == V[i][1] for i in range(n)) if sc['inputs'] else None
    d = lambda T: [T[i + 1][0] - T[i][0] for i in range(n)]
    de, dv, dp = d(E), d(V), d(P)
    ok = [i for i in range(n) if dv[i] < 10 and dp[i] < 10]
    sv, sp = sum(dv[i] for i in ok), sum(dp[i] for i in ok)
    same = sum(1 for i in ok if dv[i] == dp[i])
    print(f'{sc["name"]}: {n} ticks; game state identical: port {"yes" if same_ram else "NO"}'
          + (f', vAmiga {"yes" if va_ram else "NO"}' if va_ram is not None else ''))
    print(f'   frames/tick  emulator {sum(de) / n:.3f}  vAmiga {sv / len(ok):.3f}  port {sp / len(ok):.3f}'
          f'  (port vs vAmiga {100 * (sp - sv) / sv:+.2f}%, same length {100 * same / len(ok):.1f}% of ticks)')
    print(f'   vAmiga {dict(sorted(collections.Counter(dv).items()))}  port {dict(sorted(collections.Counter(dp).items()))}')
    return same_ram and abs(sp - sv) / sv < 0.02

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', default=f'{ROOT}/port/.build/release/platoon-headless')
    ap.add_argument('--drv', default='/tmp/vamiga-build/drv')
    ap.add_argument('--only', default='')
    args = ap.parse_args()
    good = True
    for sc in scenarios():
        if args.only and not re.search(args.only, sc['name']): continue
        good &= run(sc, args)
    print('OK' if good else 'DIFFERENCES (see above)')
    sys.exit(0 if good else 1)

if __name__ == '__main__':
    main()
