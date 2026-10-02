#!/usr/bin/env python3
"""Default-settings lockstep regression gate for the Platoon port (driver of tools/regress_all.sh).

Every scenario is an input script from the verification harnesses (port/verify/{kernel,section0,section1,section2},
kernel scripts copied to tools/regress/kernel). Each one is run by
  emu   tools/amiga/emu --deterministic                        (reference; cached, the emulator never changes)
  base  platoon-headless built from the pinned pre-enhancement commit BASE_COMMIT (cached)
  cur   the platoon-headless under test (--bin)
all with PLATOON_ENH=originalCredits=0,referenceEmulator=1 (crack credits text and the emulator's timing/Paula
instead of the real-A500 defaults, see port/verify/timing.md) unless the scenario says otherwise,
and with tick dumps at the original main-loop heads, screenshots and (port only) an FNV hash of ALL RAM after
every frame.

Verdict per scenario:
  PASS  cur is byte-identical to base: every tick dump (RAM + frame numbers), every frame's full-RAM hash, every
        screenshot and every dumped file. This is the "with all options at defaults the game behaves
        byte-identically to before" rule.
  FAIL  anything differs; the first difference is reported (and cur-vs-emu lockstep stats for diagnosis).
The emulator lockstep status (the level reached by the translation: ticks identical to the original game,
screenshots identical) is printed for information next to each verdict.

usage: regress.py --bin PORTBIN --base-bin BASEBIN [--only REGEX] [--jobs N] [--out DIR] [--list] [--no-cache]
"""
import os, sys, re, json, struct, shutil, hashlib, argparse, subprocess, time, threading
import concurrent.futures as cf

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EMU = f'{ROOT}/tools/amiga/emu'
ADF = f'{ROOT}/re/platoon_port.adf'
V = f'{ROOT}/port/verify'
RK = f'{ROOT}/tools/regress/kernel'
BASE_COMMIT = '716172f'
CACHE = '/tmp/regress-cache'
PORT_HASH = ('0', '80000')          # full RAM, every frame (port only; golden comparison)

# ------------------------------------------------------------------------------------------------ scenarios

class Sc:
    def __init__(self, name, group, emu_lines, frames, port_lines=None, port_frames=None, port_args=(),
                 tds=(), shot_every=0, env=None, emu=True, frame_off=0, note=''):
        self.name, self.group, self.emu_lines, self.frames = name, group, emu_lines, frames
        self.port_lines = port_lines if port_lines is not None else emu_lines
        self.port_frames = port_frames if port_frames is not None else frames
        self.port_args, self.tds, self.shot_every = list(port_args), list(tds), shot_every
        self.env = env if env is not None else {'PLATOON_ENH': 'originalCredits=0,referenceEmulator=1'}
        self.emu, self.frame_off, self.note = emu, frame_off, note

def lines_of(path):
    out = []
    for l in open(path):
        l = l.split('#')[0].strip()
        if l: out.append(l)
    return out

def sanitize(lines):
    """dumpr/dump paths -> basenames (outputs land in the run's --out directory)."""
    out = []
    for l in lines:
        p = l.split()
        if len(p) >= 3 and p[1] == 'dumpr' and len(p) >= 5: p[4] = os.path.basename(p[4])
        if len(p) >= 3 and p[1] == 'dump': p[2] = os.path.basename(p[2])
        out.append(' '.join(p))
    return out

