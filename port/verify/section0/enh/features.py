#!/usr/bin/env python3
"""Section-0 enhancement feature tests (owner: section0). Headless, --deterministic, --start-section 0.

usage: features.py BIN [OUTDIR] [--only REGEX]

Each test runs platoon-headless with PLATOON_ENH="originalCredits=0,<options>" on a section-0 harness script (the
same port scripts as the regression gate, tools/regress/regress.py) or a small scripted situation, with tick dumps
at the main-loop head $17186 and the F2 event log (PLATOON_EVENTS), and checks the feature's effect against the
same run with the option off. Prints PASS/FAIL per check, exits 0/1.
"""
import os, sys, re, struct, subprocess, shutil, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(f'{HERE}/../../../..')
ADF = f'{ROOT}/re/platoon_port.adf'
spec = importlib.util.spec_from_file_location('regress', f'{ROOT}/tools/regress/regress.py')
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)
SC = {s.name: s for s in R.s0_scenarios()}

BIN = sys.argv[1] if len(sys.argv) > 1 else '/tmp/pbuild-section0/release/platoon-headless'
OUT = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else '/tmp/enh-section0/ft'
ONLY = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None

# tick dump regions at $17186 (main-loop head)
TDS = [('17186', 0x5f880, 0x1c), ('17186', 0x60c24, 0xa0), ('17186', 0x12dde, 0x78), ('17186', 0x1aafa, 0x50), ('17186', 0x12d70, 4)]

class Run:
    def __init__(self, name, lines, frames, enh='', env=None):
        self.dir = f'{OUT}/{name}'
        if os.path.exists(self.dir): shutil.rmtree(self.dir)
        os.makedirs(f'{self.dir}/files')
        open(f'{self.dir}/script.txt', 'w').write('\n'.join(lines) + '\n')
        cmd = [BIN, '--adf', ADF, '--frames', str(frames), '--script', f'{self.dir}/script.txt', '--out',
               f'{self.dir}/files', '--deterministic', '--start-section', '0']
        for i, (pc, lo, ln) in enumerate(TDS): cmd += ['--tickdump', pc, f'{lo:x}', f'{ln:x}', f'{self.dir}/td{i}.bin']
        e = dict(os.environ)
        e['PLATOON_ENH'] = 'originalCredits=0' + (',' + enh if enh else '')
        e['PLATOON_EVENTS'] = f'{self.dir}/events.log'
        e.update(env or {})
        self.cmd = cmd
        with open(f'{self.dir}/stdout.txt', 'w') as so:
            subprocess.run(cmd, stdout=so, stderr=subprocess.STDOUT, env=e, cwd=ROOT, timeout=900)
        self.events = open(f'{self.dir}/events.log').read().splitlines() if os.path.exists(f'{self.dir}/events.log') else []
        self.ticks = []                                  # list of dict address -> bytes per tick
        recs = []
        for i, (pc, lo, ln) in enumerate(TDS):
            d = open(f'{self.dir}/td{i}.bin', 'rb').read() if os.path.exists(f'{self.dir}/td{i}.bin') else b''
            n = len(d) // (4 + ln)
            recs.append([(struct.unpack('<I', d[k*(4+ln):k*(4+ln)+4])[0], d[k*(4+ln)+4:(k+1)*(4+ln)]) for k in range(n)])
        self.n = min(len(r) for r in recs) if recs else 0
        self.recs = recs

    def frame(self, k): return self.recs[0][k][0]
    def r(self, k, addr, size=2):
        for i, (pc, lo, ln) in enumerate(TDS):
            if lo <= addr and addr + size <= lo + ln:
                b = self.recs[i][k][1][addr - lo: addr - lo + size]
                return int.from_bytes(b, 'big')
        raise KeyError(hex(addr))
    def series(self, addr, size=2): return [self.r(k, addr, size) for k in range(self.n)]
    def msgs(self): return [int(m.group(1), 16) for m in (re.search(r'message sec=0 idx=\$([0-9a-f]+)', l) for l in self.events) if m]
    def has(self, pat): return any(re.search(pat, l) for l in self.events)

