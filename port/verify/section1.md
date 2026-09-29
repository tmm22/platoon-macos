# Section 1 (tunnels + flare) — end-to-end verification against tools/amiga/emu

## Method
The SAME script (full boot from power-on; `poke 12e4c 1 2` selects load section 1; no --start-section) is run
in `tools/amiga/emu --deterministic` and `platoon-headless --deterministic` (port with
`PLATOON_ENH=originalCredits=0`, i.e. the kernel's credits enhancement off). Tickdumps at the main-loop heads
($171d8 tunnel tick, $170c4 life start, $18bd8 flare iteration; $17118 for section 2 after the transition) of
- $12d70 (RNG seed, 4 bytes), $12dde (a6 globals, $78),
- $19a60-$1a0b2 (room item flags, hotspot tables, tunnel AND flare object records, spawn slots, palettes,
  crosshair speed, player position),
- $3b220-$3b3fb (all section variables)

are compared tick by tick (index-aligned) together with the frame number of every tick, plus screenshots
(PIL, pixel exact) every 4..50 frames, plus (combat) the Paula register write stream (`--reglog`).

Tools: `port/verify/section1/` (they work in /tmp/verify-section1: copy them there), scripts in
`port/verify/section1/scripts/`, last full regression output `port/verify/section1/regress.log`.
- `vr.py NAME SCRIPT FRAMES [--shot-every N] [--pcs 171d8,18bd8]` runs both tools, `cmp.py NAME` compares the
  tickdumps, `shotdiff.py NAME [MINFRAME]` all screenshots, `tl.py NAME` prints an emulator timeline,
  `regress.sh` re-runs every scenario below, `linecmp.sh` compares flare-iteration beam lines (emu --bp vs
  port S1DBG), `audcmp.py` aligns the audio register streams.
- `gen.py` route generator: BFS through the maze (`re/tunnels/assets/maze.json`); F = up 8 frames + 6 idle =
  exactly one cell, L/R = 6+6 frames; room hotspot clicks poke the crosshair (`19d34/19d36`) and fire 6 frames;
  spawns suppressed by `poke 3b237 ff 1` every ~600 frames. `sc_*.py` build the scenario scripts.
- `fixpokes.py SCRIPT EMU_171d8_TICKDUMP 4` moves every tunnel poke onto the next tick-head frame (note N1).
- `flbot.py` builds a flare script from emulator feedback (every 70 frames: poke the crosshair onto each live
  enemy at a flare-safe frame and fire 2 iterations; SPACE whenever no light cycle runs).
- MEGA CHEAT boot (`cheatboot.txt`): H A M B U R G E R, KP- H I L L typed on the title (frames 360-514), fire
  560, section poke 600, fire 1100 -> `$70(a6)=3`, tunnels from frame 1111.

## Scenarios (all: emu vs port, same script) — final regression (regress.log)

| # | scenario | script, frames | result |
|---|---|---|---|
| 1 | boot, intro text "THE TUNNEL SYSTEM", idle (first far enemy, first hit) | idle.txt, 2200 | 256 ticks identical (all regions + tick frames); all shots identical |
| 2 | idle to death: 4 hits man 1 -> KILLED IN ACTION -> "YOU DIDN'T MAKE IT / ONLY ONE ... TAKE CONTROL OF YOUR MAN" -> fire -> life restart $170c4 (man 2) -> 4 hits -> "YOUR PLATOON HAS BEEN DESTROYED" -> fire -> k_game_over | death.txt, 5600 | 562 ticks + 2 life starts identical; 222/224 shots (N2) |
| 3 | walk (21,3)->room 0 (30 cells), kill guard, all 7 hotspots + 3 again (map "WHICH YOU ALREADY HAVE", taken -> EMPTY), leave | room0.txt, 2900 | 497 ticks identical, all shots identical |
| 4 | TOUR (honest route, spawns suppressed): 10 wasted corridor shots (sfx $82), first enemy hits once, rooms 0 (guard, map + slide animation, flares 5), 2, 3 (exit blocked), 4 (compass), 1 (ammo refill, medical with 1 wound), 5, 6, 7, 9 ("YOU NEED MORE FLARES"), 8 (flares -> 8 = cap), 9: EXIT -> +30000 -> fade -> flare section (98 iterations idle). Every hotspot of every room clicked twice (all item handlers, taken -> EMPTY / NOTHING IN THIS DRAWER, food repeatable). All 20 left + 20 right view tile maps and the map window/compass are displayed during the lockstep runs | tour.txt, 21400 | 4889 tunnel ticks + 98 flare iterations identical in all regions, tick frames identical; 5350 screenshots (every 4 frames) identical except 1 frame of the kernel's HUD label print |
| 5 | combat: far enemy kill (+300), left / right side enemies, water enemy (honest aim), far enemy killed after it fired (its shot still hits), new enemy spawned meanwhile erased by the landing shot, side enemy hits, water enemy hits, last bullet cannot kill (ammo 1 -> 0), ammo 0 no shot, KIA -> text -> man 2 | combat.txt, 3600 | 484 ticks + 2 life starts identical, all shots identical; Paula writes: 17029 = 17029, all values in order except 2 DMACON pairs swapped, 76 writes 1 frame early (N2) |
| 6 | room 0 guard not killed: fires on the 36th tick -> hit, thrown out facing the room; re-enter (guard restarts), kill, map, leave, re-enter: dead body kept (frame 4, handler rts); map again; wounds 3 + water enemy -> KIA with the map -> life 2 without map, items back; morale $c00 + hit -> "WITHDRAWN FROM ACTION" -> hiscore name entry | misc.txt, 4400 | 398 ticks + 2 life starts identical; shots identical except 1 frame of text-screen printing (kernel print timing) |
| 7 | teleport to room 9: EXIT with 0 flares "YOU WILL NEED SOME FLARES", 6 flares "YOU NEED MORE FLARES", 8 flares without compass "WOULD A COMPASS HELP?" +30000 -> flare; morale $c00 -> first flare hit -> WITHDRAWN -> game over | exit.txt, 3400 | 102 ticks + 111 flare iterations identical except 1 byte in 1 tick (N3); all shots identical |
| 8 | honest room cursor (joystick, in_room acceleration) to FOOD twice (+500 twice), down in corridor does nothing, walk into a wall, fire latch after leaving a room, wasted shots | honest.txt, 2300 | 347 ticks identical, all shots identical |
| 9 | morale $fe00 + SECRET DOCUMENTS (+$200 wraps to 0) -> WITHDRAWN (no clamp quirk) | wrap.txt, 2300 | 147 ticks identical, all shots identical |
| 10 | HELP without the cheat does nothing; TAB pause/resume, F10, DEL restart during the tunnels | nohelp.txt, keys.txt | identical |
| 11 | MEGA CHEAT: HELP in the tunnels -> "LET'S GO TO THE FLARE SCREEN!" (9 flares) -> flare intro (fade, RLE background, music 6, 3 messages) -> HELP in the flare loop -> WELL DONE / YOU MADE IT THROUGH THE NIGHT -> fade -> k_next_section -> LOADING THE JUNGLE & FOXHOLE -> section 2 intro | fl_help.txt, 3400 | 23 ticks + 74 iterations identical, all shots identical |
| 12 | flare idle: enemies approach/aim/shoot in the dark, hit starts a light cycle, 4 hits -> red fade -> KIA -> back to the tunnels (flares, compass, items reset) -> HELP -> flare -> 4 hits -> DESTROYED -> game over | fl_idle.txt, 5200 | 56 ticks + 416 iterations: RAM identical every iteration; a few iteration heads 1 frame early (N2); all shots identical |
| 13 | flare crosshair: all 4 diagonals (up+left moves only up: original bug), all directions, acceleration, shots into the dark (jitter, spawn base -2), SPACE flare, SPACE ignored during the cycle, palette sequence night0-3-0 | flmove.txt, 2800 | 218 iterations identical (RAM), all shots identical |
| 14 | FULL FLARE GAME (flbot): first flare by fire on the flare box, then 8 more by SPACE, 20 enemies killed in all light phases, 9 light cycles -> natural win -> section 2 loads and is started with fire (484 section-2 ticks) | flp2.txt, 7400 | 1572 flare iterations identical (RAM AND every frame number); section 2 afterwards: section RAM identical (only a6+$6b / frames +-1 = section-2 pacing); 2 shots differ (kernel print timing) |
| 15 | zero-flare quirk: flares poked to 0, a hit starts a light cycle ($3b224 from 0 -> 255 iterations), cycle ends with 0 flares -> win -> section 2 (wounds reset in the hit freezes) | flq1.txt, 4200 | 518 iterations identical (RAM); message frames +-1 (N2) |
| 16 | flare hits during lit phases (SPACE every ~200 frames, no shooting) | fl_lit.txt, 3200 | identical up to iteration 176; then diverges (N2b) |

## Fixes made (port/Sources/PlatoonCore/Game/Section1)
- Section1.swift `s1_tunnelMainLoop`: `settleCPU()` before testing the vblank-driven counter `$6a(a6)`. The test
  ran before the CPU time of f834 had elapsed (e.g. a queued message starting inside f834, ~300 lines), so the
  port saw `$6a`=0 where the A500 already saw -1 and the next tick came one frame late (tour: from frame 16060
  every tick 1-2 frames late, the flare section entered 2 frames early, 33 screenshots different).
- Section1.swift `S1Cyc.bgRow` 1050 -> 1023: copy_background measured in the emulator at 95 rows / 214 lines
  (dbra $18e34, no interrupt in between); the old value had the level-3 handler (~10 lines with music) folded in,
  which the kernel's irqCharge charges again. Flare iterations were ~10 lines slow; 29 of 416 iteration heads
  crossed into the next frame (fl_idle); now the crosshair handler lands within -2..+5 lines of the emulator.

## Notes / remaining differences
- N1 (test artefact): pokes land at the start of a frame; the port runs a tick's logic ahead of emulated time
  and pays the CPU time at the next settle point, so a poke that falls inside a tick's CPU stretch is seen at a
  different point of the logic than in the emulator. Tunnel pokes are therefore put on tick-head frames (before
  the tick's logic in both tools), flare pokes on frames F with F-1 = iteration head.
- N2 (audio cost model, reported in STATUS): sample sfx pairs cost ~52 lines in the emulator
  (k_fx($83) $1920c v234 -> $19212 v286; k_fx($80) $17d26 v248 -> v300), the port charges 45.6 (md_sfx charges
  only the dma_delay busy-waits). Effects: the wound icon appears one frame early after a tunnel hit (f1625 vs
  f1626); flare iterations containing an enemy shot / kill end ~6 lines early and sometimes a head moves across
  a frame boundary (RAM state per iteration identical). Experiment: adding 2900 cycles per sample-sfx call (in
  a temporary hook in s1_fx, removed again) made fl_lit fully identical and removed all but one 1-frame offset
  in fl_idle/flmove, confirming the cause. The fix belongs in Audio/MusicDriver.swift (md_sfx), not here.
  - N2b: in fl_lit a SPACE press starts in the frame where the emulator's iteration is still 1 frame behind the
    port's (N2): the emulator launches the flare one iteration earlier and the runs diverge from there. With the
    sfx cost corrected (experiment above) the run is identical.
  - The remaining single 1-frame offset (flare iteration 108 of fl_idle/flmove: emulator head at f1971 v11,
    port f1970 v310) is a 2-3 line shortfall of the iteration tail (list2 blits + f834) right at the frame
    boundary (kernel f834 cost, ~57 lines in the emulator).
- N3 (sub-line timing coincidence): in rooms the crosshair handler reads the joystick at line ~311/312, right at
  the frame boundary. In scenario 7 one tick head is 1 line later in the emulator (f834 printing a message), so
  the emulator samples after the vblank (fire already released) and the port just before (fire still held):
  the room fire latch $3b22f is cleared one tick later in the port (no gameplay effect).
- Kernel print timing (not section 1): text screens / HUD labels are drawn instantly by the port but glyph by
  glyph in the emulator, so a frame captured while printing can differ by one glyph (f904 HUD labels, f2560
  text screen, f5580 section-2 intro).
- Not reproduced: the flare spawn-interval-0 wrap (needs base+killbonus = 0 at a spawn with a free record; in
  flq2.txt all 5 enemies were alive when the base reached 0, the run is identical anyway).
