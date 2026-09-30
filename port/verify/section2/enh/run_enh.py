#!/usr/bin/env python3
"""Section-2 enhancement feature tests (owner: section2). Headless, port only (no emulator needed).

usage: run_enh.py [--bin platoon-headless] [--out DIR] [--only REGEX] [--jobs N]

Every scenario runs one of the verified section-2 input scripts (port/verify/section2/*.txt, from power-on,
--deterministic) with and without an option and checks what the option must (and must not) change:
  nav_*        M5 navigator model in the running game (PLATOON_S2NAV log): shortest route at every room entry along
               the honest routes (the honest scripts walk the shortest route), host picture decoder == the game's
               decoded background ($68000) for every room, host room renderer == the first drawn playfield of every
               room (outside the player); and the log itself changes nothing (full-RAM hash every frame identical)
  s9a          room-change timer pause (s2.fixRoomTimer)
  s9h_*        napalm timer stop / WITHDRAWN text (s2.napalmStopsTimer, s2.withdrawnText)
  s9j          no phantom '.' grenades after Barnes' death (s2.fixPhantomGrenades)
  m10_*        difficulty knobs (s2.diff.*, difficulty=recruit)
  m15_*        game.lives / game.fullPlatoon in section 2
  m5_compass   s2.compassAssist
Exit status 0 = all PASS.
"""
import argparse, os, re, struct, subprocess, sys, concurrent.futures as cf

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../..'))
V = os.path.join(ROOT, 'port/verify/section2')
ADF = os.path.join(ROOT, 're/platoon_port.adf')


def ticks(path, ln):
    """tickdump records: [(frame, bytes)]"""
    if not os.path.exists(path):
        return []
    d = open(path, 'rb').read()
    out, i = [], 0
    while i + 4 + ln <= len(d):
        out.append((struct.unpack('<I', d[i:i + 4])[0], d[i + 4:i + 4 + ln]))
        i += 4 + ln
    return out


def w16(b, off):
    return b[off] << 8 | b[off + 1]


class Run:
    def __init__(self, name, script, frames, enh='', tds=(), env=None, hash_=False, extra_script=None):
        self.name, self.script, self.frames, self.enh = name, script, frames, enh
        self.tds, self.env, self.hash, self.extra_script = list(tds), env or {}, hash_, extra_script

    def run(self, binary, out):
        d = os.path.join(out, self.name)
        os.makedirs(d, exist_ok=True)
        script = os.path.join(V, self.script) if not self.script.startswith('/') else self.script
        if self.extra_script:
            lines = open(script).read().splitlines() + self.extra_script
            lines = sorted((l for l in lines if l.strip()), key=lambda l: int(l.split()[0]))
            script = os.path.join(d, 'script.txt')
            open(script, 'w').write('\n'.join(lines) + '\n')
        args = [binary, '--adf', ADF, '--frames', str(self.frames), '--script', script, '--deterministic',
                '--enh', 'originalCredits=0' + (',' + self.enh if self.enh else '')]
        for pc, lo, ln in self.tds:
            args += ['--tickdump', pc, lo, ln, os.path.join(d, f'td_{pc}_{lo}.bin')]
        if self.hash:
            args += ['--hash', '0', '80000']
        env = dict(os.environ)
        env.pop('PLATOON_ENH', None)
        env['PLATOON_EVENTS'] = os.path.join(d, 'events.txt')
        for k, v in self.env.items():
            env[k] = v.replace('{d}', d)
        with open(os.path.join(d, 'stdout.txt'), 'w') as f:
            subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, env=env, cwd=ROOT, timeout=600)
        self.dir = d
        return self

    def td(self, pc, lo, ln):
        return ticks(os.path.join(self.dir, f'td_{pc}_{lo}.bin'), int(ln, 16))

    def events(self):
        p = os.path.join(self.dir, 'events.txt')
        return open(p).read().splitlines() if os.path.exists(p) else []

    def hashes(self):
        return [l for l in open(os.path.join(self.dir, 'stdout.txt')).read().splitlines() if ' hash ' in l]


