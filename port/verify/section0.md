# section0 verification (jungle + village) — evidence log

Method: lockstep of `tools/amiga/emu --deterministic` (full boot: title, fire, `poke 12e4c 0` = section 0, fire)
against `platoon-headless --start-section 0 --deterministic`, same inputs (emu frames shifted by OFF = 114 = emu
first main-loop tick 813 - port first tick 699). Harness: `/tmp/verify-section0/h.py NAME FRAMES [--shots K]`
(scenario files `/tmp/verify-section0/sc/NAME.txt`, emulator absolute frames; outputs in `/tmp/verify-section0/run/NAME/`).
Per scenario it compares
- tickdumps at the main-loop head $17186 of $5f880+$1c (player/enemy), $60c24+$a0 (all section variables incl.
  objects, bullets, bridge, torch, hut state), $12dde+$78 (a6 globals: men, morale, score, items, message queue),
  $1aaf4+$56 (door + search item table, patched by booby traps), $1b200+$10 (bridge map tiles);
- tickdumps of $12dde+$78 at the wait loops $19772 (choose-your-man input), $17dae (trap-door prompt), $1986c
  (wait-fire of the bridge game over) — the port calls `tickPoint()` with these original addresses;
- tick frame numbers (frame pacing), the Paula register stream of the music driver (emu `--reglog`, pc in
  $2800-$40ff, vs port `--reglog`), and screenshots every K frames (PIL difference).
Routes are planned on the emulator with `/tmp/verify-section0/plan.py` (incremental, save states).

## Results

Scripts are post-processed by `/tmp/verify-section0/dejitter.py` (moves each input event by <= 3 frames to the frame
start farthest from the neighbouring joystick samples = entries of r_joy_read $410 (the read happens right at entry; in
the jungle it is at v312 or v10-v25, i.e. at the frame boundary), and checks the emulator tickdumps are unchanged):
the port's CPU-time model is accurate to a few raster lines, so an input that changes 1-2 lines before/after a read
would otherwise be seen one tick apart (a real divergence of the input sampling, not of game logic; see "Remaining").

### S1 walk (sc/walk.txt, 2100 f): start, walk right, down-path col 13 to level 2, walk, auto-fire, walk left
- all tickdumps identical for 644 ticks; 26/26 screenshots identical.

### S2 deaths + choose your man + platoon wiped out (sc/deaths.txt -> deaths_dj, 4300 f, no invincibility)
Route: idle until shot (honest death by enemy bullet) -> CHOOSE YOUR MAN, FIRE keeps man 1; Left-Alt (voluntary change,
no enemy on screen) -> DOWN -> man 2; death -> DOWN DOWN UP -> man 3; poke man 1 hits=3, Left-Alt, UP x3 -> man 1;
death -> man 1 KILLED IN ACTION -> auto first living man; poke men 3-5 KIA / man 5 hits 3 -> death -> only man 5
left (DOWN/UP skip the dead); last death -> whole platoon dead -> sec0_exit -> kernel game over (+ title).
- main loop 302 ticks, choose-screen loop ($19772) 93 ticks: all RAM regions identical; tick frames 0 mismatches.
- kernel k_game_over ($fee8) entered at the same frame (2635) with identical a6 globals.
- screenshots: 140, 50 differ: dissolve steps 3-8 (see Remaining R1) and, after the game over, the title credits
  (kernel enhancement originalCredits, default on; the harness now runs the port with PLATOON_ENH=originalCredits=0).