def kernel_scenarios():
    A6 = ('10eac', '12dde', '78')                      # every vblank (level-3 handler entry): a6 globals
    HS = ('f890', '116cc', '1600')                     # k_init: hiscore track image after every game
    GO = ('fee8', '12dde', '78')                       # k_game_over entry
    SS = ('fcc8', '12dde', '78')                       # k_section_start
    tds = [A6, HS, GO, SS]
    L = []
    for n, fr, se in [('title', 2600, 20), ('f10', 1400, 20), ('cheat', 2400, 10), ('hud', 1800, 5), ('hs', 4200, 20),
                      ('tie', 4400, 50), ('del0', 3200, 20), ('del1', 2600, 20), ('del2', 2600, 20), ('go1', 2400, 20),
                      ('go2t', 2900, 20), ('s0s1', 7000, 50)]:
        f = 'empty' if n == 'title' else n
        L.append(Sc(f'k_{n}', 'kernel', sanitize(lines_of(f'{RK}/{f}.txt')), fr, tds=tds, shot_every=se))
    # defaults (originalCredits on) except the emulator timing: golden only
    L.append(Sc('k_title_defaults', 'kernel', lines_of(f'{RK}/empty.txt'), 1400, tds=tds, shot_every=20,
                env={'PLATOON_ENH': 'referenceEmulator=1'}, emu=False,
                note='enhancement defaults (originalCredits on) with referenceEmulator=1, golden only'))
    # hiscore persistence (PLATOON_HISCORES): the saved track file is compared too; golden only
    L.append(Sc('k_hs_persist', 'kernel', sanitize(lines_of(f'{RK}/hs.txt')), 4200, tds=tds, shot_every=100, emu=False,
                env={'PLATOON_ENH': 'originalCredits=0,referenceEmulator=1', 'PLATOON_HISCORES': '{out}/hiscores.bin'},
                note='PLATOON_HISCORES file written by the $424 save hook, golden only'))
    # continue from section 1 with a carried a6 block (PLATOON_CARRY) - golden only
    L.append(Sc('k_carry1', 'kernel', lines_of(f'{RK}/carry_port.txt'), 1700, port_args=['--start-section', '1'],
                tds=[A6, ('171c6', '12dde', '78')], shot_every=50, emu=False,
                env={'PLATOON_ENH': 'originalCredits=0,referenceEmulator=1', 'PLATOON_CARRY': f'{RK}/carry.bin'},
                note='--start-section 1 + PLATOON_CARRY, golden only'))
    return L

S0OFF = 114
S0BOOT = ['300 fire 1', '305 fire 0', '350 poke 12e4c 0 2', '600 fire 1', '605 fire 0']
def s0_scenarios():
    sc = f'{V}/section0/harness/sc'
    regions = [('17186', '5f880', '1c'), ('17186', '60c24', 'a0'), ('17186', '12dde', '78'), ('17186', '1aaf4', '56'),
               ('17186', '1b200', '10'), ('19772', '12dde', '78'), ('17dae', '12dde', '78'), ('1986c', '12dde', '78')]
    L = []
    for n, fr, shots in [('walk', 2100, 50), ('cheats', 2400, 50), ('deaths_dj', 4300, 50), ('deaths2_dj', 4300, 50),
                         ('doom_dj', 2300, 50), ('dummy_dj', 3400, 50), ('jungle_route_part1_dj', 7700, 100),
                         ('jungle_route3_dj', 9000, 100), ('village_route_dj', 5800, 50),
                         ('honest_village_dj', 13700, 100), ('misc_dj', 14700, 100)]:
        ev = []
        for l in lines_of(f'{sc}/{n}.txt'):
            p = l.split(); ev.append((int(p[0]), ' '.join(p[1:])))
        shot_ev = [(f, f'shot s_{f:05d}') for f in range(820, fr, shots)]
        emu_lines = S0BOOT + [f'{f} {c}' for f, c in sorted(ev + shot_ev, key=lambda x: x[0])]
        pf = f'{sc}/{n}.port.txt'
        if os.path.exists(pf):          # tick-aligned port inputs (retime.py), see port/verify/section0.md
            pe = [(int(l.split()[0]), ' '.join(l.split()[1:])) for l in lines_of(pf)]
            pe += [(f - S0OFF, c) for f, c in shot_ev]
        else:
            pe = [(f - S0OFF, c) for f, c in ev + shot_ev]
        port_lines = [f'{f} {c}' for f, c in sorted(pe, key=lambda x: x[0]) if f >= 0]
        L.append(Sc(f's0_{n}', 'section0', emu_lines, fr, port_lines=port_lines, port_frames=fr - S0OFF,
                    port_args=['--start-section', '0'], tds=regions, frame_off=S0OFF))
    return L