A6 = ('12dde', '78')
A6_17118 = ('17118',) + A6


def scenarios():
    S = []
    nav_env = {'PLATOON_S2NAV': '{d}/nav.txt'}
    for n, fr in [('honest1', 3900), ('honest2', 3400)]:
        S.append(('nav_' + n, [Run(f'nav_{n}', f'{n}.txt', fr, env=nav_env, hash_=True),
                               Run(f'nav_{n}_nolog', f'{n}.txt', fr, hash_=True)], check_nav))
    tds = [('170f4',) + A6, ('17604',) + A6, ('1764e',) + A6]
    S.append(('s9a', [Run('s9a_orig', 'tele.txt', 2900, tds=tds), Run('s9a_fix', 'tele.txt', 2900, 's2.fixRoomTimer=1', tds=tds)], check_s9a))
    tds = [('1770e',) + A6, ('1718a',) + A6]
    S.append(('s9h_napalm', [Run('s9h_orig', 'napalm.txt', 7300, tds=tds),
                             Run('s9h_fix', 'napalm.txt', 7300, 's2.napalmStopsTimer=1', tds=tds)], check_s9h_napalm))
    S.append(('s9h_withdrawn', [Run('s9w_orig', 'morale.txt', 1500), Run('s9w_fix', 'morale.txt', 1500, 's2.withdrawnText=1')],
              check_s9h_withdrawn))
    tds = [A6_17118]
    S.append(('s9j', [Run('s9j_orig', 'fox1.txt', 1400, tds=tds), Run('s9j_fix', 'fox1.txt', 1400, 's2.fixPhantomGrenades=1', tds=tds)],
              check_s9j))
    S.append(('m10_barnes', [Run('m10b_3', 'fox1.txt', 1400, 's2.diff.barnesHits=3', tds=[('17c0a',) + A6])], check_m10_barnes))
    tds = [('170f4',) + A6, ('1718a',) + A6]
    S.append(('m10_timer', [Run('m10t_orig', 'napalm.txt', 7300, tds=tds), Run('m10t_60', 'napalm.txt', 7300, 's2.diff.timer=60', tds=tds),
                            Run('m10t_recruit', 'napalm.txt', 10300, 'difficulty=recruit', tds=tds)], check_m10_timer))
    tds = [('17118', '57e22', '270')]
    S.append(('m10_soldiers', [Run('m10s_orig', 'combat.txt', 1900, tds=tds),
                               Run('m10s_0', 'combat.txt', 1900, 's2.diff.maxSoldiers=0', tds=tds)], check_m10_soldiers))
    tds = [A6_17118]
    S.append(('m10_morale', [Run('m10m_orig', 'fox2.txt', 1800, tds=tds),
                             Run('m10m_0', 'fox2.txt', 1800, 's2.diff.hitMorale=0', tds=tds)], check_m10_morale))
    tds = [('17068',) + A6, ('17e96',) + A6, ('17f18',) + A6]
    S.append(('m15_lives', [Run('m15l_orig', 'fox2.txt', 3400, tds=tds), Run('m15l_3', 'fox2.txt', 3400, 'game.lives=3', tds=tds)],
              check_m15_lives))
    # full platoon: man 0 killed and man 1 wounded twice in the jungle (poked before the section starts)
    carry = ['350 poke 12de2 4 2', '350 poke 12de8 2 2', '350 poke 12de4 3 2']
    S.append(('m15_full', [Run('m15f_orig', 'fox2.txt', 3400, tds=tds + [A6_17118], extra_script=carry),
                           Run('m15f_full', 'fox2.txt', 3400, 'game.fullPlatoon=1', tds=tds + [A6_17118], extra_script=carry)],
              check_m15_full))
    tds = [('17118', '189d8', '8'), A6_17118]
    S.append(('m5_compass', [Run('m5c_orig', 'morale.txt', 1200, tds=tds),
                             Run('m5c_on', 'morale.txt', 1200, 's2.compassAssist=1', tds=tds)], check_m5_compass))
    return S