results = []
def check(name, ok, detail=''):
    results.append((name, ok))
    print(f'{"PASS" if ok else "FAIL"}  {name}  {detail}', flush=True)

def want(name): return ONLY is None or re.search(ONLY, name)

def sc(name): s = SC[name]; return s.port_lines, s.port_frames

# ---------------------------------------------------------------------------------------------- S6 bridge failsafe
if want('s6'):
    lines, fr = sc('s0_doom_dj')
    off = Run('s6_off', lines, fr)
    on = Run('s6_on', lines, fr, 's0.bridgeFailsafe=1')
    pst_off, pst_on = off.series(0x5f89a), on.series(0x5f89a)
    col_on = on.series(0x60c28)
    check('s6 original: doom (player state 9, wiped out)', 9 in pst_off and off.has('gameOver|screen .*gameOver') ,
          f'states {sorted(set(pst_off))}')
    check('s6 failsafe: never state 9, never column >= $4e', 9 not in pst_on and max(col_on) < 0x4e and on.has('screen') ,
          f'max col ${max(col_on):x}')
    check('s6 failsafe: stopped at column $4d with "SET THE EXPLOSIVES" ($11)', max(col_on) == 0x4d and 0x11 in on.msgs())
    check('s6 failsafe: no game over, no KILLED IN ACTION', not on.has('gameOver') and 0x12 not in on.msgs())
    # with the preset knob
    rec = Run('s6_recruit', lines, fr, 'difficulty=recruit')
    check('s6 via difficulty=recruit', 9 not in rec.series(0x5f89a) and max(rec.series(0x60c28)) == 0x4d)

# ---------------------------------------------------------------------------------------------- S7 forgiving traps
if want('s7'):
    # a tripwire placed ahead of the walking player (warp to level 1 col $41 via the F3 cheat like doom_dj, then
    # walk right; at frame 400 a trap is poked at x $b0 in front of him)
    lines, _ = sc('s0_doom_dj')
    base = [l for l in lines if int(l.split()[0]) < 900]
    trap = base + ['900 poke 60c7a 1 2', '900 poke 60c76 00b00050 4']
    trap = sorted(trap, key=lambda l: int(l.split()[0]))
    off = Run('s7_off', trap, 1400)
    on = Run('s7_on', trap, 1400, 's0.forgivingTraps=1')
    h_off, h_on = off.series(0x12dde + 4), on.series(0x12dde + 4)
    check('s7 original: the tripwire kills man 0 (hits 3+1, KILLED IN ACTION)', off.has('death man=0') and 0x12 in off.msgs(), f'hits {sorted(set(h_off))}')
    check('s7 forgiving: man 0 only wounded (hits 1, YOU\'RE HIT, no KIA)', on.has('wounded man=0 hits=1') and not on.has('death man=0')
          and 0x0e in on.msgs() and 0x12 not in on.msgs(), f'hits {sorted(set(h_on))}')

# ---------------------------------------------------------------------------------------------- S9b morale clamp
if want('s9b'):
    lines, _ = sc('s0_walk')
    base = sorted([l for l in lines if int(l.split()[0]) < 700] +
                  ['700 poke 12e0c ff00 2', '700 poke 60c84 00940050 4'], key=lambda l: int(l.split()[0]))
    off = Run('s9b_off', base, 800)
    on = Run('s9b_on', base, 800, 's0.fixMoraleWrap=1')
    mo, mn = off.series(0x12e0c), on.series(0x12e0c)
    # first tick after the crate was opened: crate y back to 0
    k = next(i for i in range(off.n) if off.frame(i) > 700 and off.r(i, 0x60c86) == 0)
    check('s9b original: morale wraps after a crate at $ff00', mo[k] < 0x1000, f'morale ${mo[k]:x}')
    k = next(i for i in range(on.n) if on.frame(i) > 700 and on.r(i, 0x60c86) == 0)
    check('s9b fix: morale clamped at $ffff', mn[k] >= 0xff00, f'morale ${mn[k]:x}')