def s1_scenarios():
    regs = [('12d70', '4'), ('12dde', '78'), ('19a60', '652'), ('3b220', '1dc')]
    L = []
    for n, fr, pcs, se in [('idle', 2200, '171d8', 20), ('death', 5600, '171d8,170c4', 25), ('room0', 2900, '171d8', 20),
                           ('combat', 3600, '171d8,170c4', 20), ('misc', 4400, '171d8,170c4', 20),
                           ('exit', 3400, '171d8,18bd8', 20), ('honest', 2300, '171d8', 20), ('wrap', 2300, '171d8', 20),
                           ('nohelp', 1300, '171d8', 20), ('keys', 2000, '171d8,170c4', 10),
                           ('fl_help', 3400, '171d8,18bd8', 20), ('fl_idle', 5200, '171d8,18bd8', 20),
                           ('flmove', 2800, '171d8,18bd8', 20), ('fl_lit', 3200, '171d8,18bd8', 20),
                           ('flq1', 4200, '171d8,18bd8', 25), ('flp2', 7400, '17118,18bd8', 20),
                           ('tour', 21400, '171d8,18bd8', 25)]:
        tds = [(pc, lo, ln) for pc in pcs.split(',') for lo, ln in regs][:8]
        L.append(Sc(f's1_{n}', 'section1', lines_of(f'{V}/section1/scripts/{n}.txt'), fr, tds=tds, shot_every=se))
    return L

def s2_scenarios():
    tds = [('17118', '57e22', '270'), ('17118', '12dde', '78'), ('17118', '18f1c', 'fc'), ('17118', '17226', '2'),
           ('17118', '189d8', '8'), ('170f4', '12dde', '78'), ('1771c', '12dde', '78')]
    L = []
    for n, fr, se in [('napalm', 7300, 50), ('fox1', 1400, 10), ('fox2', 1800, 10), ('fox4', 1400, 10), ('morale', 1500, 10),
                      ('caps', 2500, 10), ('mines', 1300, 10), ('wire', 1300, 10), ('rocks', 1300, 10), ('combat', 1900, 10),
                      ('log11', 1200, 10), ('rock0', 1200, 10), ('mine5', 1200, 10), ('wire78', 1200, 10), ('tele', 2900, 10),
                      ('tele_wrong', 3800, 10), ('s1to2', 3300, 10), ('honest1', 3900, 10), ('honest2', 3400, 10)]:
        L.append(Sc(f's2_{n}', 'section2', lines_of(f'{V}/section2/{n}.txt'), fr, tds=tds, shot_every=se))
    return L

def all_scenarios():
    return kernel_scenarios() + s0_scenarios() + s1_scenarios() + s2_scenarios()

# ------------------------------------------------------------------------------------------------ running

def clean_env(extra, out):
    e = {k: v for k, v in os.environ.items() if not k.startswith('PLATOON_') and k not in ('S2PACE', 'S2PACELEN', 'S2PACEPL')}
    for k, v in extra.items(): e[k] = v.replace('{out}', out)
    return e

def file_sig(p):
    st = os.stat(p); return f'{st.st_size}:{int(st.st_mtime)}'

def run_key(sc, kind, binsig):
    lines = sc.emu_lines if kind == 'emu' else sc.port_lines
    d = dict(kind=kind, lines=lines, frames=sc.frames if kind == 'emu' else sc.port_frames,
             args=[] if kind == 'emu' else sc.port_args, tds=sc.tds, shots=sc.shot_every,
             env=sc.env if kind != 'emu' else {}, bin=binsig, adf=file_sig(ADF), v=3)
    return hashlib.sha1(json.dumps(d, sort_keys=True).encode()).hexdigest()[:16]