# ---- checks: return list of failure strings (empty = PASS) and an info line

def check_nav(runs):
    r, nolog = runs
    f = []
    nav = open(os.path.join(r.dir, 'nav.txt')).read().splitlines()
    rooms = [l for l in nav if ' room ' in l]
    dec = [l for l in nav if ' decode ' in l]
    drawn = [l for l in nav if ' drawn ' in l]
    if not rooms:
        return ['no room entries logged'], ''
    routes = [re.search(r'route (\S*) dist (-?\d+)', l).groups() for l in rooms]
    if routes[0][0] != 'LRLRLRLRRLRLRL':
        f.append(f'start route {routes[0][0]}')
    # the exit taken follows from the heading change (left = turn anticlockwise); when it was the suggested one the
    # remaining route must be the rest of the previous route, otherwise (a detour) at least as long as that
    hd = [re.search(r'heading (\S)', l).group(1) for l in rooms]
    follow = 0
    for i in range(1, len(routes)):
        turn = ('NESW'.index(hd[i]) - 'NESW'.index(hd[i - 1])) % 4
        exit_ = {3: 'L', 1: 'R'}.get(turn)
        prev, cur = routes[i - 1][0], routes[i][0]
        if exit_ is None or prev in ('', 'none'):
            continue                                # restart at the start room / bunker
        if prev[0] == exit_:
            follow += 1
            if cur != prev[1:]:
                f.append(f'room {i}: took the suggested {exit_}, route {cur} after {prev}')
        elif cur != 'none' and len(cur) < len(prev) - 1:
            f.append(f'room {i}: detour {exit_} shortened the route {prev} -> {cur}')
    if routes[-1][1] != '0':
        f.append(f'last room not a bunker: {rooms[-1]}')
    bad = [l for l in dec if not l.endswith('OK')]
    if bad or len(dec) != len(rooms):
        f.append(f'decode: {len(dec)} decodes for {len(rooms)} rooms, bad: {bad[:3]}')
    badd = [l for l in drawn if ' OK ' not in l]
    if badd or len(drawn) < len(rooms) - 1:
        f.append(f'drawn: {len(drawn)} checks for {len(rooms)} rooms, bad: {badd[:3]}')
    if r.hashes() != nolog.hashes() or not r.hashes():
        f.append('PLATOON_S2NAV changed the RAM hash')
    return f, f'{len(rooms)} rooms ({follow} along the guide), route {routes[0][0]}, {len(dec)} decodes OK, {len(drawn)} drawn OK, RAM hash identical'


def timer(b):
    return w16(b, 0x6c)


def check_s9a(runs):
    o, x = runs
    f = []
    for r, fix in [(o, False), (x, True)]:
        a, b = r.td('17604', *A6), r.td('1764e', *A6)
        if len(a) < 10 or len(a) != len(b):
            f.append(f'{r.name}: {len(a)} / {len(b)} transitions')
            continue
        same = sum(1 for (_, p), (_, q) in zip(a, b) if timer(p) == timer(q))
        stopped = sum(1 for _, q in b if w16(q, 0x68) == 0)
        if fix and (same != len(a) or stopped != len(b)):
            f.append(f'fix: timer ran during {len(a) - same} of {len(a)} transitions')
        if not fix and same == len(a):
            f.append('orig: timer never ran during a transition')
    # lowest timer at a room entry (the script ends with a restart at 2:00)
    eo = min((timer(b) for _, b in o.td('170f4', *A6)), default=None)
    ex = min((timer(b) for _, b in x.td('170f4', *A6)), default=None)
    if eo is None or ex is None or not ex > eo:
        f.append(f'last room entry: timer fix {ex} <= orig {eo}')
        return f, ''
    return f, f'last room entered with {eo:04x} (orig) / {ex:04x} (fix) on the clock'


