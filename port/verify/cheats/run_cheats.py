#!/usr/bin/env python3
"""Headless checks of the cheats (Enhance/CheatOptions.swift, `// ENHANCEMENT CHEAT-*` hooks).

usage: port/verify/cheats/run_cheats.py [--bin PLATOON_HEADLESS] [--out DIR] [--only REGEX] [--list]

Every scenario runs platoon-headless twice or more (the cheat on, and a control run with the cheat off that must show
the effect the cheat removes), with PLATOON_EVENTS (F2 event log) and RAM dumps of the a6 globals ($12dde, $76 bytes:
man records +0 grenades / +2 ammo / +4 hits, $2c flares, $2e morale, $6c timer, $70 cheat flags). Screenshots of the
interesting frames are written to OUT/<scenario>/<run>/. Prints one PASS/FAIL line per check; exit 1 on any FAIL.
"""
import argparse, os, re, subprocess, sys, struct

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
ADF = os.path.join(ROOT, "re/platoon_port.adf")
A6 = 0x12dde

ap = argparse.ArgumentParser()
ap.add_argument("--bin", default="/tmp/pbuild-cheats/release/platoon-headless")
ap.add_argument("--out", default="/tmp/cheats-verify")
ap.add_argument("--only", default=None)
ap.add_argument("--list", action="store_true")
args = ap.parse_args()

# boot prefixes (frames absolute from power-on; RE recipes: $12e4c = $6e(a6) next load section)
# (fire at 900: past the section's intro text screen; the S2 recipes poke the start room / map byte at 880 first)
BOOT_S1 = ["300 fire 1", "305 fire 0", "350 poke 12e4c 1 2", "600 fire 1", "605 fire 0", "900 fire 1", "905 fire 0"]
BOOT_S2_PRE = ["300 fire 1", "305 fire 0", "350 poke 12e4c 2 2", "600 fire 1", "605 fire 0"]
BOOT_S2 = BOOT_S2_PRE + ["900 fire 1", "905 fire 0"]