# ---------------------------------------------------------------------------------------------- S9f hut dummy
if want('s9f'):
    lines, fr = sc('s0_dummy_dj')
    off = Run('s9f_off', lines, fr)
    on = Run('s9f_on', lines, fr, 's0.fixHutDummy=1')
    check('s9f original: the hut-1 dummy is shot (guard flag $60c70 = 1)', max(off.series(0x60c70)) == 1)
    check('s9f fix: dummy not shootable ($60c70 stays 0)', max(on.series(0x60c70)) == 0)

# ---------------------------------------------------------------------------------------------- S9g tripwire spawn
if want('s9g'):
    for nm in ('s0_jungle_route_part1_dj', 's0_jungle_route3_dj'):
        lines, fr = sc(nm)
        runs = {'off': Run(f's9g_off_{nm}', lines, fr), 'on': Run(f's9g_on_{nm}', lines, fr, 's0.fixTripwireSpawn=1')}
        res = {}
        for k, r in runs.items():
            st, tx, c34, face = r.series(0x60c7a), r.series(0x60c76), r.series(0x60c34), r.series(0x5f886)
            spawns = [(tx[i], c34[i], face[i]) for i in range(1, r.n) if st[i] == 1 and st[i - 1] == 0]
            behind = [s for s in spawns if s[2] == 0 and s[0] < 0x100]
            res[k] = (len(spawns), len(behind))
        check(f's9g {nm}: tripwires behind the player only without the fix', res['on'][1] == 0,
              f'spawns/behind original {res["off"]}, fixed {res["on"]}')

# ---------------------------------------------------------------------------------------------- S9k trap-door bonus
if want('s9k'):
    lines, fr = sc('s0_honest_village_dj')
    # switch to man 2 (poke current man) shortly before the trap door
    k0 = None
    probe = Run('s9k_probe', lines, fr)
    tp = [i for i in range(probe.n)]
    score_off = None
    # the trap-door "Y" happens at the end of the script: poke the current man at the last main-loop tick in hut 1
    last = max(i for i in range(probe.n) if probe.r(i, 0x60c26) == 5)
    f = probe.frame(last) - 30
    add = [f'{f} poke 12dfc 00012dea 4', f'{f} poke 12e00 2 2']
    l2 = sorted(lines + add, key=lambda l: int(l.split()[0]))
    off = Run('s9k_off', l2, fr)
    on = Run('s9k_on', l2, fr, 's0.fixTrapdoorBonus=1')
    so = [l for l in off.events if 'score' in l][-1:] ; sn = [l for l in on.events if 'score' in l][-1:]
    check('s9k: bonus differs from the original when man 2 is in control', so != sn, f'orig {so} fixed {sn}')

# ---------------------------------------------------------------------------------------------- M10 knobs
if want('m10'):
    lines, fr = sc('s0_walk')
    off = Run('m10_off', lines, fr)
    vet = Run('m10_veteran', lines, fr, 'difficulty=veteran')
    rec = Run('m10_recruit', lines, fr, 'difficulty=recruit')
    cus = Run('m10_custom', lines, fr, 'difficulty=custom,s0.diff.grenades=3,s0.diff.ammo=0x40')
    check('m10 original: 9 grenades / $90 rounds', off.r(0, 0x12dde) == 9 and off.r(0, 0x12de0) == 0x90)
    check('m10 veteran: 6 grenades / $60 rounds, start morale $6c00', vet.r(0, 0x12dde) == 6 and vet.r(0, 0x12de0) == 0x60
          and vet.r(0, 0x12e0c) <= 0x6c00, f'morale ${vet.r(0, 0x12e0c):x}')
    check('m10 recruit: start morale $c000', rec.r(0, 0x12e0c) > 0x9000)
    check('m10 custom: explicit knobs only', cus.r(0, 0x12dde) == 3 and cus.r(0, 0x12de0) == 0x40 and cus.r(0, 0x12e0c) <= 0x9000)
    # the RNG call sequence is unchanged: same RNG state as long as the game doesn't diverge (first ticks)
    check('m10 veteran: same RNG sequence in the first 20 ticks (no k_random call added/removed)', vet.series(0x12d70, 4)[:20] == off.series(0x12d70, 4)[:20])