def check_s9h_napalm(runs):
    o, x = runs
    f = []
    to, tx = o.td('1770e', *A6), x.td('1770e', *A6)
    if not to or not tx:
        return ['no text screen'], ''
    if timer(to[-1][1]) == 0:
        f.append('orig: timer 0 on the napalm screen (expected the 59:59 wrap)')
    if timer(tx[-1][1]) != 0:
        f.append(f'fix: timer {timer(tx[-1][1]):04x} on the napalm screen')
    if [fr for fr, _ in o.td('1718a', *A6)] != [fr for fr, _ in x.td('1718a', *A6)]:
        f.append('time_up frame changed')
    return f, f'napalm screen timer orig {timer(to[-1][1]):04x}, fix {timer(tx[-1][1]):04x}'


def check_s9h_withdrawn(runs):
    o, x = runs
    def texts(r):
        return [l for l in r.events() if 'textScreen' in l]
    f = []
    to, tx = texts(o), texts(x)
    if not any('DESTROYED' in l for l in to):
        f.append(f'orig: no DESTROYED text {to[-1:]}')
    if not any('WITHDRAWN' in l for l in tx) or any('DESTROYED' in l for l in tx):
        f.append(f'fix: {tx[-1:]}')
    return f, (tx[-1][:90] if tx else '')


def check_s9j(runs):
    o, x = runs
    def fx0a(r):
        return sum(1 for l in r.events() if re.search(r'fx \$0a', l))
    go, gx = o.td(*A6_17118)[-1][1], x.td(*A6_17118)[-1][1]
    f = []
    if w16(go, 0) != 0 or fx0a(o) != 9:
        f.append(f'orig: grenades left {w16(go, 0)}, throws {fx0a(o)} (expected 0 / 9: phantom throws)')
    if w16(gx, 0) != 4 or fx0a(x) != 5:
        f.append(f'fix: grenades left {w16(gx, 0)}, throws {fx0a(x)} (expected 4 / 5)')
    return f, f'grenades left orig {w16(go, 0)} fix {w16(gx, 0)}'


def check_m10_barnes(runs):
    r, = runs
    ev = r.events()
    hits = [i for i, l in enumerate(ev) if 'DIRECT HIT' in l or 'YOU GOT HIM' in l]
    kill = [i for i, l in enumerate(ev) if 'GET TO THE BUNKER' in l]
    f = []
    if len(hits) != 2 or not kill or kill[0] < hits[-1]:
        f.append(f'{len(hits)} hit messages before the kill (expected 2 + the kill on the 3rd)')
    if len(r.td('17c0a', *A6)) != 1:
        f.append('game not won')
    return f, f'Barnes down after 3 hits, game won'


def check_m10_timer(runs):
    o, s, rec = runs
    f = []
    st = [timer(b) for _, b in s.td('170f4', *A6)]   # first room entry (17068 is before the write)
    if not st or st[0] != 0x0100:
        f.append(f'60 s: start timer {st[:1]}')
    tu = [x.td('1718a', *A6)[0][0] if x.td('1718a', *A6) else None for x in (o, s, rec)]
    if None in tu:
        return f + [f'time_up frames {tu}'], ''
    if not (2900 <= tu[0] - tu[1] <= 3100):
        f.append(f'60 s: time_up {tu[1]} vs {tu[0]}')
    if not (2900 <= tu[2] - tu[0] <= 3100):
        f.append(f'recruit: time_up {tu[2]} vs {tu[0]}')
    rt = [timer(b) for _, b in rec.td('170f4', *A6)]
    if not rt or rt[0] != 0x0300:
        f.append(f'recruit: start timer {rt[:1]}')
    return f, f'napalm at frame {tu[1]} (60 s) / {tu[0]} (orig 120 s) / {tu[2]} (recruit 180 s)'


def check_m10_soldiers(runs):
    o, z = runs
    left = lambda r: [b[0x120] for _, b in r.td('17118', '57e22', '270')]
    active = lambda r: sum(1 for _, b in r.td('17118', '57e22', '270') for s in (4, 5, 6)
                           if b[s * 0x12] != 0 and struct.unpack('>I', b[s * 0x12 + 0xa:s * 0x12 + 0xe])[0] in (0x17c32, 0x17c7c, 0x17cc6))
    f = []
    if active(o) == 0:
        f.append('orig: no soldier ever active')
    if any(left(z)) or active(z):
        f.append(f'max 0: soldiers left {max(left(z))}, active soldier ticks {active(z)}')
    return f, f'soldier-active ticks orig {active(o)}, max0 {active(z)}'