### S3 honest jungle route, part 1 (sc/jungle_route_part1.txt -> _dj, 7700 f; invincibility poke only)
Planned on the emulator (`route_jungle.py`): L1 start -> col 13 down -> L2 col 19 down -> L3 col 26 down -> L4 col 31 up
-> L3 col 30 up -> L2 col 33 down -> L3 col 34 down -> L4 col 46 up -> L3 col 48 down -> L4: EXPLOSIVES box appears at
the right edge (col $31, c34=2) and is picked up ("YOU HAVE FOUND SOME EXPLOSIVES", HUD icon, +500) -> back L4 48 up,
L3 46 down, L4 34 up, L3 33 up, L2 30 down, L3 31 down, L4 6 up, L3 4 up, L2 3 up, L1 4 up -> L0 (west jungle) 17 down ->
L1 21 up -> L0 33 down -> L1 37 up -> L0 40 down -> L1 51 down -> L2 52 down -> L3 55 down -> L4 65 up -> L3 68 down ->
L4 75 up -> L3 73 up (all levels 0-4, 36 path changes up and down).
Content seen (coverage over the tickdumps): enemy states 0,1 (tree sniper drop, frame $1e),2 (soldier walk),5 (spider
hole $2b-$2e),6 (kneel & fire),7 (jump over trap); booby traps armed+exploding (trap state 1,2; with invincibility
hits := 3 like the original); explosives box object.
- 3443 ticks: all five RAM regions identical every tick; 138/138 screenshots identical; driver register stream
  45452 writes, identical values, 4 writes land one frame apart (sfx at a frame boundary, see Remaining R2);
  tick frames: 6 of 3443 ticks start one frame apart (and re-synchronise the next tick).

### S4 honest full jungle route to the village (sc/jungle_route3.txt -> _dj, 9000 f)
S3 continued (`route_jungle2.py`, `route_jungle3.py`): L2 col 68 up -> L1 river stretch: "SET THE EXPLOSIVES ON THE
BRIDGE" (msg $11, cols $45-$4a), plant at col $48 (state 10: kneel 5 ticks, forced walk right, bomb object bob $33,
HUD icon off), bridge blows at col $4e (map tiles $1b209/$1b20a := $95/$96, knock-back state 8 frames $31-$33 without
damage, +10000), walk back left to the gap: "PLEASE DON'T ATTEMPT SUICIDE!!" (msg $18) at $60c30 = $246, then right to
col $54 and up into the village street (level 0, east end).
Note (original quirk, reproduced): with invincibility on, bridge_blow's player_hit returns early, so the player
stays in state 10 (forced walk right) for ever — the route switches invincibility off for the blast.
- 4089 ticks: all RAM regions identical every tick; 164/164 screenshots identical; driver register stream 54191
  writes identical in value (4 one frame apart, R2); tick frames: 2 of 4089 ticks one frame apart.

### S5 "YOU DID'NT BLOW UP THE BRIDGE" (sc/doom.txt -> _dj, 2300 f)
MEGA CHEAT poked on, F3 warp (level 1, x $41, before the bridge, cheat off again), walk right without explosives:
col $4e -> state 9 (frozen), bridge runner (enemy state 8, frames $15.., kneels at x $21, frame $34, fires 3 shots
through the player bullet slots, bobs $30-$32, sfx $0a), hit -> all_dead: man hits := 4, KILLED IN ACTION, dissolve,
music 3, HUD palette, the two-line text, wait for fire (loop $1986c), game over ($fee8).
- 204 main-loop ticks + 30 wait-fire ticks identical; k_game_over entered in the same frame (1440) with identical
  a6; tick frames 0 mismatches; screenshots: 3 differ during dissolves, the rest after the game over are the title
  credits enhancement (see S2).

Port input alignment (`/tmp/verify-section0/retime.py`): where the port's frame pacing is one frame off for a stretch
(see R3), an input given at the same frame would be sampled by a different read_input in the two tools. retime.py
writes a port script (sc/NAME.port.txt) in which every joystick event reaches the port's read_input with the same
index as in the emulator (reads: emu PC $19f3a, port trace 019f3e) and every key event is delivered (line 100) between
the same key tests (emu $171aa/$17de4, port traces); h.py uses it when present. This isolates game-logic equivalence
from the pacing residual, which is reported separately (tick frame mismatches).