def run_tool(kind, sc, binpath, out):
    """Runs one tool into `out` (fresh). Returns wall seconds."""
    if os.path.exists(out): shutil.rmtree(out)
    os.makedirs(f'{out}/files')
    lines = sc.emu_lines if kind == 'emu' else sc.port_lines
    frames = sc.frames if kind == 'emu' else sc.port_frames
    open(f'{out}/script.txt', 'w').write('\n'.join(lines) + '\n')
    cmd = [binpath, '--adf', ADF, '--frames', str(frames), '--script', f'{out}/script.txt', '--out', f'{out}/files',
           '--deterministic']
    if sc.shot_every: cmd += ['--shot-every', str(sc.shot_every)]
    for i, (pc, lo, ln) in enumerate(sc.tds): cmd += ['--tickdump', pc, lo, ln, f'{out}/td{i}_{pc}_{lo}.bin']
    env = clean_env({} if kind == 'emu' else sc.env, f'{out}/files')
    if kind != 'emu': cmd += sc.port_args + ['--hash', *PORT_HASH]
    t = time.time()
    with open(f'{out}/stdout.txt', 'w') as so:
        subprocess.run(cmd, stdout=so, stderr=subprocess.STDOUT, env=env, cwd=ROOT)
    open(f'{out}/cmd.txt', 'w').write(' '.join(cmd) + '\n')
    open(f'{out}/.done', 'w').write('ok')
    return time.time() - t

def cached_run(kind, sc, binpath, binsig, outroot, use_cache):
    key = run_key(sc, kind, binsig)
    cdir = f'{CACHE}/{kind}/{sc.name}-{key}'
    if use_cache and os.path.exists(f'{cdir}/.done'):
        return cdir, 0.0, True
    tmp = cdir + f'.tmp{os.getpid()}.{threading.get_ident()}'
    secs = run_tool(kind, sc, binpath, tmp)
    if os.path.exists(cdir): shutil.rmtree(cdir, ignore_errors=True)
    try: os.rename(tmp, cdir)
    except OSError: cdir = tmp
    return cdir, secs, False

# ------------------------------------------------------------------------------------------------ comparing