# ---------------------------------------------------------------------------------------------- M14 jump/crouch
if want('m14'):
    lines, _ = sc('s0_walk')
    base = [l for l in lines if int(l.split()[0]) < 700]
    extra = ['700 right 1', '760 key 32 1', '764 key 32 0', '860 right 0', '900 key 33 1', '960 key 33 0',
             '1000 up 1', '1040 up 0']
    l2 = sorted(base + extra, key=lambda l: int(l.split()[0]))
    off = Run('m14_off', l2, 1100, 's0.jumpKey=0x32,s0.crouchKey=0x33')
    on = Run('m14_on', l2, 1100, 's0.explicitJumpCrouch=1,s0.jumpKey=0x32,s0.crouchKey=0x33')
    ps_off, ps_on = off.series(0x5f89a), on.series(0x5f89a)
    fr_on = on.series(0x5f884)
    check('m14 off: keys do nothing (no jump before UP)', 1 not in ps_off[:next(i for i in range(off.n) if off.frame(i) >= 1000)])
    k_up = next(i for i in range(on.n) if on.frame(i) >= 1000)
    check('m14 on: jump key jumps (state 1)', 1 in ps_on[:k_up])
    check('m14 on: crouch key crouches (frame $a)', 0xa in fr_on[:k_up])
    check('m14 on: UP without a path does not jump', 1 not in ps_on[k_up:], f'states after UP {sorted(set(ps_on[k_up:]))}')

# ---------------------------------------------------------------------------------------------- L3 randomiser
if want('l3'):
    lines, fr = sc('s0_walk')
    off = Run('l3_off', lines, 900)
    a = Run('l3_seed1', lines, 900, 's0.villageSeed=1')
    b = Run('l3_seed1b', lines, 900, 's0.villageSeed=1')
    c = Run('l3_seed2', lines, 900, 's0.villageSeed=2')
    def table(r): t = r.recs[3][0][1]; return [t[i*4:i*4+4] for i in range(20)]
    T0, T1, T1b, T2 = table(off), table(a), table(b), table(c)
    pairs0 = sorted(x[2:] for x in T0); pairs1 = sorted(x[2:] for x in T1)
    check('l3: spots (lo/hi) unchanged, contents permuted', [x[:2] for x in T0] == [x[:2] for x in T1] and pairs0 == pairs1)
    sp = lambda T: {x[2]: i for i, x in enumerate(T) if x[2] in (0x10, 0x17)}
    check('l3: torch/map moved', sp(T0) != sp(T1), f'orig {sp(T0)} seed1 {sp(T1)} seed2 {sp(T2)}')
    check('l3: same seed = same village, other seed differs', T1 == T1b and T1 != T2)
    check('l3: dead entries #8/#14 untouched', T1[8] == T0[8] and T1[14] == T0[14])
    check('l3: game state otherwise identical (RNG, player)', off.series(0x12d70, 4) == a.series(0x12d70, 4))

# ---------------------------------------------------------------------------------------------- L4 widescreen latch
if want('l4'):
    lines, fr = sc('s0_jungle_route_part1_dj')
    r = Run('l4', lines, fr, '', {'PLATOON_S0_WIDETEST': f'{OUT}/l4/wide,7'})
    log = open(f'{OUT}/l4/wide/wide.log').read().splitlines() if os.path.exists(f'{OUT}/l4/wide/wide.log') else []
    ms = [float(re.search(r'match ([0-9.]+)', l).group(1)) for l in log]
    offs = [int(re.search(r'best offset (-?\d+)', l).group(1)) for l in log]
    good = sum(1 for m in ms if m >= 0.85)
    check('l4: latched scroll state renders the visible window exactly (>=85% pixels, bobs excluded) in >= 95% of samples',
          len(ms) > 20 and good >= 0.95 * len(ms), f'{good}/{len(ms)} samples, min {min(ms) if ms else 0:.3f}, offsets {sorted(set(offs))}')
    # regression: with the self-test the game itself is unchanged
    ref = Run('l4_ref', lines, fr)
    check('l4: game RAM identical with the latch attached', all(ref.recs[i] == r.recs[i] for i in range(len(TDS))))

print(f'\n{sum(ok for _, ok in results)}/{len(results)} checks passed')
sys.exit(0 if all(ok for _, ok in results) else 1)
