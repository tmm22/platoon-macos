#!/usr/bin/env python3
"""Feature tests of the section-1 enhancements (owner: section1). Headless, --deterministic, from power-on.

usage: s1test.py BIN [OUTDIR] [--only REGEX]
Each test generates a script, runs BIN with/without options and checks RAM dumps / the F2 event log.
Prints PASS/FAIL per check; exit 1 on any failure.
"""
import os, re, subprocess, sys, struct

BIN = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else '/tmp/enh-section1/ft'
ONLY = None
if '--only' in sys.argv: ONLY = re.compile(sys.argv[sys.argv.index('--only') + 1])
ADF = os.path.join(os.path.dirname(__file__), '../../../re/platoon_port.adf')
A6 = 0x12dde
BOOT = """300 fire 1
305 fire 0
350 poke 12e4c 1 2
600 fire 1
605 fire 0
900 fire 1
905 fire 0
911 poke 3b237 ff 1
"""
fails = 0

def run(name, script, frames, enh='', env=None, args=()):
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d): os.remove(os.path.join(d, f))
    sp = os.path.join(d, 'script.txt')
    lines = [l for l in script.strip().splitlines() if l.strip()]
    lines.sort(key=lambda l: int(l.split()[0]))
    open(sp, 'w').write('\n'.join(lines) + '\n')
    e = dict(os.environ)
    e['PLATOON_ENH'] = 'originalCredits=0' + (',' + enh if enh else '')
    e['PLATOON_EVENTS'] = os.path.join(d, 'events.txt')
    if env: e.update(env)
    cmd = [BIN, '--adf', ADF, '--frames', str(frames), '--script', sp, '--out', d, '--deterministic'] + list(args)
    r = subprocess.run(cmd, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    open(os.path.join(d, 'stdout.txt'), 'wb').write(r.stdout)
    return d

def rd(d, f): return open(os.path.join(d, f), 'rb').read()
def w16(b, o): return struct.unpack('>H', b[o:o + 2])[0]
def events(d): return open(os.path.join(d, 'events.txt')).read()

def check(name, cond, info=''):
    global fails
    print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  ' + str(info)))
    if not cond: fails += 1

def want(t): return ONLY is None or ONLY.search(t)

# ---------------------------------------------------------------- M4 keep items + checkpoint respawn, M10 hitMorale
# walk into room 8 (flares), take them, leave, get killed (hits 3 -> 4), continue with the second man.
DEATH = BOOT + """915 poke 1a0b0 0f23 2
915 poke 12e08 3 2
930 up 1
938 up 0
960 poke 19d34 1e 2
960 poke 19d36 1e 2
962 fire 1
968 fire 0
1000 poke 19d34 82 2
1000 poke 19d36 7b 2
1002 fire 1
1008 fire 0
1030 dumpr 12dde 76 a6_before.bin
1030 poke 12de2 3 2
1030 poke 3b237 1 1
1600 fire 1
1606 fire 0
1700 fire 1
1706 fire 0
1800 fire 1
1806 fire 0
1900 dumpr 12dde 76 a6.bin
1900 dumpr 1a0b0 2 pos.bin
1900 dumpr 19ad0 10 room8.bin
1900 shot end
"""
if want('keep'):
    base = run('keep_off', DEATH, 1910)
    a = rd(base, 'a6.bin'); b0 = rd(base, 'a6_before.bin')
    check('keep_off: flares taken before death', w16(b0, 0x2c) == 5, w16(b0, 0x2c))
    check('keep_off: second man playing', w16(a, 0x22) == 1, w16(a, 0x22))
    check('keep_off: flares reset to 0 (original)', w16(a, 0x2c) == 0, w16(a, 0x2c))
    check('keep_off: back at (21,3) facing W', rd(base, 'pos.bin') == b'\x15\x03' and w16(a, 0x2a) == 3, rd(base, 'pos.bin').hex())
    check('keep_off: room-8 flare box available again', w16(rd(base, 'room8.bin'), 0) & 0x80 == 0)
    mor_off = w16(b0, 0x2e) - w16(a, 0x2e)
    k = run('keep_on', DEATH, 1910, 's1.keepItems=1,s1.checkpointRespawn=1')
    a = rd(k, 'a6.bin')
    check('keep_on: second man playing', w16(a, 0x22) == 1, w16(a, 0x22))
    check('keep_on: flares kept', w16(a, 0x2c) == 5, w16(a, 0x2c))
    check('keep_on: room-8 flare box stays taken', w16(rd(k, 'room8.bin'), 0) & 0x80 != 0)
    check('keep_on: respawn in front of room 8 facing away (15,35) E', rd(k, 'pos.bin') == b'\x0f\x23' and w16(a, 0x2a) == 1,
          (rd(k, 'pos.bin').hex(), w16(a, 0x2a)))
    check('keep_on: run is assisted', 'mode=assisted' in events(k) or 'mode=custom' in events(k))
    h = run('hitmorale', DEATH, 1910, 's1.diff.hitMorale=0x400')
    mor_on = w16(rd(h, 'a6_before.bin'), 0x2e) - w16(rd(h, 'a6.bin'), 0x2e)
    check('M10 hitMorale: wounds cost $400 instead of $c00', mor_off > 0 and mor_off % 0xc00 == 0 and mor_on * 3 == mor_off, (hex(mor_off), hex(mor_on)))

# ---------------------------------------------------------------- M15 lives
IDLE = """300 fire 1
305 fire 0
350 poke 12e4c 1 2
600 fire 1
605 fire 0
900 fire 1
905 fire 0
2900 fire 1
2905 fire 0
4600 fire 1
4605 fire 0
5000 dumpr 12dde 76 a6.bin
"""
if want('lives'):
    d = run('lives_off', IDLE, 5010)
    ev = events(d)
    check('lives_off: game over after the 2nd man (original)', 'gameOver' in ev and 'manChanged 1->2' not in ev)
    d = run('lives3', IDLE, 5010, 'game.lives=3')
    ev = events(d); a = rd(d, 'a6.bin')
    check('lives=3: third man takes over', 'manChanged 1->2' in ev, re.findall('manChanged.*', ev))
    check('lives=3: no game over yet at 5000', 'gameOver' not in ev)

# ---------------------------------------------------------------- M15 fullPlatoon (carry: man 0 KIA, man 1 wounded twice, 40 bullets)
if want('full'):
    carry = bytearray(0x76)
    recs = [(9, 0x90, 4), (7, 0x28, 2), (9, 0x90, 0), (9, 0x90, 1), (3, 0x10, 4)]
    for i, (g, am, h) in enumerate(recs): carry[6 * i:6 * i + 6] = struct.pack('>HHH', g, am, h)
    struct.pack_into('>H', carry, 0x2e, 0x9000)
    cp = os.path.join(OUT, 'carry_full.bin'); os.makedirs(OUT, exist_ok=True); open(cp, 'wb').write(carry)
    S = """300 fire 1
305 fire 0
600 fire 1
605 fire 0
900 fire 1
905 fire 0
1000 dumpr 12dde 76 a6.bin
"""
    d = run('full_on', S, 1010, 'game.fullPlatoon=1', env={'PLATOON_CARRY': cp}, args=['--start-section', '1'])
    a = rd(d, 'a6.bin')
    check('fullPlatoon: first living man (1) plays', w16(a, 0x22) == 1 and struct.unpack('>I', a[0x1e:0x22])[0] == A6 + 6,
          (w16(a, 0x22), a[0x1e:0x22].hex()))
    check('fullPlatoon: records carried over', all(struct.unpack('>HHH', a[6 * i:6 * i + 6])[2] == recs[i][2] for i in range(5)),
          a[:30].hex())
    d = run('full_off', S, 1010, env={'PLATOON_CARRY': cp}, args=['--start-section', '1'])
    a = rd(d, 'a6.bin')
    check('fullPlatoon off: records re-initialised (original)', w16(a, 0x22) == 0 and w16(a, 4) == 0 and w16(a, 2) == 0x90)

# ---------------------------------------------------------------- M4 flare retry / keep items after a lost flare night
FLARE = BOOT + """927 poke 1a0b0 271f 2
927 poke 12e08 0 2
927 poke 12e0a 8 2
938 up 1
946 up 0
975 poke 19d34 74 2
975 poke 19d36 24 2
977 fire 1
983 fire 0
1400 poke 12de2 3 2
3400 fire 1
3406 fire 0
3500 fire 1
3506 fire 0
3700 dumpr 12dde 76 a6.bin
3700 dumpr 1a0b0 2 pos.bin
3700 shot end
"""
if want('flare'):
    d = run('flare_off', FLARE, 3710)
    ev = events(d)
    ctx = re.findall(r'context screen=(\w+) area=(\w+)', ev)
    areas = [a for s, a in ctx]
    check('flare_off: flare night entered', 'flare' in areas)
    check('flare_off: death in the flare night returns to the tunnels', 'death man=0' in ev and areas[-1] == 'tunnels', areas[-5:])
    check('flare_off: flares not restored', w16(rd(d, 'a6.bin'), 0x2c) < 8, w16(rd(d, 'a6.bin'), 0x2c))
    d = run('flare_retry', FLARE, 3710, 's1.flareRetry=1')
    ev = events(d); a = rd(d, 'a6.bin')
    areas = [a2 for s, a2 in re.findall(r'context screen=(\w+) area=(\w+)', ev)]
    check('flareRetry: death in the flare night restarts the flare night', 'death man=0' in ev and areas[-1] == 'flare', areas[-5:])
    check('flareRetry: second man, 8 flares again', w16(a, 0x22) == 1 and w16(a, 0x2c) >= 7, (w16(a, 0x22), w16(a, 0x2c)))
    d = run('flare_keep', FLARE, 3710, 's1.keepItems=1')
    a = rd(d, 'a6.bin')
    areas = [a2 for s, a2 in re.findall(r'context screen=(\w+) area=(\w+)', events(d))]
    check('keepItems: back in the tunnels with the 8 flares brought into the night (no softlock)',
          areas[-1] == 'tunnels' and w16(a, 0x2c) == 8, (areas[-3:], w16(a, 0x2c)))

COMBAT_A = """300 fire 1
305 fire 0
350 poke 12e4c 1 2
600 fire 1
605 fire 0
900 fire 1
905 fire 0
936 up 1
968 up 0
968 left 1
976 left 0
979 poke 19d34 46 2
979 poke 19d36 28 2
981 fire 1
993 fire 0
1075 poke 3b237 ff 1
1113 up 1
1121 up 0
1127 up 1
1135 up 0
1141 up 1
1149 up 0
1155 up 1
1163 up 0
1179 poke 3b237 1 1
"""
# ---------------------------------------------------------------- S9c last bullet (combat B of combat.txt with 1 bullet)
LAST = COMBAT_A + """1191 poke 19d34 28 2
1191 poke 19d36 37 2
1191 poke 12de0 1 2
1195 fire 1
1207 fire 0
1300 dumpr 12dde 76 a6.bin
1300 dumpr 19d56 1 obj2.bin
"""
if want('bullet'):
    d = run('lastbullet_off', LAST, 1310)
    a = rd(d, 'a6.bin')
    check('lastbullet off: the last bullet does not kill (original)', w16(a, 2) == 0 and a[0x4e:0x52] == b'\0\0\x03\0', a[0x4e:0x52].hex())
    d = run('lastbullet_on', LAST, 1310, 's1.fixLastBullet=1')
    a = rd(d, 'a6.bin')
    check('fixLastBullet: the last bullet kills (+300)', w16(a, 2) == 0 and a[0x4e:0x52] == b'\0\0\x06\0', a[0x4e:0x52].hex())

# ---------------------------------------------------------------- S9e food, S9b morale wrap, M10 itemMorale (room 2 from S)
FOOD = BOOT + """915 poke 1a0b0 070b 2
915 poke 12e08 0 2
915 poke 12e0c ff00 2
930 up 1
938 up 0
960 poke 19d34 2d 2
960 poke 19d36 4b 2
962 fire 1
968 fire 0
1100 fire 1
1106 fire 0
1400 dumpr 12dde 76 a6.bin
"""
if want('food|morale'):
    d = run('food_off', FOOD, 1410)
    a = rd(d, 'a6.bin')
    check('food off: two clicks = +1000 (original farm)', a[0x4e:0x52] == b'\0\0\x10\0', a[0x4e:0x52].hex())
    d = run('food_on', FOOD, 1410, 's1.fixFoodFarm=1')
    a = rd(d, 'a6.bin')
    check('fixFoodFarm: food scores once', a[0x4e:0x52] == b'\0\0\x05\0', a[0x4e:0x52].hex())
MORALE = BOOT + """915 poke 1a0b0 0f23 2
915 poke 12e08 3 2
915 poke 12e0c ff00 2
930 up 1
938 up 0
960 poke 19d34 1e 2
960 poke 19d36 1e 2
962 fire 1
968 fire 0
1100 dumpr 12dde 76 a6.bin
"""
if want('morale'):
    d = run('morale_off', MORALE, 1110)
    check('morale off: +$200 wraps $ff00 -> $0100 (original)', w16(rd(d, 'a6.bin'), 0x2e) == 0x0100, hex(w16(rd(d, 'a6.bin'), 0x2e)))
    d = run('morale_on', MORALE, 1110, 's1.fixMoraleWrap=1')
    check('fixMoraleWrap: clamped at $ffff', w16(rd(d, 'a6.bin'), 0x2e) == 0xffff, hex(w16(rd(d, 'a6.bin'), 0x2e)))
    d = run('morale_knob', MORALE.replace('ff00', '4000'), 1110, 's1.diff.itemMorale=0x800')
    check('M10 itemMorale: +$800', w16(rd(d, 'a6.bin'), 0x2e) == 0x4800, hex(w16(rd(d, 'a6.bin'), 0x2e)))

# ---------------------------------------------------------------- L3 randomiser
if want('random'):
    S = BOOT + "1000 dumpr 19a60 8c items.bin\n1000 dumpr 12dde 76 a6.bin\n"
    d0 = run('rand_off', S, 1010); base = rd(d0, 'items.bin')
    lists = [0x19a60, 0x19a70, 0x19a7e, 0x19a8a, 0x19a96, 0x19aa6, 0x19ab4, 0x19ac4, 0x19ad0, 0x19ade]
    types = [0, 1, 2, 3, 0, 1, 0, 2, 1, 3]; groups = [8, 7, 6, 6]
    def room_items(b): return [[w16(b, lists[k] - 0x19a60 + 2 * g) for g in range(groups[types[k]])] for k in range(10)]
    ro = room_items(base)
    seen = set()
    for seed in (1, 2, 3, 12345):
        d = run('rand_%d' % seed, S, 1010, 's1.randomSeed=%d' % seed)
        rr = room_items(rd(d, 'items.bin'))
        seen.add(str(rr))
        ok = all(sorted(ro[k][g] for k in range(10) if types[k] == t) == sorted(rr[k][g] for k in range(10) if types[k] == t)
                 for t in range(4) for g in range(groups[t]))
        check('randomSeed=%d: per-type hotspot permutation' % seed, ok)
        check('randomSeed=%d: leave hotspots and EXIT placement valid' % seed,
              all(rr[k][-1] == 0 for k in range(10)) and sum(1 for k in range(10) if 0x15 in rr[k]) == 1
              and all(types[k] == 3 for k in range(10) if 0x15 in rr[k]) and sum(r.count(4) for r in rr) == 2)
    check('randomSeed: seeds give different layouts', len(seen) >= 3, len(seen))
    d1 = run('rand_1b', S, 1010, 's1.randomSeed=1')
    check('randomSeed: deterministic', rd(d1, 'items.bin') == rd(os.path.join(OUT, 'rand_1'), 'items.bin'))

# ---------------------------------------------------------------- L2 direct aim (combat B, target on the enemy; room click)
AIM = COMBAT_A + """1195 fire 1
1207 fire 0
1197 dumpr 19d32 6 cross.bin
1300 dumpr 12dde 76 a6.bin
"""
if want('aim'):
    # side enemy on the left at object (x $23, y $36): box centre ~ ($32,$42) -> visible (80 + $32, $42 + 16)
    tx, ty = 80 + 0x32, 0x42 + 16
    env = {'PLATOON_S1_AIM': '1180:%d,%d' % (tx, ty)}
    d = run('aim_off', AIM, 1310, env=env)
    check('directAim off: target ignored, no kill', rd(d, 'a6.bin')[0x4e:0x52] == b'\0\0\x03\0', rd(d, 'a6.bin')[0x4e:0x52].hex())
    d = run('aim_on', AIM, 1310, 's1.directAim=1', env=env)
    c = rd(d, 'cross.bin')
    cx, cy = w16(c, 2), w16(c, 4)
    check('directAim: crosshair near the target', abs(80 + cx + 9 - tx) <= 7 and abs(cy + 9 + 16 - ty) <= 7, (cx, cy))
    check('directAim: enemy killed (+300)', rd(d, 'a6.bin')[0x4e:0x52] == b'\0\0\x06\0', rd(d, 'a6.bin')[0x4e:0x52].hex())
    ROOM = BOOT + """915 poke 1a0b0 0f23 2
915 poke 12e08 3 2
930 up 1
938 up 0
962 fire 1
968 fire 0
1100 dumpr 12dde 76 a6.bin
"""
    # flare box hotspot (19,16)-(52,47) of room 8 -> object (30,30): centre visible (80+39, 30+25) (colLeft 10 -> 80 px)
    d = run('aim_room', ROOM, 1110, 's1.directAim=1', env={'PLATOON_S1_AIM': '940:%d,%d' % (80 + 39, 55)})
    check('directAim: room hotspot clicked by pointer (flares +5)', w16(rd(d, 'a6.bin'), 0x2c) == 5, w16(rd(d, 'a6.bin'), 0x2c))

# ---------------------------------------------------------------- S9d flare spawn interval
SPAWN = BOOT + """927 poke 1a0b0 271f 2
927 poke 12e08 0 2
927 poke 12e0a 8 2
938 up 1
946 up 0
975 poke 19d34 74 2
975 poke 19d36 24 2
977 fire 1
983 fire 0
""" + ''.join('%d poke 3b228 0 2\n%d poke 3b22a 0 2\n%d dumpr 3b226 2 cnt%d.bin\n' % (f, f, f + 1, f) for f in range(1100, 2500, 4))
if want('spawn'):
    d = run('spawn_off', SPAWN, 2510)
    v0 = max(w16(rd(d, 'cnt%d.bin' % f), 0) for f in range(1100, 2500, 4))
    d = run('spawn_on', SPAWN, 2510, 's1.fixFlareSpawn=1')
    v1 = max(w16(rd(d, 'cnt%d.bin' % f), 0) for f in range(1300, 2500, 4))
    check('flare spawn: original interval 0 wraps (spawns off for ~65000 iterations)', v0 > 0xff00, hex(v0))
    check('fixFlareSpawn: interval clamped to 1 (spawns keep coming)', v1 < 0x40, hex(v1))

# ---------------------------------------------------------------- M3 variant B explored map window
EXPL = BOOT + """930 left 1
936 left 0
940 up 1
980 up 0
990 right 1
996 right 0
1000 up 1
1040 up 0
1060 shot explored
1060 dumpr 3f100 739 seen.bin
"""
if want('explored'):
    d = run('explored_on', EXPL, 1070, 's1.exploredMap=1')
    seen = rd(d, 'seen.bin')
    n = sum(1 for b in seen if b)
    check('exploredMap: cells marked seen', 20 < n < 400, n)
    check('exploredMap: screenshot written', os.path.exists(os.path.join(d, 'explored.png')))

print('ALL PASS' if fails == 0 else '%d FAILED' % fails)
sys.exit(1 if fails else 0)
