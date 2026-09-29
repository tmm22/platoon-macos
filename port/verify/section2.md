# Verification: section 2 (final jungle + foxhole/bunker + endings)

Owner files: port/Sources/PlatoonCore/Game/Section2/*.swift. Reference: tools/amiga/emu, disk re/platoon_port.adf.
Scratch/outputs: /tmp/verify-section2/ (scripts are reproduced/listed here).

## Method
- Harness `/tmp/verify-section2/run.sh NAME SCRIPT FRAMES`: runs emu and platoon-headless (both `--deterministic`) with the
  same script from power-on and tick-dumps at the main-loop head $17118: slots+vars+palette+buckets $57e22+$270,
  a6 globals $12dde+$78, code-block vars $18f1c+$fc (room, dirs, soldier params, path width, score kill const),
  $17226 (last time), $189d8+8 (hint table); room_enter_done $170f4 (a6 globals); plus tick-head positions
  (emu `--bp`, port `PLATOON_TRACE=1`) compared by `bpcmp.py` (frame/raster line of every tick head).
- Scripts for honest play are generated closed-loop against the emulator (`honest/drive.py` + `honest/plan.py`: BFS path
  planner with the exact pl_move rules and static-object boxes, replanning whenever the emulator state deviates from the
  prediction), then replayed unchanged in both tools.

## Results log

### S1 natural 2:00 time-out (napalm) — `/tmp/verify-section2/napalm.txt`
Script: boot script (`300 fire 1/305 fire 0/350 poke 12e4c 2 2/600 fire 1/605 fire 0/900 fire 1/905 fire 0`) +
`930 poke 17d68 4e75 2` (invulnerable: player_hit = rts; the port honours this code patch) + `7150 fire 1/7156 fire 0`
(leave the napalm text) + `7700 fire 1/7705 fire 0`. 8200 frames. Player idles in the start room: soldiers walk and shoot,
idle-sniper shots every ~100 ticks, hints (incl. "NOT LONG BEFORE THE NAPALM" in the last minute), timer to 00:00.
- Unpaced: all 5973 main-loop ticks: slots/vars $57e22+$270 and code-block vars $18f1c+$fc IDENTICAL every tick;
  time_up $1718a at f6903 v268 in both; napalm text wait left at f7150 in both, k_game_over f7150; GAME OVER/title
  screenshots identical. Differences: a6 timer sub-counter/vLastTime/hint-1 switch at single ticks where the port's tick
  head is one frame early/late (kernel TIME-redraw ordering and audio sfx cost; see STATUS NEED kernel/audio);
  30/82 screenshots of the play phase differ by one tick of object motion for the same reason.
- Paced (`PACE=1`: port tick heads held to the emu's measured beam positions via S2PACE, see FinalJungle.swift):
  ALL tick dumps identical for all 5974 ticks (incl. a6 globals and the timer) and 73/73 screenshots (every 100
  frames, incl. play, napalm text, GAME OVER, title) pixel-identical.

### S2 bunker fight + win (foxhole) — `/tmp/verify-section2/fox1.txt`
Boot script + `880 poke 18174 e 2` (start room = bunker room 14, RE recipe) + `930 poke 57f5a 7fff 2` (Barnes holds fire),
UP 930-940 (depth 20), FIRE presses at 942/970/998/1026/1054, UP 1090-1150 (to the door), FIRE 1350 (leave text).
- 204 bunker ticks: slots/vars identical every tick. Grenades 9->4 by fire, Barnes hp 50->0 (5 direct hits, messages
  DIRECT HIT/YOU GOT HIM, "GET TO THE BUNKER - NOW!"), then the PHANTOM '.' quirk auto-throws the remaining 4 grenades at
  f1070/1087/1105/1122 in both (identical frames). game_won $17c0a at f1129 (emu v207 / port v208); "YOU MADE IT!" text;
  fire at 1350 -> k_game_over f1350 in both -> title (score 0 does not qualify).
- Screenshots every 2 frames: 889/900 identical; the 11 differing: TIME digit redraw one tick late (kernel), transient
  frames during kernel k_clear_screens / res_print progress (kernel, see STATUS), and f1132-1136 during my
  clear_play_and_pal (FIXED, below).
- Re-run after the clear_play_and_pal fix (fox1b): the partly-cleared playfield frame f1132 now matches (bottom stripe
  still visible in both); the remaining diffs of f1132-1138 are the HUD area cleared by the kernel's k_clear_screens
  (instant in the port, progressive on the A500) -> kernel.

### S3 bunker: Barnes shooting, grenade variants, deaths, second chance, all dead — `/tmp/verify-section2/fox2.txt`
Boot + `880 poke 18174 e 2`; UP 930-940; '.' key (`key 0x39`) press 950-953 (grenade via the key, hit); LEFT 960-968
(x 128) + FIRE 975 (miss: sfx $85 explosion); UP 990-1005 (depth 50) + FIRE 1010 (grenade lands at y 132: explosion
drawn at the top of the window); UP 1015-1020 (depth 60) + FIRE 1025 (grenade vanishes, y u>= $8c, no explosion); then
standing: Barnes' aimed bullets hit the player repeatedly (YOU'RE HIT / KILLED IN ACTION, wound marks, morale -$800,
respawn at ($a0,0) with Barnes' bullets removed); FIRE every 100 frames 1100-3400 (throws from depth 0 = misses; leaves
the text screens).
- 433 ticks: slots/vars/code-block vars identical every tick. second chance $17e96 at f1128 (emu v208 / port v207),
  "ONE OF YOUR PLATOON MEMBERS..." left at f1300 in both, fj_restart $17068 at f1302 (restart in room 14 thanks to the
  immediate poke; man 1), all_dead $17f18 at f1554 in both, "YOUR PLATOON HAS BEEN DESTROYED!" left at f1700 in both,
  k_game_over f1700.
- Screenshots (every 4 frames, section part): differences only in TIME redraw tick, kernel clear/print transients.

### S4 time-out inside the bunker — `/tmp/verify-section2/fox4.txt`
Boot + `880 poke 18174 e 2` + `930 poke 12e4a 0003 2` (timer 00:03) + UP 930-945 + FIRE 1300.
129 ticks identical; time_up $1718a at f1053 v261 in both; white flash (16 steps x 4 vblanks) colours identical frame by
frame (sampled pixels equal); napalm text left at f1300 in both -> k_game_over. Screenshot diffs: during the flash the
HUD shows the TIME drawn by the last tick: emu 00:00, port 00:01 (kernel TIME-redraw ordering, NEED kernel), plus
clear transients.

### S5 morale zero — `/tmp/verify-section2/morale.txt`
Boot + `930 poke 12e0c 0001 2` (morale 1) + FIRE 1400. First hit (soldier bullet) -> morale 0 -> morale_zero $17f04 at
f984 v204 in both, "YOUR PLATOON HAS BEEN DESTROYED!" (the original's overwritten-a0 bug reproduced: the WITHDRAWN text is
never shown), left at f1400 in both -> k_game_over. 59 ticks identical; 1 screenshot diff (TIME tick).

### S6 MEGA CHEAT CAPS LOCK + hiscore entry — `/tmp/verify-section2/caps.txt`
Boot + `930 poke 12e4f 02 1` (MEGA CHEAT) + `935 poke 12e2c 00012345 4` (score) + `960 key 0x62 1`/`966 key 0x62 0` +
FIRE 1100; then RIGHT/FIRE pairs every 30 frames 1400-1700 and FIRE every 30 frames 1800-2400 (name entry).
game_won via CAPS LOCK at f961 (emu v18 / port v17); "YOU MADE IT!" left at f1100 in both; GAME OVER -> "ENTER YOUR NAME:"
with 00012345 -> hiscore table -> title -> new game: screens identical at the sampled frames (diffs only in kernel
name-entry/title transients, not section-2 code).

### S7 mines / barbed wire / rocks+logs (walking into hazards) — `/tmp/verify-section2/{mines,wire,rocks}.txt`
The start-room map byte is poked (`880 poke 18f0d TT 1`, RE recipe) to room type $0c (5 mines, types 3/4/5), $0e (barbed
wire types 6/7) and $06 (rock type 0, logs 9/10, wire 7), then the player walks into the objects.
- mines: mine type 4 explodes on contact (explosion bob, sfx $81 via $57f64, YOU'RE HIT, wound, morale -$800), second
  hit later; 375 ticks, all tick dumps (incl. a6) identical.
- wire: blocked + hurt 4 times -> KILLED IN ACTION -> second chance $17e96 at f1124 (emu v210 / port v209); 199 ticks
  identical.
- rocks/logs: blocking (position/path width restored from $57f46/$19014), wire hits; 373 ticks identical.
- Screenshots every 2 frames: only TIME-tick, wound-icon draw (kernel k_hud_wounds drawn one frame earlier) and kernel
  clear transients differ.

### S8 RE teleport route (cheat path, compass carried) — `/tmp/verify-section2/tele.txt`
`re/foxhole/work/route_boot.txt` (invulnerable, player teleported to the far end before each exit: L R L R L R L R R L R L
R L -> bunker room 34) + `880 poke 12e04 1 2` (compass carried: hint 0 = GET GOING!, HUD compass follows $2a(a6)) + bunker
fight with Barnes shooting (man 0 killed there -> second chance -> restart). 1619 ticks: slots/vars/code vars identical;
16 room entries ($170f4, a6 globals) identical.
- FOUND/FIXED (timing): the picture decode window ($17604->$1764e, fade-out running) was 5-21 lines longer in the port
  (avg +12) than in the emu. Cause: the level-3 fade hook charged k_set_top_pal's cpu() cost a second time as main-program
  debt (in addition to s2FadeHookCycles). After the fix all 16 decode windows end within -6..+8 lines of the emu (avg +1),
  and the one-HUD-update difference after the second-chance restart (text countdown a6+$30 off by one for the rest of
  the game, because the decode ended just after instead of just before a vblank) is gone: a6 globals identical all ticks
  (except the timer sub-counter at the known pacing ticks).

### S9 rifle combat, path edges, DOWN, ammo; remaining object types — `/tmp/verify-section2/{combat,log11,rock0,mine5,wire78}.txt`
- combat (start room, no pokes): UP to depth 60, rifle fire every 4 frames 962-1800 (one shot per press; soldiers
  killed: +300 BCD score x2, GOOD SHOOTING!/THAT'S THE WAY TO DO IT!, dying countdown; bullets freed at depth $6e),
  RIGHT/LEFT against the path edges (clamp without exit), LEFT of $64 when T-junction soldiers spawn (they come from
  the right), DOWN to depth 0, ammo 144 -> 71, hits from soldiers/idle shots, second chance: 863 ticks identical.
- log type 11 (map $0a), rock type 0 (map $05), mine type 5 (map $02), wire types 7/8 (map $01): 416/401/401/287 ticks
  identical.

### Code coverage
Emulator `--pchist 17000 19020` merged over all scenario scripts above: every instruction the RE agents ever executed
(re/finaljungle/cov_all.hist + re/foxhole/foxhole_cov.hist, 1627 addresses) is executed by these scripts except 4
addresses that are not instruction starts (operand words). Since the port's tick dumps match the emulator in every one
of these runs, every executed path of the section-2 code is exercised in the port with identical RAM results.

### Sound
fox1 recorded with `--wav` in both tools (44.1 kHz): 50 Hz RMS envelopes correlate 0.998 (boot/intro, music), 0.968
(bunker fight: music 5 + grenade throw $0a, Barnes shot $82, hit/kill $81, miss $85) and 0.999 (win text, music 3 /
game over); sfx onsets at identical frames. (Absolute level differs by a constant mixing factor; the driver itself is
verified by the audio module.)

### S10 wrong turns / every room type (teleport, invulnerable) — `/tmp/verify-section2/tele_wrong.txt`
Route L L L L (104 114 115 -> back to the start room 105: the loop) then R L R L L R L L R R L R R L R L R L L R L
(106 96 97 87 86 76 75 85 84 74 73 63 64 54 55 45 46 36 35 25 -> bunker room 24): with the main route this visits every
room type 1..16 and all 10 pictures (type 4 room 96 / type 3 room 54 = picture 5, which contains ADF track 127: the port
shows the proper jungle picture, identical to the emulator). 2441 ticks identical, 26 room entries identical, 360/363
section screenshots (every 10 frames) pixel-identical (3 = TIME tick).
Note: in PACE mode this teleport script diverges (idle countdown one tick off at the first teleport): the pokes land at
frame starts, and in pace mode the port runs a whole tick at its head position while the emulator's tick spans the frame
boundary, so a mid-tick poke is seen by a different part of the tick. Pace mode is only used with input-only scripts.

### S11 entering section 2 from section 1 (kernel k_next_section) — `/tmp/verify-section2/s1to2.txt`
section1's `fl_help.txt` (title cheat, HELP in the tunnels -> flare -> HELP -> "LOADING... THE JUNGLE & FOXHOLE
SECTIONS") + FIRE 2700 (intro text) + walk + CAPS LOCK 2950 (MEGA CHEAT from the title cheat) + FIRE 3150. Section 2 code
from $17000 at f2573 in both; 225 section ticks identical (morale/score/compass carried over from section 1, men
re-initialised); game_won f2951 v18 in both; text left f3150 in both; then kernel GAME OVER/hiscore/title.

### S12 HONEST GAME: start room -> bunker -> Barnes -> win -> hiscore — `port/verify/section2/honest1.txt`
No pokes at all (boot script + joystick only). Generated closed-loop against the emulator (`/tmp/verify-section2/honest/`:
plan.py BFS over the exact pl_move rules avoiding static objects and predicted bullets/idle shots, drive.py replanning
at every deviation/new projectile; bunker policy: depth 20 at x 148..160, grenades as needed, sidestep Barnes' bullets,
then the door). Route L R L R L R L R R L R L R L (rooms 105 104 94 93 83 82 72 71 61 62 52 53 43 44 -> 34) with rifle fire
at soldiers (5 kills: score 1500), 3 hits taken (in 105 and twice in 82), 5 grenade hits on Barnes, the phantom '.'
auto-throws, sidestep, bunker door -> game_won f2285 v208 in both, "YOU MADE IT!" left f2500 in both -> GAME OVER ->
"ENTER YOUR NAME:" with 00001500 -> table -> title.
- Unpaced: the tick heads drift by a frame at tick 317 (kernel TIME redraw / audio sfx cost), after which the frame-exact
  joystick script hits different ticks (expected: the input changes every frame).
- Paced (`PACE=1`, S2PACE tick heads + S2PACEPL obj_player calls held to the emulator's beam positions; the port can only
  be delayed): ALL 1112 main-loop ticks identical in every dumped region ($57e22+$270, a6 $12dde+$78, $18f1c+$fc, $17226,
  $189d8), 15 room entries identical; screenshots every 4 frames: 933/975 identical; the 42 differing = kernel title
  credits (enhancement originalCredits default), f2288 (kernel k_clear_screens transient after the win), f2660 and the
  name-entry/title frames 3444-3480 (kernel).