### S6 village tour, every hut and search result (sc/village_route.txt -> _dj + .port, 5800 f)
F4 warp (cheat) to the street, then (`route_village.py`): hut 3 (door $42): $212/$210 rice, $20e flour, $20c rubbish;
hut 2 ($3c): the VC guard (enemy state 4, frame $34) is shot (+300, dying state 3, body frame $33, $60c70 := 1), $1e8
stool, $1ec/$1ee map (YOU HAVE FOUND A MAP, HUD icon, +500, morale +$200; second search "A TABLE."); hut 1 ($37):
$1ba stool, $1b6 rice, $1b4 rubbish, $1c0 empty, trap-door prompt (msg $b, prop bob $3b) answered N (wait for the
queue, turn and step away), again answered Y without torch ("YOU NEED TO FIND A TORCH"); hut 0 ($31): $190 booby
trap (explosion at the player, hits := 3 with invincibility, search entry patched to "A SACK OF FLOUR" — second search
there), $194 torch (+500, morale +$200) and again ("A POT OF RICE."); hut 4 ($49): $248 stool, $246/$244/$242 table,
$240 nothing, $23e booby trap then "A POT OF WATER", $23c provisions; hut 5 ($4d): $270 flour, $272 stool, $274
nothing, $276 stool; back to hut 1 with the torch: Y -> bonus 1000/man, dissolve, k_next_section -> section 1 entry.
Villagers walk the street (frames $23-$2a). Messages seen: 1-9, $a, $b, $d, $f, $16. States 4/5/6 (enter/in/leave hut).
- 2018 main-loop ticks, 58 trap-door prompt ticks ($17dae), k_next_section ($11076) and section entry ($17000):
  a6 / section RAM identical at every record (item table $1aafa patches included). 
- Section 1 entered with identical a6 (map flag, score, men, morale) = the carry-over.
- tick frames: a stretch of 636 ticks runs one frame early in the port (R3); screenshots 200: 4 differ during dissolves,
  29 others (all in that stretch: same content one frame apart).

### S7 honest complete section: boot -> jungle -> explosives -> bridge -> village -> trap door -> section 1 (sc/honest_village.txt -> _dj + .port, 13700 f)
S4's route continued (`route_honest_village.py`, invincibility poke only): arriving at the east end of the street
(bridge blown, so supply crates can drop), sweep left/right through the street firing at soldiers and villagers in
front (villager killed: "YOU SHOULDN'T SHOOT INNOCENT VILLAGERS", morale -$1200, no score; soldiers +300; a killed
soldier dropped a crate that was walked over: "MEDICAL SUPPLIES"), hut 2 guard shot + map, hut 0 torch, hut 1 trap
door Y (+1000 per living man) -> dissolve -> k_next_section -> "THE TUNNEL SYSTEM" -> fire -> section 1.
- 5884 main-loop ticks, 21 trap-door prompt ticks, k_next_section and section-1 entry: all RAM regions / a6 identical.
- 258 screenshots: 257 identical, 1 differs during a dissolve (R1).
- tick frames: 9 of 5884 ticks one frame apart; driver register stream 83824 writes: 14 small value-sequence
  reorderings (the ch3 volume write around an sfx end) and 54 writes one frame apart (R2).
Coverage over this run: player states 0,2,3,4,5,6,8,10; enemy states 0-7; enemy frames incl. villagers $23-$2a,
spider hole $2b-$2e, guard $34/$33; traps, bomb, crate objects; bridge 0/1/2; levels 0-5; messages 2,8,$c,$10,$11,$17,$18.

### S8 more deaths (sc/deaths2.txt -> _dj + .port, 4300 f; no invincibility where it matters)
(`route_deaths2.py`) 1. level 2, walk right until hit: a TRIPWIRE (booby trap, trap state 1 -> 2, explosion, sfx
$85) kills man 1 (hits := 3 then +1 = KILLED IN ACTION) -> choose screen starts at the first living man -> FIRE.
2. F4 to the village, hut 0, search $190 without invincibility: VIET CONG BOOBY TRAP kills man 2 inside the hut
(state 8 at y $3d, KIA) -> choose screen -> back in the hut in state 5 (level 5 kept) -> search again: "A SACK OF
FLOUR." (patched entry). 3. hut 2 without shooting: the guard fires after 15 ticks (enemy bullet y $45, dx -20) ->
man 3 hit -> choose -> back in hut 2 (guard re-created with a fresh timer). 4. morale poked to $30: the main loop's
morale countdown reaches 0 -> sec0_exit -> k_game_over.
- 872 main-loop ticks, 15 choose-screen ticks, k_game_over entry (same frame 3131, identical a6): identical.
- tick frames 1 mismatch; screenshots 140: 12 differ, all during dissolves (R1).