def check_m10_morale(runs):
    o, z = runs
    mo = [w16(b, 0x2e) for _, b in o.td(*A6_17118)]
    mz = [w16(b, 0x2e) for _, b in z.td(*A6_17118)]
    f = []
    if len(set(mo)) < 2:
        f.append('orig: morale never changed')
    if len(set(mz)) != 1:
        f.append(f'hitMorale=0: morale values {sorted(set(mz))}')
    return f, f'morale orig {mo[0]:04x}->{mo[-1]:04x}, hitMorale=0 stays {mz[0]:04x}'


def check_m15_lives(runs):
    o, x = runs
    f = []
    so = [w16(b, 0x22) for _, b in o.td('17068', *A6)]
    sx = [w16(b, 0x22) for _, b in x.td('17068', *A6)]
    if so != [0, 1]:
        f.append(f'orig: men {so}')
    if sx != [0, 1, 2]:
        f.append(f'lives=3: men {sx}')
    if len(x.td('17f18', *A6)) != 1 or len(o.td('17f18', *A6)) != 1:
        f.append('all_dead not reached once')
    return f, f'restarts with men orig {so}, lives=3 {sx}; all dead after the last'


def check_m15_full(runs):
    o, x = runs
    f = []
    fo, fx = o.td(*A6_17118)[0][1], x.td(*A6_17118)[0][1]
    # orig: re-initialised, man 0, all hits 0
    if w16(fo, 0x22) != 0 or w16(fo, 4) != 0 or w16(fo, 0xa) != 0:
        f.append('orig: men not re-initialised')
    if w16(fx, 0x22) != 1 or struct.unpack('>I', fx[0x1e:0x22])[0] != 0x12dde + 6 or w16(fx, 4) != 4 or w16(fx, 0xa) != 2 or w16(fx, 6) != 3:
        f.append(f'full: first tick man {w16(fx, 0x22)} hits {w16(fx, 4)}/{w16(fx, 0xa)} grenades man1 {w16(fx, 6)}')
    sx = [w16(b, 0x22) for _, b in x.td('17068', *A6)]
    if sx[:2] != [1, 2]:
        f.append(f'full: men {sx}')
    return f, f'full platoon: starts with man 1 (2 wounds, 3 grenades carried), then men {sx}'


def check_m5_compass(runs):
    o, x = runs
    ho, hx = o.td('17118', '189d8', '8')[0][1], x.td('17118', '189d8', '8')[0][1]
    ao, ax = o.td(*A6_17118)[0][1], x.td(*A6_17118)[0][1]
    f = []
    if ho[4] != 0x0b or w16(ao, 0x26) != 0:
        f.append('orig: compass hint / flag')
    if hx[4] != 0 or w16(ax, 0x26) != 1:
        f.append(f'on: hint0 {hx[4]:02x} compass {w16(ax, 0x26)}')
    return f, 'hint 0 GET GOING!, compass flag set'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', default='/tmp/pbuild-section2/release/platoon-headless')
    ap.add_argument('--out', default='/tmp/enh-section2/ft')
    ap.add_argument('--only', default='')
    ap.add_argument('--jobs', type=int, default=6)
    a = ap.parse_args()
    sc = [s for s in scenarios() if re.search(a.only, s[0])]
    runs = [r for _, rs, _ in sc for r in rs]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        list(ex.map(lambda r: r.run(a.bin, a.out), runs))
    ok = True
    for name, rs, chk in sc:
        try:
            fails, info = chk(rs)
        except Exception as e:  # noqa
            fails, info = [f'check crashed: {e!r}'], ''
        ok &= not fails
        print(f"{'PASS' if not fails else 'FAIL'} {name}: {info if not fails else '; '.join(fails)}")
    print('ALL PASS' if ok else 'FAILURES')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