def recs(path, L):
    d = open(path, 'rb').read(); n = len(d) // (4 + L)
    return [(struct.unpack('<I', d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]

def png_same(a, b):
    if open(a, 'rb').read() == open(b, 'rb').read(): return True
    try:
        from PIL import Image, ImageChops
        A = Image.open(a).convert('RGB'); B = Image.open(b).convert('RGB')
        return A.size == B.size and ImageChops.difference(A, B).getbbox() is None
    except Exception:
        return False

def golden(sc, cur, base):
    """Byte-exact cur vs base. Returns (ok, message)."""
    probs, stats = [], []
    # tick dumps
    tdn = 0
    for i, (pc, lo, ln) in enumerate(sc.tds):
        fn = f'td{i}_{pc}_{lo}.bin'; L = int(ln, 16)
        a, b = f'{base}/{fn}', f'{cur}/{fn}'
        da = open(a, 'rb').read() if os.path.exists(a) else b''
        db = open(b, 'rb').read() if os.path.exists(b) else b''
        tdn += len(da) // (4 + L)
        if da == db: continue
        A, B = recs(a, L) if da else [], recs(b, L) if db else []
        msg = f'tickdump ${pc} ${lo}+${ln}: base {len(A)} ticks, cur {len(B)} ticks'
        for k, ((fa, xa), (fb, xb)) in enumerate(zip(A, B)):
            if fa != fb or xa != xb:
                offs = [j for j in range(L) if xa[j] != xb[j]][:6]
                msg += f'; first diff tick {k}: frame {fa}/{fb}' + (' bytes ' + ' '.join(
                    f'${int(lo,16)+j:05x}:{xa[j]:02x}/{xb[j]:02x}' for j in offs) if offs else ' (frame only)')
                break
        probs.append(msg)
    stats.append(f'{len(sc.tds)} tickdumps/{tdn} ticks')
    # per-frame full-RAM hash (stdout)
    ha = [l for l in open(f'{base}/stdout.txt') if l.startswith('frame ')]
    hb = [l for l in open(f'{cur}/stdout.txt') if l.startswith('frame ')]
    if ha != hb:
        k = next((i for i, (x, y) in enumerate(zip(ha, hb)) if x != y), min(len(ha), len(hb)))
        probs.append(f'RAM hash: base {len(ha)} frames, cur {len(hb)} frames; first difference at frame {k + 1}')
    stats.append(f'{len(ha)} frame RAM hashes')
    other_a = [l for l in open(f'{base}/stdout.txt') if not l.startswith('frame ')]
    other_b = [l for l in open(f'{cur}/stdout.txt') if not l.startswith('frame ')]
    if other_a != other_b:
        probs.append(f'stdout differs: base {other_a[:2]} cur {other_b[:2]}')
    # screenshots and dumped files
    fa = sorted(os.listdir(f'{base}/files')); fb = sorted(os.listdir(f'{cur}/files'))
    if fa != fb:
        probs.append(f'output files differ: only base {sorted(set(fa)-set(fb))[:4]}, only cur {sorted(set(fb)-set(fa))[:4]}')
    nshot = 0; bad = []
    for f in fa:
        if f not in fb: continue
        a, b = f'{base}/files/{f}', f'{cur}/files/{f}'
        if f.endswith('.png'):
            nshot += 1
            if not png_same(a, b): bad.append(f)
        elif open(a, 'rb').read() != open(b, 'rb').read(): bad.append(f)
    if bad: probs.append(f'{len(bad)} output files differ: {bad[:5]}')
    stats.append(f'{nshot} shots, {len(fa) - nshot} files')
    if probs: return False, ' | '.join(probs)
    return True, 'identical to baseline (' + ', '.join(stats) + ')'

def emu_stats(sc, port, emu):
    """Lockstep status port vs emulator (information): tick-aligned RAM identity, tick frames, screenshots."""
    parts = []
    tot = bad = frames_off = 0; regs_bad = []
    for i, (pc, lo, ln) in enumerate(sc.tds):
        fn = f'td{i}_{pc}_{lo}.bin'; L = int(ln, 16)
        a, b = f'{emu}/{fn}', f'{port}/{fn}'
        if not os.path.exists(a) or not os.path.exists(b): continue
        A, B = recs(a, L), recs(b, L)
        if pc == '10eac' and lo == '12dde':      # per-frame a6 (kernel): frames where the globals differ
            nb = sum(1 for (x, y) in zip(A, B) if x[1] != y[1]); tot += min(len(A), len(B)); bad += nb
            if nb: regs_bad.append(f'${pc}:{nb}')
            continue
        nb = sum(1 for (x, y) in zip(A, B) if x[1] != y[1])
        nf = sum(1 for (x, y) in zip(A, B) if y[0] + sc.frame_off != x[0])
        if len(A) != len(B): regs_bad.append(f'${pc}/${lo}: {len(A)} vs {len(B)} ticks')
        tot += min(len(A), len(B)); bad += nb; frames_off = max(frames_off, nf)
        if nb: regs_bad.append(f'${pc}/${lo}:{nb}')
    parts.append(f'RAM {tot - bad}/{tot} ticks identical' + (f' (differ: {", ".join(regs_bad[:4])})' if regs_bad else ''))
    if frames_off: parts.append(f'tick frames off: {frames_off}')
    # screenshots: same names (kernel/s1/s2: --shot-every at the same frames; s0: named shots)
    ea = sorted(f for f in os.listdir(f'{emu}/files') if f.endswith('.png'))
    same = 0; n = 0
    for f in ea:
        if sc.frame_off and not f.startswith('s_'): continue
        pb = f'{port}/files/{f}'
        if not os.path.exists(pb): continue
        n += 1
        if png_same(f'{emu}/files/{f}', pb): same += 1
    parts.append(f'shots {same}/{n} identical')
    return '; '.join(parts)

# ------------------------------------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=False); ap.add_argument('--base-bin', required=False)
    ap.add_argument('--only', default=''); ap.add_argument('--skip', default='')
    ap.add_argument('--jobs', type=int, default=max(2, (os.cpu_count() or 4) * 3 // 4))
    ap.add_argument('--out', default=f'/tmp/regress/run-{time.strftime("%Y%m%d-%H%M%S")}-{os.getpid()}')
    ap.add_argument('--list', action='store_true'); ap.add_argument('--no-cache', action='store_true')
    ap.add_argument('--no-emu', action='store_true', help='skip the emulator (information only)')
    o = ap.parse_args()
    scs = all_scenarios()
    if o.only: scs = [s for s in scs if re.search(o.only, s.name)]
    if o.skip: scs = [s for s in scs if not re.search(o.skip, s.name)]
    if o.list:
        for s in scs: print(f'{s.name:28s} {s.group:9s} {s.frames:6d} frames  {s.note}')
        return 0
    if not o.bin or not o.base_bin: ap.error('--bin and --base-bin are required')
    os.makedirs(o.out, exist_ok=True)
    cur_bin, base_bin = os.path.abspath(o.bin), os.path.abspath(o.base_bin)
    emusig, basesig = file_sig(EMU), BASE_COMMIT + ':' + file_sig(base_bin)
    scs.sort(key=lambda s: -s.frames)
    print(f'regress: {len(scs)} scenarios, {o.jobs} jobs, out {o.out}\n  cur  {cur_bin}\n  base {base_bin} ({BASE_COMMIT})',
          flush=True)
    lock = threading.Lock(); results = {}
    t0 = time.time()

    def one(sc):
        t = time.time()
        cur = f'{o.out}/{sc.name}'
        run_tool('cur', sc, cur_bin, cur)
        base, _, _ = cached_run('base', sc, base_bin, basesig, o.out, not o.no_cache)
        ok, msg = golden(sc, cur, base)
        info = ''
        if sc.emu and not o.no_emu:
            emu, _, _ = cached_run('emu', sc, EMU, emusig, o.out, not o.no_cache)
            sfile = f'{base}/.emu_stats'
            if ok and os.path.exists(sfile) and not o.no_cache:
                info = open(sfile).read()
            else:
                info = emu_stats(sc, cur if not ok else base, emu)
                if ok: open(sfile, 'w').write(info)
            if not ok: info += ' | baseline vs emu: ' + emu_stats(sc, base, emu)
        line = f'{"PASS" if ok else "FAIL"} {sc.name:26s} {time.time() - t:6.1f}s  {msg}' + (f'\n       emu lockstep: {info}' if info else '')
        with lock:
            results[sc.name] = (ok, line)
            print(line, flush=True)

    with cf.ThreadPoolExecutor(max_workers=max(1, o.jobs)) as ex:
        futs = [ex.submit(one, s) for s in scs]
        for f in futs:
            try: f.result()
            except Exception as e:
                print(f'ERROR {e!r}', flush=True)
    names = [s.name for s in scs]
    fails = [n for n in names if n not in results or not results[n][0]]
    with open(f'{o.out}/summary.txt', 'w') as sf:
        for n in sorted(names, key=lambda n: (n[:2], n)):
            sf.write((results[n][1] if n in results else f'FAIL {n} (no result)') + '\n')
        sf.write(f'{"ALL PASS" if not fails else "FAILED: " + " ".join(fails)} ({len(names)} scenarios, {time.time() - t0:.0f}s)\n')
    print(f'\n{"ALL PASS" if not fails else "FAILED: " + " ".join(fails)} ({len(names)} scenarios, {time.time() - t0:.0f}s)'
          f'\nsummary: {o.out}/summary.txt', flush=True)
    return 0 if not fails else 1

if __name__ == '__main__':
    sys.exit(main())