def run(name, sub, enh, script, frames, dumps=(), start=None, shots=(), shot_every=0):
    d = os.path.join(args.out, name, sub)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        os.remove(os.path.join(d, f))
    lines = list(script)
    for f in dumps:
        lines.append(f"{f} dumpr {A6:x} 76 a6_{f}.bin")
    for f in shots:
        lines.append(f"{f} shot shot_{f}")
    with open(os.path.join(d, "script.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    cmd = [args.bin, "--adf", ADF, "--frames", str(frames), "--script", os.path.join(d, "script.txt"), "--out", d]
    if start is not None:
        cmd += ["--start-section", str(start)]
    if shot_every:
        cmd += ["--shot-every", str(shot_every)]
    if enh:
        cmd += ["--enh", enh]
    env = dict(os.environ, PLATOON_EVENTS=os.path.join(d, "events.txt"))
    env.pop("PLATOON_ENH", None)
    subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=600)
    ev = open(os.path.join(d, "events.txt")).read().splitlines() if os.path.exists(os.path.join(d, "events.txt")) else []
    ram = {}
    for f in dumps:
        p = os.path.join(d, f"a6_{f}.bin")
        if os.path.exists(p):
            ram[f] = open(p, "rb").read()
    return Run(d, ev, ram)


class Run:
    def __init__(self, d, ev, ram):
        self.dir, self.events, self.ram = d, ev, ram

    def count(self, pat):
        r = re.compile(pat)
        return sum(1 for e in self.events if r.search(e))

    def w(self, frame, off):
        b = self.ram[frame]
        return struct.unpack(">H", b[off:off + 2])[0]

    def man(self, frame, i):
        return {"grenades": self.w(frame, 6 * i), "ammo": self.w(frame, 6 * i + 2), "hits": self.w(frame, 6 * i + 4)}

    def cur(self, frame):
        return self.w(frame, 0x22)

    def morale(self, frame):
        return self.w(frame, 0x2e)


results = []


def check(scn, what, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {scn:14s} {what}" + (f"   [{detail}]" if detail else ""))


HURT = r"wounded|manSelect|YOU'RE HIT|KILLED IN ACTION|death man|gameOver"


def hurt_summary(r):
    return f"wounded={r.count('wounded')} manSelect={r.count('manSelect')} hit_msgs={r.count(chr(39).join(['YOU', 'RE HIT']))} " \
           f"kia={r.count('KILLED IN ACTION')} gameOver={r.count('gameOver')}"


def invincible_scenario(name, script, frames, start=None, extra_enh="", dumps=(), expect_control_hurt=True, shots=()):
    on = run(name, "on", ",".join(x for x in ["cheat.invincible=1", extra_enh] if x), script, frames, dumps, start, shots)
    off = run(name, "off", extra_enh, script, frames, dumps, start, shots)
    check(name, "invincible: no wound / hit / man select / death", on.count(HURT) == 0, hurt_summary(on))
    if expect_control_hurt:
        check(name, "control (cheat off) does get hurt", off.count(HURT) > 0, hurt_summary(off))
    if dumps:
        f = dumps[-1]
        hits = [on.man(f, i)["hits"] for i in range(5)]
        check(name, "invincible: all wound counters 0 at the end", hits == [0] * 5, f"hits={hits}")
    return on, off


# ---------------------------------------------------------------------------------------------------------------
SCENARIOS = {}


def scenario(f):
    SCENARIOS[f.__name__] = f
    return f


@scenario
def s0_idle():
    """Jungle start: stand still for ~4400 frames (soldiers walk up, shoot, stab)."""
    on, off = invincible_scenario("s0_idle", [], 5000, start=0, dumps=(700, 4990))
    # morale: only the per-tick decay, no -$800 per hit
    m0, m1 = on.morale(700), on.morale(4990)
    check("s0_idle", "invincible: morale only decays by the 1-per-tick rule", 0 < m0 - m1 < 2300, f"{m0:04x}->{m1:04x}")


@scenario
def s0_walk():
    """Jungle: walk right on level 1 for 4000 frames (tripwires ahead, contact with soldiers, bridge)."""
    script = ["650 right 1"]
    on, off = invincible_scenario("s0_walk", script, 4700, start=0, dumps=(4690,), shots=(4690,))
    check("s0_walk", "a tripwire went off at the player (fx $85)", on.count(r"fx \$85") > 0, f"fx85={on.count('fx .85')}")


@scenario
def s0_hut2_guard():
    """Village hut 2 (VC guard shoots 15 ticks after you enter, then every 25): start pos poked to col $39."""
    script = ["560 poke 1a6da 00390000 4", "700 up 1", "740 up 0"]
    invincible_scenario("s0_hut2_guard", script, 4000, start=0, dumps=(760, 3990), shots=(800, 3990))


@scenario
def s0_hut0_trap():
    """Village hut 0: search the booby-trapped spot ($60c30 = $190) -> explosion at the player."""
    script = ["560 poke 1a6da 002e0000 4", "700 up 1", "740 up 0"]
    # step right in small pulses and search (UP) after each: the first spot is the booby trap
    f = 800
    for _ in range(6):
        script += [f"{f} right 1", f"{f + 3} right 0", f"{f + 20} up 1", f"{f + 26} up 0"]
        f += 60
    on, off = invincible_scenario("s0_hut0_trap", script, 1800, start=0, dumps=(1790,), shots=(1300,))
    check("s0_hut0_trap", "the booby trap went off (message $0f)", on.count(r"idx=\$0f") > 0, f"msgs={on.count('idx=.0f')}")


@scenario
def s1_tunnels():
    """Tunnels: stand in the corridor; enemies walk up, aim and fire (+ water enemies)."""
    invincible_scenario("s1_tunnels", BOOT_S1, 6000, dumps=(1000, 5990), shots=(5990,))


@scenario
def s1_flare():
    """Flare night (HELP route with the original cheats): enemies rise behind the sandbags and shoot."""
    script = BOOT_S1 + ["915 key 5f 1", "925 key 5f 0"]
    on, off = invincible_scenario("s1_flare", script, 6000, extra_enh="cheat.original=1", dumps=(5990,), shots=(3000, 5990))
    check("s1_flare", "the flare night was reached", on.count(r"idx=\$24") > 0 and off.count(r"idx=\$24") > 0)


@scenario
def s2_jungle():
    """Final jungle start room: soldiers shoot, the sniper fires when you keep your depth."""
    invincible_scenario("s2_jungle", BOOT_S2, 5500, dumps=(1000, 5490), shots=(5490,))


@scenario
def s2_mines():
    """Final jungle: walk into mines (verify/section2/mines.txt recipe: room type $0c)."""
    script = BOOT_S2_PRE + ["880 poke 18f0d 0c 1", "900 fire 1", "905 fire 0", "930 up 1", "955 up 0", "955 left 1",
                           "960 left 0", "960 up 1", "964 up 0", "1010 left 1", "1024 left 0", "1024 up 1", "1034 up 0",
                           "1080 right 1", "1090 right 0", "1090 up 1", "1140 up 0"]
    on, off = invincible_scenario("s2_mines", script, 1600, dumps=(1590,), shots=(1100,))
    check("s2_mines", "a mine exploded (sfx $81)", on.count(r"fx \$81") > 0, f"fx81={on.count('fx .81')}")


@scenario
def s2_wire():
    """Final jungle: walk into barbed wire (verify/section2/wire.txt recipe: room type $0e)."""
    script = BOOT_S2_PRE + ["880 poke 18f0d 0e 1", "900 fire 1", "905 fire 0", "930 up 1", "945 up 0", "1000 up 1",
                           "1010 up 0", "1050 left 1", "1080 left 0", "1080 up 1", "1110 up 0", "1110 right 1", "1125 right 0",
                           "1130 up 1", "1400 up 0"]
    invincible_scenario("s2_wire", script, 1600, dumps=(1590,), shots=(1200,))


@scenario
def s2_bunker():
    """Bunker room (start room poked to 14, RE recipe): Barnes shoots."""
    script = BOOT_S2_PRE + ["880 poke 18174 e 2", "900 fire 1", "905 fire 0"]
    invincible_scenario("s2_bunker", script, 5000, dumps=(1000, 4990), extra_enh="cheat.freezeTimer=1", shots=(2000,))


@scenario
def ammo():
    """Infinite ammo / grenades: fire and throw in the jungle, tunnels and final jungle (+ bunker grenades)."""
    s0 = ["700 fire 1", "2700 fire 0"] + [f"{f} key 40 {1 if i % 2 == 0 else 0}" for i, f in enumerate(range(2800, 3600, 40))]
    for sub, enh in (("on", "cheat.infiniteAmmo=1,cheat.infiniteGrenades=1,cheat.invincible=1"), ("off", "cheat.invincible=1")):
        r = run("ammo_s0", sub, enh, s0, 3700, dumps=(690, 3690), start=0)
        a0, a1 = r.man(690, 0), r.man(3690, r.cur(3690))
        shots = r.count(r"fx \$82")
        if sub == "on":
            check("ammo_s0", "jungle: rounds and grenades unchanged after firing/throwing", a1["ammo"] == 0x90 and a1["grenades"] == 9,
                  f"{a0}->{a1} shots={shots} throws={r.count('fx .0a')}")
        else:
            check("ammo_s0", "control: rounds/grenades used", a1["ammo"] < 0x90 and a1["grenades"] < 9, f"{a1}")
    # tunnels: fire in the corridor (every press uses a round) and in combat
    s1 = BOOT_S1 + [f"{f} fire {1 if i % 2 == 0 else 0}" for i, f in enumerate(range(1100, 3000, 20))]
    for sub, enh in (("on", "cheat.infiniteAmmo=1,cheat.invincible=1"), ("off", "cheat.invincible=1")):
        r = run("ammo_s1", sub, enh, s1, 3100, dumps=(1090, 3090))
        a1 = r.man(3090, r.cur(3090))
        if sub == "on":
            check("ammo_s1", "tunnels: rounds unchanged after firing", a1["ammo"] == 0x90, f"{a1} shots={r.count('fx .8[23]')}")
        else:
            check("ammo_s1", "control: rounds used", a1["ammo"] < 0x90, f"{a1}")
    # final jungle: rifle in the start room, grenades in the bunker
    s2 = BOOT_S2 + [f"{f} fire {1 if i % 2 == 0 else 0}" for i, f in enumerate(range(1000, 2000, 10))]
    s2b = BOOT_S2_PRE + ["880 poke 18174 e 2", "900 fire 1", "905 fire 0"] + \
        [f"{f} fire {1 if i % 2 == 0 else 0}" for i, f in enumerate(range(1000, 1600, 20))]
    for sub, enh in (("on", "cheat.infiniteAmmo=1,cheat.infiniteGrenades=1,cheat.invincible=1"), ("off", "cheat.invincible=1")):
        r = run("ammo_s2", sub, enh, s2, 2100, dumps=(990, 2090))
        rb = run("ammo_s2b", sub, enh + ",cheat.freezeTimer=1", s2b, 1700, dumps=(990, 1690))
        a1, g1 = r.man(2090, r.cur(2090)), rb.man(1690, rb.cur(1690))
        if sub == "on":
            check("ammo_s2", "final jungle: rounds unchanged, bunker grenades unchanged",
                  a1["ammo"] == 0x90 and g1["grenades"] == 9, f"rifle {a1} shots={r.count('fx .82')}; bunker {g1} throws={rb.count('fx .0a')}")
        else:
            check("ammo_s2", "control: rounds and grenades used", a1["ammo"] < 0x90 and g1["grenades"] < 9, f"{a1} {g1}")


@scenario
def flares():
    """Infinite flares: 8 flares in the tunnels (exit requirement); the flare night still ends with the last flare."""
    r = run("flares_s1", "on", "cheat.infiniteFlares=1", BOOT_S1, 1400, dumps=(1390,))
    check("flares", "tunnels: flare count kept at 8", r.w(1390, 0x2c) == 8, f"flares={r.w(1390, 0x2c)}")
    rc = run("flares_s1", "off", "", BOOT_S1, 1400, dumps=(1390,))
    check("flares", "control: tunnels start without flares", rc.w(1390, 0x2c) == 0, f"flares={rc.w(1390, 0x2c)}")
    # the flare night via HELP (9 flares): fire them all with SPACE, the night must still be survived -> section 2
    s = BOOT_S1 + ["1100 key 5f 1", "1110 key 5f 0"] + [f"{f} key 40 {1 if i % 2 == 0 else 0}" for i, f in enumerate(range(1800, 9000, 25))]
    r = run("flares_night", "on", "cheat.infiniteFlares=1,cheat.original=1,cheat.invincible=1", s, 9500, dumps=(1790,))
    check("flares", "flare night: flares fired, the night ends (WELL DONE -> section 2)",
          r.count(r"idx=\$28") > 0 and r.count("sectionStart 2") > 0, f"launches={r.count('fx .0a')} won={r.count('idx=.28')}")


@scenario
def morale():
    """Infinite morale: hits in each section cost nothing, the jungle's per-tick decay stops."""
    r = run("morale_s0", "on", "cheat.infiniteMorale=1", [], 3000, dumps=(700, 2990), start=0)
    check("morale", "jungle: morale unchanged despite hits and ticks", r.morale(700) == r.morale(2990) == 0x9000 and r.count("wounded") > 0,
          f"{r.morale(700):04x}->{r.morale(2990):04x} hits={r.count('wounded')}")
    r = run("morale_s1", "on", "cheat.infiniteMorale=1", BOOT_S1, 6000, dumps=(1000, 5990))
    check("morale", "tunnels: morale unchanged despite hits", r.morale(1000) == r.morale(5990) and r.count("wounded") > 0,
          f"{r.morale(1000):04x}->{r.morale(5990):04x} hits={r.count('wounded')}")
    r = run("morale_s2", "on", "cheat.infiniteMorale=1", BOOT_S2, 4000, dumps=(1000, 3990))
    check("morale", "final jungle: morale unchanged despite hits", r.morale(1000) == r.morale(3990) and r.count("wounded") > 0,
          f"{r.morale(1000):04x}->{r.morale(3990):04x} hits={r.count('wounded')}")


@scenario
def timer():
    """Freeze timer: the final jungle's 2:00 stays 2:00; control counts down."""
    for sub, enh in (("on", "cheat.freezeTimer=1,cheat.invincible=1"), ("off", "cheat.invincible=1")):
        r = run("timer", sub, enh, BOOT_S2, 4000, dumps=(1000, 3990), shots=(3990,))
        t0, t1 = r.w(1000, 0x6c), r.w(3990, 0x6c)
        if sub == "on":
            check("timer", "timer frozen at 02:00", t0 == t1 == 0x200, f"{t0:04x}->{t1:04x}")
        else:
            check("timer", "control: timer runs", t1 < t0, f"{t0:04x}->{t1:04x}")
    # frozen timer = no napalm: 8000 frames (> 2:00) in the start room
    r = run("timer_long", "on", "cheat.freezeTimer=1,cheat.invincible=1", BOOT_S2, 8500, dumps=(8490,))
    check("timer", "no napalm strike after 2:40 of play", r.count("NAPALM") == 0 and r.count("gameOver") == 0, f"t={r.w(8490, 0x6c):04x}")


def men_script(boot, pokes_at, fire_from, fire_to, step=60):
    s = list(boot) + pokes_at
    s += [f"{f} fire {1 if i % 2 == 0 else 0}" for i, f in enumerate(range(fire_from, fire_to, step // 2))]
    return s


@scenario
def men():
    """Infinite men: every soldier on his last wound; the last one is patched up instead of the game ending."""
    last = [f"{0x12de2 + 6 * i:x} 3 2" for i in range(5)]
    # jungle: all 5 men at 3 hits -> each hit kills; fire presses leave the CHOOSE YOUR MAN screen
    s0 = ["690 poke " + p for p in last]
    s0 = men_script([], s0, 1000, 12000, step=120)
    # (infinite morale in both runs: every hit costs $800, so morale would end the game first)
    for sub, enh in (("on", "cheat.infiniteMen=1,cheat.infiniteMorale=1"), ("off", "cheat.infiniteMorale=1")):
        r = run("men_s0", sub, enh, s0, 12000, dumps=(11990,), start=0)
        go = r.count("gameOver")
        if sub == "on":
            check("men", "jungle: all men killed, no game over", go == 0 and r.count("KILLED IN ACTION") >= 5,
                  f"kia={r.count('KILLED IN ACTION')} gameOver={go}")
        else:
            check("men", "control: the platoon is wiped out", go > 0, f"kia={r.count('KILLED IN ACTION')} gameOver={go}")
    s1 = men_script(BOOT_S1, ["1000 poke 12de2 3 2", "1000 poke 12de8 3 2"], 1100, 14000, step=200)
    for sub, enh in (("on", "cheat.infiniteMen=1,cheat.infiniteMorale=1"), ("off", "cheat.infiniteMorale=1")):
        r = run("men_s1", sub, enh, s1, 14000, dumps=(13990,))
        go = r.count("gameOver") + r.count("DESTROYED")
        if sub == "on":
            check("men", "tunnels: both men killed, no PLATOON DESTROYED", go == 0 and r.count("KILLED IN ACTION") >= 2,
                  f"kia={r.count('KILLED IN ACTION')} lost={go}")
        else:
            check("men", "control: platoon destroyed", go > 0, f"kia={r.count('KILLED IN ACTION')} lost={go}")
    s2 = men_script(BOOT_S2, ["1000 poke 12de2 3 2", "1000 poke 12de8 3 2"], 1100, 9000, step=200)
    for sub, enh in (("on", "cheat.infiniteMen=1,cheat.freezeTimer=1,cheat.infiniteMorale=1"),
                     ("off", "cheat.freezeTimer=1,cheat.infiniteMorale=1")):
        r = run("men_s2", sub, enh, s2, 9000, dumps=(8990,))
        go = r.count("gameOver")
        if sub == "on":
            check("men", "final jungle: both men killed, no game over", go == 0 and r.count("KILLED IN ACTION") >= 2,
                  f"kia={r.count('KILLED IN ACTION')} gameOver={go}")
        else:
            check("men", "control: all dead -> game over", go > 0, f"kia={r.count('KILLED IN ACTION')} gameOver={go}")


@scenario
def original():
    """Original developer cheats: $70(a6) = 3, MEGA CHEAT on the credits, F1-F4 warps, HELP / CAPS LOCK skips."""
    r = run("orig_title", "on", "cheat.original=1", [], 700, dumps=(690,), shots=(400,))
    check("original", "$12e4e == 3 on the title", r.w(690, 0x70) == 3, f"$70={r.w(690, 0x70):04x}")
    check("original", "hiscore mode assisted", any("mode=assisted" in e for e in r.events))
    rc = run("orig_title", "off", "", [], 700, dumps=(690,))
    check("original", "control: $12e4e == 0", rc.w(690, 0x70) == 0 and any("mode=original" in e for e in rc.events))
    # jungle warps: F2 (level 4 x $2d), F4 (village), F1 back to the start
    s = ["700 key 51 1", "712 key 51 0", "900 dumpr 60c24 4 w2.bin", "1000 key 53 1", "1012 key 53 0", "1200 dumpr 60c24 4 w4.bin",
         "1300 key 50 1", "1312 key 50 0", "1500 dumpr 60c24 4 w1.bin", "1600 key 54 1", "1606 key 54 0", "1700 dumpr 60ca0 2 inv.bin"]
    r = run("orig_jungle", "on", "cheat.original=1,cheat.invincible=1", s, 1800, start=0, shots=(900, 1200, 1500, 1750))
    rd = lambda n: open(os.path.join(r.dir, n), "rb").read().hex() if os.path.exists(os.path.join(r.dir, n)) else "-"
    check("original", "jungle F2 / F4 / F1 warps ($60c24)", (rd("w2.bin"), rd("w4.bin"), rd("w1.bin")) == ("002d0004", "00410000", "00050001"),
          f"{rd('w2.bin')} {rd('w4.bin')} {rd('w1.bin')}")
    check("original", "jungle F5 = original invincibility ($60ca0)", rd("inv.bin") != "0000", rd("inv.bin"))
    rc = run("orig_jungle", "off", "cheat.invincible=1", s, 1800, start=0)
    check("original", "control: no warp without the cheat", open(os.path.join(rc.dir, "w2.bin"), "rb").read().hex() == "00050001")
    # tunnels HELP -> flare night; flare night HELP -> section 2
    s = BOOT_S1 + ["915 key 5f 1", "925 key 5f 0", "2400 key 5f 1", "2410 key 5f 0"]
    r = run("orig_help", "on", "cheat.original=1,cheat.invincible=1", s, 3200, shots=(1300, 3100))
    check("original", "HELP: tunnels -> flare night -> section 2", r.count(r"idx=\$24") > 0 and r.count("sectionStart 2") > 0,
          f"flare={r.count('idx=.24')} s2={r.count('sectionStart 2')}")
    # final jungle CAPS LOCK -> game won
    s = BOOT_S2 + ["1100 key 62 1", "1110 key 62 0"]
    r = run("orig_caps", "on", "cheat.original=1", s, 1600, shots=(1400,))
    check("original", "CAPS LOCK in the final jungle: YOU MADE IT", r.count("YOU MADE IT") > 0)


def main():
    if args.list:
        for k, f in SCENARIOS.items():
            print(f"{k:14s} {f.__doc__}")
        return
    for k, f in SCENARIOS.items():
        if args.only and not re.search(args.only, k):
            continue
        f()
    n, bad = len(results), results.count(False)
    print(f"\n{'ALL PASS' if bad == 0 else f'{bad} FAIL'} ({n} checks)")
    sys.exit(1 if bad else 0)


main()
