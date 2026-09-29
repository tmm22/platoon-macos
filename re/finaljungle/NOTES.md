# Platoon (Amiga) — Section 2 engine: the FINAL JUNGLE and the BUNKER ("foxhole") room  (module `finaljungle`)

Scope: everything executed from the section-2 code block ($17000-$18865) and its data ($18866-$58fff):
the intro text, the 2-minute timer, the pseudo-3D "path into the screen" room engine (10x12 room
maze, compass, left/right exits), soldiers, snipers ("idle shots"), mines and barbed wire, player
shooting, death / "one more chance" / game over, the napalm time-out, and the last room (bunker) where
Barnes has to be killed with grenades before the player can enter the bunker ("YOU MADE IT!").
There is NO separate foxhole engine: the "foxhole" of the section name ("THE JUNGLE & FOXHOLE
SECTIONS") is room type 16 of this same engine (picture 10, Barnes in his foxhole in front of the
bunker). Winning ends the game (kernel game over + hiscore); there is no further section.
Kernel routines ($f800-$12dde) are described at interface level only (see re/kernel/labels.txt).

All numbers hex unless obviously decimal. **[verified]** = checked in the emulator.

Files in this directory
- `NOTES.md` — this spec.
- `labels.txt`, `comments.txt`, `gen_listing.py` → `finaljungle.s` (annotated rdis listing of $17000-$1901f).
- `extract.py` — pulls every asset from the ADF into `assets/` (see §d). `python3 extract.py`
  (`--darc-only` to reproduce the corrupt picture 5 of the Darc image, see §d.2).
- `cov_all.hist` — merged executed-PC histogram of all my test runs (1349 of 1457 reachable
  instructions executed; the rest = 2 dead routines, 2 unused object types, a few rare branches).
- `work/` — scratch (scripts, screenshots, sheets).
- `assets/` — pic01..10.png, pic05_darc_corrupt.png, rooms/room_00..16.png, bobs.png/json, map.png,
  map.json, maze_graph.json, palettes.png/json, messages.json, tables.json.

---------------------------------------------------------------------------------------------------
## (a) Scope and how to reach it in the emulator

Section 2 = disk tracks 111..158 (48 tracks, $42000 bytes) loaded **uncompressed 1:1** to
$17000-$58fff: RAM address A <-> ADF offset A + $81a00. Kernel `k_section_start` ($fcc8) jumps to $17000
after "ENTERING THE COMBAT ZONE". At run time only the variable area ($57b00-$5808f, $58190..) and a few
self-modified bytes ($17226, $172aa-$172af, $189dc-$189df, HUD colours 8/9 at $176ce written by the
kernel message system) differ from the disk.

**Darc image defect**: track 127 (RAM $2d000-$2e5ff) is corrupt in `platoon_darc.adf` (and in the
Beyonders crack). It lies inside background picture 5 (right-turn rooms of types 3 and 4), which is
displayed as colour noise in the emulator too **[verified]** (`assets/pic05_darc_corrupt.png`,
`work/p5/pic5.png`). `platoon_b.adf` (original dump) has a good track 127: with it picture 5 decodes to
exactly the bytes up to the start of picture 6 ($301a2) and shows a proper jungle scene. The port
should take track 127 from platoon_b.adf (extract.py does).

States (all in `re/states/`, made by me):
| state | what |
|---|---|
| `finaljungle_entry.state` | pc = $17000 (section entry, before the intro text). Poke the map here to start in another room type (e.g. `1 poke 18f0d 3 1` = start room becomes type 3). |
| `finaljungle_start.state` | first main-loop iteration ($17118) of room $69, timer 02:00, nothing spawned yet, man 0 |
| `finaljungle_bunker.state` | the bunker room (room 34, type 16) just after its setup ($170f4), timer ~01:29, Barnes alive, 9 grenades |
| `section2_play.state` (shared) | frame 1000; the player is already being hit in it — prefer finaljungle_start |

Boot script (absolute frames, events sorted by frame):
```
300 fire 1
305 fire 0
350 poke 12e4c 2 2
600 fire 1
605 fire 0
700 breaksave 17000 ../../states/finaljungle_entry.state       # or: 900 fire 1 / 905 fire 0 /
                                                               #     906 breaksave 17118 .../finaljungle_start.state
```
Useful pokes (relative to finaljungle_start.state):
- `1 poke 17d68 4e75 2` — invulnerability (player_hit becomes rts; all callers tolerate it) **[verified]**.
- `1 poke 12e4a 0003 2` — timer 00:03 (napalm soon) **[verified]**; `1 poke 12e0c 0001 2` — morale 1.
- `1 poke 12e4f 02 1` + `10 key 0x62 1` — MEGA CHEAT flag + CAPS LOCK = instant win **[verified]**
  (note: emulator `key` codes are parsed with %i: use 0x prefix).
- `1 poke 57f42 0 1` — no more soldiers in the current room.
- Route to the bunker from the start, with invulnerability (each step: put the player at the far end, then
  walk sideways): `work/route2.txt` = for each letter of `LRLRLRLRRLRLRL`:
  `F poke 57e26 5f 2 / F poke 57e24 a0 2 / F+1 left|right 1 / F+40 left|right 0`, F += 110 **[verified]**
  (rooms 104 94 93 83 82 72 71 61 62 52 53 43 44 34).
- Bunker walkthrough (`work/bunk.txt`, from finaljungle_bunker.state): up for 10 frames (depth $14),
  then 5 fire presses 30 frames apart (5 direct hits → "GET TO THE BUNKER - NOW!"), then hold up →
  "YOU MADE IT!" **[verified]**.

---------------------------------------------------------------------------------------------------
## (b) Code map

Conventions: a6 = $12dde (kernel globals). a5 = pointer to the current man (6-byte record at a6+6*i:
+0 grenades, +2 rifle ammo, +4 hits). a3 = current object slot inside handlers. `rand()` = kernel $f850
(d0 = 0..255, other bits of d0 as documented in kernel). `sfx(n)` = $18860 = `jmp $f86c` (d0=n).
`msg(n)` = kernel $f82c (queue message n of table $4a(a6) = $189e0; ignored if 4 queued).
"tick" = one main-loop iteration (normally one 50 Hz frame, §e).
Comparisons: `s<` signed (blt/bgt/ble/bge), `u<` unsigned (bcs/bcc).

### b.1 Object slots (the core data structure) — 16 slots of $12 bytes at $57e22 (slot n at $57e22+n*$12)
| off | size | meaning |
|---|---|---|
| +0 | b | active: 0 = free. $ff = normal. Soldier: 1..4 = dying countdown. Barnes: health ($32, -$a per hit) |
| +1 | b | anim counter; the draw loop stores it back `&7`; displayed frame = frame + (anim>>1) |
| +2 | w | x (screen pixels, left edge of the bob; no clipping) |
| +4 | w | y = DEPTH (0 = nearest to camera; the far end of the path is ~$5f; Barnes $69) |
| +6 | l | bob directory address (8-byte entries, §d.3) |
| +a | l | handler (called with a3 = slot, a5 = man); may clear +0 |
| +e | w | dx (bullets/soldiers), step counter (grenade); player dying: +e byte = end frame, +f byte = tick counter |
| +10 | b | frame (index into the directory, before adding anim>>1) |
| +11 | b | unused (only copied/cleared as part of word +10) |

Slot usage: 0 player; 1-3 player bullets; 4-6 soldiers (Barnes = slot 4 in the bunker room);
7-9 enemy bullets; 4-8 may be borrowed by the idle shot; 10-15 static room objects (rocks, logs,
mines, barbed wire) / grenades (10-12, bunker room only) / explosions (a mine or grenade slot is
converted in place).

Slot init table `d_slot_init` $18df0 (46 longs = slots 0..9 + 4 bytes, copied on every room entry):
- slot 0: `ff 00 | x 00a0 | y 0000 | gfx 00047400 | h 000179fa | 0000 | 00 00` (player, frame 0)
- slots 1-3: inactive, gfx $476a0 (bullet), handler $17c1e (obj_pbullet), +e = 0, frame 0
- slots 4-6: inactive, x $32/$64/$96, y $5f, gfx $475d8 (soldier), handler $17cc6, +e = 8 (only gfx matters)
- slots 7-9: inactive, gfx $476b0 (enemy bullet), handler $17cfc (obj_ebullet)
- slot 10: first 4 bytes = 0 (the table overlaps the map). Slots 10-15 otherwise zero (area cleared).

### b.2 Entry and (re)start — `fj_entry` $17000, `fj_restart` $17068
```
fj_entry:
  kernel $f860 (display init)
  $57b00[i] = i*40 (long), i = 0..199          ; row table used by draw_bob
  $4a(a6) = $189e0 (message table)
  kernel $f840 (clear $70000-$7ffff)
  text_screen(a0 = $18c6d intro)               ; "!THE JUNGLE! YOU HAVE TWO MINUTES BEFORE THE AIRSTRIKE. FIND THE BUNKER! PRESS FIRE WHEN READY"
  game_screen_init()                           ; music 5, clear, game palette
  $1e(a6) = a6 ; $22(a6) = 0
  for i in 0..4: man[i] = {grenades 9, ammo $90, hits 0}     ; carried-over men are re-initialised
  a5 = a6 (man 0)
fj_restart:                                    ; also after "YOU HAVE ONE MORE CHANCE" with a5 = man 1
  $1e(a6) = a5
  a0 = trans_start ($1816c)
  $6a(a6) = $32 ; $6c(a6) = $0200             ; timer 2:00 (BCD mm:ss), see §e
  $189dc.l = $189d8.l (= 00 01 06 07)
  $189dc.b = ($26(a6) != 0) ? 0 : $b           ; no compass carried -> hint "A COMPASS WOULD HELP !"
  kernel $f830 (full HUD redraw)
room_enter ($170a8):                           ; a0 = transition routine
  SP = $400 ; push a0
  clear longs $57e20..$58f9f ($460 longs)      ; slots, vars, sort buckets, blit buffer
  copy 46 longs $18df0 -> $57e22
  bytes $57f90..$5808f = $ff                   ; empty depth buckets
  $54(a6) = 0 (byte)
  d0 = 1 ; jsr (a0)                            ; transition + room setup + picture + objects (§b.10)
room_enter_done ($170f4):
  $57f5c = $64 ; $57f58 = $14 ; $57f5a = $14 ; $57f64 = $80
  st.b $68(a6)                                 ; timer runs
```

### b.3 Main loop — `main_loop` $17118
```
loop:
  kernel $f834 (HUD update: score, message text, compass, bars, TIME)
  if ($71(a6) & 2) and key($62 CAPS LOCK): goto game_won          ; MEGA CHEAT instant win
  idle_shot_tick()       ; $17342
  soldier_spawn_tick()   ; $17498
  hint_tick()            ; $17228
  kernel $f85c (wait until the previous swap request was served)
  if $2e(a6) (morale) == 0: goto morale_zero                        ; $17f04
  bg_restore()           ; $17558
  objects_update_draw()  ; $1773e
  kernel $f84c (swap)
  t = $6c(a6)
  if t == ($17226).w: continue
  ($17226).w = t
  if byte $6c(a6) (minutes) == 0: $189dd = 5     ; hint 1 becomes "NOT LONG BEFORE THE NAPALM"
  if t != 0: continue
time_up ($1718a):
  sfx($81) ; sfx_and_reset (also sets $57f64=$80)
  pal_copy_current()     ; $57f70 = palette at $5a(a6), set
  repeat: for each of 16 colours: each of R,G,B nibble +1 if it is not already $f (changed -> d2=$ff)
          set top palette $57f70 ; wait 4 vblanks
  until nothing changed                          ; flash to white, <= 15 steps x 4 frames
  fade_out_wait() ; kernel $f840
  text_screen_music3(a0=$18bb8)  "YOU DIDN'T MAKE IT! YOUR PLATOON HAS BEEN DESTROYED, BY A NAPALM STRIKE !"
  jmp kernel $f864 (game over)
```
Note: the kernel timer keeps running during the flash ($68(a6) stays set), so the HUD briefly shows
59:59 (BCD wrap) **[verified]** — cosmetic.

### b.4 Hints — `hint_tick` $17228
```
$57f56 -= 1 ; if $57f56 s>= 0: return
$57f56 = (rand() & $7f) + $64
msg( $189dc[rand() & 3] )     ; [0] = $b (no compass) or 0 "GET GOING!", [1] = 1 "KEEP MOVING!" (5 when <1 min),
                              ; [2] = 6 "GO GET 'EM", [3] = 7 "STAY ALERT"
```
$57f56 is 0 after every room entry, so a hint is shown immediately in every new room **[verified]**.

### b.5 Fade-out in the vertical-blank interrupt — $1726a..$17330, $175e8
```
pal_copy_current ($1726a): copy 16 words from ($5a(a6)) to $57f70 ; kernel $f878(a0=$57f70)
fade_out_start ($1728a):  pal_copy_current ; $172aa.w = $ff00 (st.b) ; $172ac = ($6c).l ; ($6c).l = $172c2
l3hook_fade ($172c2, runs on every level-3 interrupt = vblank, before the kernel handler):
  if $172aa.w == 0: ($6c).l = $172ac ; jump to $172ac (original handler)
  movem d0-d4/a0 ; d1 = 0
  for each colour of $57f70: each nibble: if != 0: nibble -= 1, d1 = $ff
  $172aa.w = d1 ; kernel $f878(a0=$57f70) ; restore ; jump to the original handler ($10eac)
fade_out_wait ($175e8): fade_out_start ; do { kernel $f848 (wait vbl) ; kernel $f834 (HUD) } while $172aa.w != 0
```
So a fade-out takes at most 15 vblanks + 1; the hook removes itself one vblank after the fade ends.

### b.6 Text screens — $176de / $176ea / $1771e
```
text_screen_music3 ($176de): kernel $f868(d0=3) ; fall into text_screen
text_screen ($176ea, a0 = string):  kernel $f840 (clear both buffers) ; kernel $f878(a0=$18fe2 text palette)
     res_print(a0) ($408) ; kernel $f844(d0=$31) (= 50 vblanks) ; wait until joystick fire pressed ($410 bit7)
     (no wait for release: holding fire skips the screen after 1 s)
game_screen_init ($1771e): kernel $f868(d0=5) (in-game tune) ; kernel $f840 ; kernel $f878(a0=$18fc2)
clear_play_and_pal ($17676): clear rows 0..143 of the 4 planes of $70000 and $78000 ($1680 bytes each)
     kernel $f878(a0=$18fc2) ; kernel $f87c(a0=$176be HUD palette)
```

### b.7 Rendering — `bg_restore` $17558, `objects_update_draw` $1773e, `draw_bob` $17850 (see §f)

objects_update_draw:
```
for slot = 15 downto 0:                        ; a3 = $57e22 + slot*$12, d7 = slot
  if active(a3):
    call handler(a3)                           ; d7/a3 preserved
    if active(a3):
      k = y(a3)
      if slot != 0 and (slot < 4 or 7 <= slot < 10): k -= $14      ; bullets are sorted $14 nearer
      k &= $ff
      while bucket[$57f90 + k] != $ff (i.e. >= 0): k += 1          ; linear probe, NO upper bound
      bucket[k] = slot
objects_draw ($177a6):
for a0 = $5808f downto $57f90:                 ; far (high depth) first = painter's algorithm
  if (a0).b is negative: continue
  slot = (a0).b ; (a0).b = $ff
  d0 = x<<16 | ((($8f - y - dir[0].rows_m1) ))     ; dir = +6(a3); screen top row; only entry 0's height is used
  anim(a3) &= 7
  e = (anim >> 1) + frame(a3)
  a1 = $47700 + dir[e].ofs                      ; bob data (header + mask + 4 planes)
  draw_bob(a1, d0)
```
Quirk: a probe that runs past $5808f is written into $58090.. and never drawn (not reachable in practice).
The order of handler execution (slot 15 first) matters: static objects/grenades, then enemy bullets,
soldiers, player bullets, and the player last.

### b.8 Player — `obj_player` $179fa (slot 0)
```
$57f46.l = (x,y) ; $19014 = $19012             ; saved for blocking objects
if $57f44 == 0 (bunker room):
    bunker_goal_check()                          ; $17be2: if Barnes ($57e6a) == 0 and $9e s< x s<= $ae and y s>= $5f: game_won
    if key($39 '.'): if !$57f53: $57f53 = $ff ; throw_grenade()   else: $57f53 = 0
j = joystick()
if !(j & $80): $57f52 = 0                         ; fire released
elif $57f44 == 0: if !$57f52: $57f52 = $ff ; throw_grenade()     ; fire = grenade in the bunker room
elif man.ammo != 0: $57f4a = $ff                 ; request a rifle shot (latched in pl_shoot)
j = joystick() ; d1 = 2 ; d3 = 0 (anim step) ; d4 = 0 (vertical)
if (j & $f) == 0: frame = 4 - (anim >> 1)         ; displayed frame = 4 (standing)
if j & 1 (DOWN): d4 = 1 ; d3 = 1 ; $19012 += 1 ; y -= 2 ; if y s< 0: $19012 -= 1 ; y = 0
if j & 4 (UP):   d4 = 1 ; d3 = $ff ; y += 2 ; $19012 -= 1 ; if y s>= $60: $19012 += 1 ; y = $5f
d1 = 4 ; d6 = (y s>= $5a) ? $57f44 : 0           ; exits usable only at the far end
if j & 8 (LEFT):  frame = 9 ; d3 = 1 ; x -= 4
if j & 2 (RIGHT): frame = 0 ; d3 = 1 ; x += 4
if $57f4a: pl_shoot() ; $57f4a = 0
if d4: frame = $11
lo = $64 - $19012 ; hi = $be + $19012
if lo s> x: if d6 & 1: goto exit_left (room change) else x = lo
if hi s< x: if d6 & 2: goto exit_right          else x = hi
anim += d3 (byte)
if y s> $1e: frame += $15 ; if y s> $3c and frame s< $26: frame += $15
```
Frames (directory $47400, 3 size sets of $15): +0..3 walk right, +4 stand, +5..8 die (right), +9..12
walk left, +13..16 die (left), +17..20 walk away (back view). Near set 0-20 (depth <= $1e), medium 21-41
(<= $3c), far 42-58 (only horizontal/stand/death frames exist; vertical walking keeps medium frames
38..41 because of the `< $26` test). The x speed is 4 px/tick, depth speed 2/tick; the path width
$19012 is $32 at depth 0 and shrinks by 1 per depth step of 2 (so at depth $5f the player is confined to
x in [$61..$c1]). Entering a room always places the player at x=$a0, depth 0.

`pl_shoot` $1811c: `if $57f52: return ; $57f52 = $ff ; slot = first of 1..3 with WORD +0 == 0 (active and
anim both 0) else return ; man.ammo -= 1 ; active=$ff ; x = px+8 ; y = py+$28 ; sfx($82)`.
Player bullet `obj_pbullet` $17c1e: `y += 8 ; if y s>= $6e: free`. Bullets therefore only live 1-3 ticks
at the far end; they can only hit soldiers (§b.11). Rifle: one shot per fire press, ammo $90 per man.

`throw_grenade` $182de: slot = first free of 10..12 else return ; if man.grenades == 0 return ;
grenades -= 1 ; +0.w = $ff00 ; x = px + $a ; y = py + $1e ; handler $1833a ; gfx $476a8 ; frame 0 ;
+e = 0 ; sfx($a).

### b.9 Death, respawn, men — `player_hit` $17d68, $17e30, $17e5e
```
player_hit:  (callers: bullet_hits_player, mines, barbed wire)
  anim(player) = 0 ; handler(player) = $17e30
  f = frame(player)
  start = f <= 4 ? 5 : f <= $14 ? $d : f <= $19 ? $1a : f <= $29 ? $22 : f <= $2e ? $2f : $37   (signed byte compares)
  frame = start ; +e byte ($57e30) = start + 3 ; +f byte ($57e31) = 0
  $57f54 = $ff (dying) ; $57f5c = $64
  man.hits += 1
  msg(man.hits u< 4 ? $a "YOU'RE HIT" : 9 "KILLED IN ACTION")
  kernel $f818 (HUD wound marks)
  morale $2e(a6) -= $800, clamp at 0
  play_hit_sfx: sfx($57f64) ; $57f64 = $80        ; $80 normally, $81 when a mine did it
obj_player_dying ($17e30): +f = (+f + 1) & 3 ; if 0: frame += 1 ; if frame == +e: handler = $17e5e
obj_player_dead_wait ($17e5e): +f = (+f + 1) & 7 ; if != 0 return
  $19012 = $32 ; handler = obj_player ; $57f54 = 0
  if man.hits u>= 4:
     if $22(a6) != 0: goto all_dead
     $22(a6) = 1 ; a5 = a6+6 ; $1e(a6) = a5 ; kernel $f818 ; fade_out_wait ; clear_play_and_pal
     text_screen_music3($18d2c)  "YOU DIDN'T MAKE IT ! ONE OF YOUR PLATOON MEMBERS FOLLOWED YOU TO THE EDGE
                                  OF THE JUNGLE  YOU HAVE ONE MORE CHANCE  TAKE CONTROL OF YOUR MAN  PRESS FIRE TO CONTINUE"
     game_screen_init ; goto fj_restart           ; timer back to 2:00, back to the start room
  else (pd_respawn): if $57f44 == 0: free slots 7-9 else free slots 1-9 ; y = 0 ; x = $a0
all_dead ($17f18) / morale_zero ($17f04):
  fade_out_wait ; kernel $f840 ; text_screen_music3($18ce7 "YOUR PLATOON HAS BEEN DESTROYED! PRESS FIRE TO CONTINUE.")
  jmp kernel $f864 (game over)
```
Death animation: 3 frame steps x 4 ticks + 8 ticks hold = 20 ticks. BUG (faithful): morale_zero loads
a0 = $18c14 ("YOUR PLATOON HAS WITHDRAWN FROM ACTION") and then branches to $17f22 which overwrites a0
with $18ce7, so the withdrawn text is never shown **[verified]**. Only 2 of the 5 men are ever used;
4 hits kill a man; morale -$800 per hit, and morale 0 ends the game at the next tick.

### b.10 Room transitions and setup — $1816c..$182ac, $17604, $1841a
Exits: `exit_right` $1817e: `a0 = $18192 ; goto room_enter`; `exit_left` $18188: `a0 = $181b4`.
```
trans_start ($1816c):  d1 = $18f44.l ($010afff6) ; d0 = $69 ; $2a(a6) = 0 ; goto room_setup
trans_right ($18192):  $2a(a6) = ($2a(a6)+1) & 3 ; d0 = $18f1c + (byte)$18f40[0] ; d1 = $18f40 rol.l 8
trans_left  ($181b4):  $2a(a6) = ($2a(a6)-1) & 3 ; d0 = $18f1c + (byte)$18f40[2] ; d1 = $18f40 ror.l 8
room_setup ($181d2):
  $18f40.l = d1 ; $18f1c = d0 (byte arithmetic)
  clr.w $68.l                ; absolute $68 (level-2 vector high word, already 0): harmless bug, timer NOT stopped
  t = $18ea4[d0 & $ff] ; $57f45 = t ; $57f44 = $18f2e[t] ; pic = $18f1d[t]
  r = rand() & 7 ; if r > 5: r -= 3 ; $57f42 = r   ; soldiers of this room: 0..5 (P: 0,1,2,5 = 1/8, 3,4 = 2/8)
  $19012 = $32
  if $57f44 != 0:
     e = $57f44 ; $19016 = $18f48[e-1] ; $19010 = $18f52[e-1] ; $1900e = $18f4c[e-1] ; $1900a = $18f58[e-1]
  else (bunker): slot 4 = {active $32, x $96, y $69, gfx $47628, handler $182b0, +e..+11 = 0}
  goto room_load_picture(pic)
room_load_picture ($17604, d0 = 1..10):
  fade_out_start
  RLE-decode picture d0 into $68000/$6a000/$6c000/$6e000 (§d.2)
  wait for the fade to end ; clear_play_and_pal ; room_spawn_objects ; rts (to room_enter_done)
room_spawn_objects ($1841a): list = $18866[t] ; a1 = slot 10
  while (w = list.w) >= 0: active=$ff ; gfx = $188aa[w] ; handler = $188da[w] ; (x,y) = next long ; a1 += $12
```
The direction long `$18f40` holds 4 signed room-index offsets [R, B, L, F] for the current heading
(start: R=+1, B=+10, L=-1, F=-10, i.e. "north" = up in the 10-wide map). Right exit: move by R, then
rol 8 → the new R is the old B (consistent clockwise rotation). Left exit: move by L, ror 8. The compass
$2a(a6) (0..3, displayed by kernel $f834 if the compass item $26(a6) is carried) follows. The room type
does NOT depend on the heading. The screen is black during a transition (fade-out, decode, instant
palette switch); the timer keeps counting.

### b.11 Soldiers — spawn $17498, handlers $17c32/$17c7c/$17cc6, hit test $1807a, fire $17f32
```
soldier_spawn_tick:
  if $57f54 or $57f44 == 0 or $57f42 == 0: return
  $57f58 -= 1 ; if s>= 0 return ; $57f58 = (rand() & $f) + $14
  if player y s> $40: return
  slot = first free of 4..6 else return
  $57f42 -= 1 ; active = $ff ; handler = $1900a ; frame = $19016 ; dx = $19010 ; y = $5b ; x = $1900e
  if x s< 0 (T-junction, $ffff): x = $5f ; frame = 0 ; dx = 5
       if player x s<= $64: x = $d2 ; frame = 5 ; dx = -5
exit tables (index exits-1):   exits=1 (left-turn rooms):  x $5f, dx +5, frame 0, handler $17c32
                               exits=2 (right-turn rooms): x $d2, dx -5, frame 5, handler $17c7c
                               exits=3 (T-junction):       x chosen as above, handler $17cc6
soldier handlers (common part):
  soldier_hit_check()      ; may return from the handler (dying / killed)
  soldier_fire()
  anim += 1 ; x += dx
  if x s< $5f or x s>= $d2:
     L ($17c32): x -= dx ; dx = -dx ; frame ^= 5 ; if frame == 0: free, $57f42 += 1   (walk in, back, leave)
     R ($17c7c): same, but leaves when the frame becomes 5 again (walk in, back, leave)
     T ($17cc6): free, $57f42 += 1                                                 (crosses once)
soldier_hit_check ($1807a):
  if active is 1..$7f (dying): active -= 1 ; return from handler (death frame shown 4 ticks in total)
  for b in slots 1..3: if active(b) and y(b) s>= $5f and x+2 s<= x(b)+$10 s<= x+$1e:
      active = 4 ; anim = 0 ; frame += 4 ; free b ; score += 300 (BCD $18ffe..$19001 via kernel $f80c)
      msg((rand() & 1) ? 3 "GOOD SHOOTING!" : 8 "THAT'S THE WAY TO DO IT!")
      play_hit_sfx() (sfx $80) ; return from handler
soldier_fire ($17f32):
  if $57f54: return ; if $57f5a != 0: $57f5a -= 1 ; return
  b = first free of slots 7..9 else return
  dy = y - py (word) ; dx = px - x
  if dy.b == 0: free(b) (no-op) ; return          ; only the LOW byte is tested
  dx = sign(dx) * ((|dx| * 4) divu dy)             ; quotient word; so the bullet reaches the player's x when it reaches his depth
  b.dx = dx ; b.(x,y) = (x,y) ; active(b) = $ff
  $57f5a = (rand() & $f) + $14 ; sfx($82)
obj_ebullet ($17cfc): bullet_hits_player() ; x += dx ; if x u>= $140: free ; y -= 4 ; if y s< 0: free
bullet_hits_player ($17d1e): if $57f54: return
  if px s<= bx s<= px+$18 and py+8 s<= by s<= py+$1c: free bullet ; player_hit (and do not return to the handler body)
```
Soldier frames: directory $475d8 (bob entries 59..68): 0-3 walk right, 4 dead, 5-8 walk left, 9 dead.
Killed soldiers are not returned to the pool. The fire cooldown $57f5a is shared by all soldiers.

### b.12 Idle shot ("sniper") — `idle_shot_tick` $17342, $17414, $1741e, $17458
Punishes standing at the same depth.
```
if $57f44 == 0 or $57f60 != 0 or $57f54 or player y u>= $40: return
if $57f5c != 0:
   if py != $57f5e: $57f5e = py ; $57f5c = $32 ; return      ; moved in depth: restart (50 ticks)
   $57f5c -= 1 ; if != 0 return
slot = first free of 4..8 else return
active = $ff ; $57f60 = slot ; save gfx/handler/word +10 in $57f66/$57f6a/$57f6e
gfx = $476c0 ; handler = $17414 ; anim = 0 ; frame = 0
if rand() & 2: x = $110, dx = -7  else x = $18, dx = +8
y = py + $14 ; sfx($82)
obj_idleshot_h0 ($17414): handler = $1741e                     ; one tick without moving
obj_idleshot_h1 ($1741e): bullet_hits_player (on hit -> idle_shot_end after player_hit)
   gfx = $476a0 ; anim = frame = 0 ; x += dx ; if x u< $10 or x u>= $12c: idle_shot_end
idle_shot_end ($17458): free slot, restore gfx/handler/word +10, $57f60 = 0, $57f5c = $64
```
First shot after 100 ticks without depth change, then every ~100+ ticks **[verified: spawn 99 frames
after the start state, hit 14 ticks later]**. Moving only sideways does not reset the countdown.

### b.13 Static room objects — handlers $1846c..$18804, explosion $186dc/$18706
All: player box = [px, px+$e] x [py, py+4] (+3 for types 4-8); object box = [x, x+W] x [y, y+D];
overlap iff `x+W s>= px and x s<= px+$e and y s<= py+4 and y+D s>= py`.
| type | gfx (bob) | handler | W x D | effect |
|---|---|---|---|---|
| 0 | $476c8 (89 rock) | $1857a | $14 x 7 | block (restore $57f46 pos and $19014 width) |
| 1 | $476d0 (90 rock) | $185d4 | $10 x 5 | block (type not used in any room) |
| 2 | $476d8 (91 rock) | $1862e | $a x 5 | block (type not used in any room) |
| 3 | $47658 (75 mine) | $18688 | $a x 4 | explode: object -> explosion, $57f64=$81, player_hit |
| 4 | $47660 (76 mine) | $18718 | 6 x 4 (+3) | same as 3 |
| 5 | $47668 (77 mine) | $18760 | 6 x 4 (+3) | same as 3 |
| 6 | $47670 (78 wire) | $187a8 | $32 x 6 (+3) | block + player_hit |
| 7 | $47678 (79 wire) | $18804 | $28 x 4 (+3) | block + player_hit |
| 8 | $47680 (80 wire) | $18804 | $28 x 4 (+3) | block + player_hit |
| 9 | $47688 (81 log) | $1846c | $46 x $a | block |
| 10 | $47690 (82 log) | $184c6 | $32 x 8 | block |
| 11 | $47698 (83 log) | $18520 | $28 x 6 | block |
Barbed wire only hurts while the player is not already dying (player_hit re-entry while dying is
possible in principle: the wire does not test $57f54). Mines disappear (explosion) after triggering.
`obj_to_explosion` $186dc: frame = 0 ; handler = $18706 ; gfx = $476e0 ; anim = 0 ; x -= $e ; y += 4.
`obj_explosion` $18706: frame += 1 ; if frame == 4: free → entries 92..95 each shown one tick.

### b.14 Bunker room — Barnes $182b0, grenade $1833a
```
obj_barnes: barnes_fire() ; frame = px s< $82 ? 0 : px s< $a0 ? 1 : 2        ; entries 69..71
barnes_fire ($17f68): if $57f54: return ; if $57f5a s>= 0: $57f5a -= 1 ; return
   b = first free of 7..9 else return
   d1 = (y - py) lsr 3 ; d0 = px - x
   dx = d1.b == 0 ? (d0<0 ? -$f : $f) : sign(d0) * ((|d0| divu d1) & $f)
   b = {x+$e, y, dx, active $ff} ; $57f5a = (rand() & $f) + $a ; sfx($82)
obj_grenade: y += 4 + arc[+e]   (arc $18400 = 6,5,4,3,2,1,0,-1,-2,-3,-4,-5,-6)
   if y u>= $8c: free (no explosion)
   +e += 1 ; if +e != $d: return                                   ; lands after 13 ticks at py+$1e+$34
   if $60 s<= y s< $6e... (y s>= $60 and y u< $6e) and $9b s< x s<= $aa and Barnes alive:
       Barnes.active -= $a
       if != 0: sfx($81) ; msg((rand() & 1) + $e)   ; $e "DIRECT HIT !" / $f "YOU GOT HIM!"
       else:    msg($10 "GET TO THE BUNKER - NOW!") ; $57f55 = 0 ; sfx($81) ; $57f55 = $ff
   else: sfx($85)
   obj_to_explosion
```
A hit requires throwing from depth py in [$e, $1b] and x in [$92, $a0] (the entry x $a0 works).
5 hits kill Barnes; 9 grenades per man. Then walk to x in ($9e,$ae] at depth $5f → game_won:
`clear_play_and_pal ; text_screen_music3($18b5f "YOU MADE IT! A HUEY IS ON IT'S WAY, TO TAKE YOU BACK TO THE
FIREBASE !") ; jmp $f864` (game over + hiscore; the game is finished) **[verified]**.

### b.15 Dead / unreferenced code and data
- $1780a `dead_project` (perspective x/y mapping, 138/100 scale) and $179be `dead_debug_frame`
  (keys $4d/$4b change the frame, prints hex) are not referenced anywhere.
- $17260 (10 bytes), $18b5a (print string without text), $18f64-$18f99 (small bitmap), and
  $19018-$193ff (leftover section-1 flare code, references $1a0ae/$3b22f) are unreferenced.
- Messages 2 (duplicate of 3), 4 "GOT YA !", $c "JUNGLE CONFRONTATION", $d "KILL BARNES WITH THE
  GRENADES." are never queued. Bob entries 72-74, 87 are never used. Object types 1, 2 appear in no room.

---------------------------------------------------------------------------------------------------
## (c) RAM variables

Kernel globals (a6 = $12dde) used here: $0..$1d men (5 x {grenades, ammo, hits}); $1e man ptr; $22 man
index (0/1); $26 compass carried (read); $2a compass heading 0..3 (written); $2e morale (read/-$800);
$4a message table ptr; $54 byte cleared per room; $5a current top palette ptr (kernel); $62 back buffer
($70000/$78000); $68 timer enable; $6a timer 50 Hz sub-counter; $6c/$6d timer minutes/seconds BCD;
$70/$71 cheat flags (bit1 of $71 = MEGA CHEAT).

| addr | size | meaning | init | written by / read by |
|---|---|---|---|---|
| $17226 | w | last seen timer value | disk $0159 | main_loop |
| $172aa | w | fade active | 0 | fade_out_start / l3hook_fade, fade_out_wait |
| $172ac | l | saved level-3 vector | | fade_out_start / l3hook |
| $189dc | 4 b | hint message numbers | from $189d8 + compass test | fj_restart, main_loop / hint_tick |
| $18f1c | b | current room 0..119 | $69 | room_setup |
| $18f40 | l | direction offsets [R,B,L,F] | $010afff6 | room_setup |
| $1900a | l | soldier handler | | room_setup / soldier_spawn |
| $1900e | w | soldier start x | | " |
| $19010 | w | soldier dx | | " |
| $19012 | w | path half-width | $32 | player, room_setup, respawn / player, blocks |
| $19014 | w | saved path width | | player / blocks |
| $19016 | b | soldier start frame | | room_setup / spawn |
| $57b00 | 200 l | row offsets i*40 | | fj_entry / draw_bob |
| $57e22 | 16*$12 | object slots (§b.1) | $18df0 | everyone |
| $57f42 | b | soldiers left in the room pool | 0..5 | room_setup, spawn, soldier leave |
| $57f44 | b | exit mask of the room (0 = bunker room) | | room_setup |
| $57f45 | b | room type (write-only) | | room_setup |
| $57f46 | l | player x,y at the start of the tick | | player / blocks |
| $57f4a | b | rifle shot request | 0 | player |
| $57f52 | b | fire latch | 0 | player, pl_shoot |
| $57f53 | b | '.' key latch | 0 | player |
| $57f54 | b | player dying | 0 | player_hit, dead_wait |
| $57f55 | b | write-only flag around Barnes' death sfx | | grenade |
| $57f56 | w | hint countdown | 0 | hint_tick |
| $57f58 | w | soldier spawn delay | $14 | spawn |
| $57f5a | w | enemy fire cooldown (shared) | $14 | soldier_fire, barnes_fire |
| $57f5c | w | idle-shot countdown | $64 | idle_shot_tick, player_hit, idle_shot_end |
| $57f5e | w | depth at last idle reset | 0 | idle_shot_tick |
| $57f60 | l | slot used by the idle shot (0 = none) | 0 | idle shot |
| $57f64 | w | sfx played by play_hit_sfx | $80 | mines ($81) |
| $57f66/$57f6a/$57f6e | l,l,w | saved gfx/handler/word+10 of the borrowed slot | | idle shot |
| $57f70 | 16 w | working palette for fades / napalm flash | | pal_copy_current |
| $57f90 | 256 b | depth sort buckets ($ff = empty) | $ff | objects_update_draw |
| $58190 | 3600 b | bob blit buffer (mask + 4 planes, one extra word per row) | | draw_bob |
| $68000 | 4 x $2000 | decoded room background (rows 0..151 used; 144 shown) | | room_load_picture / bg_restore |

---------------------------------------------------------------------------------------------------
## (d) Data formats (all verified by `extract.py`)

### d.1 Palettes
- game (playfield) $18fc2: `000 480 8a0 ac2 c80 fa2 fc6 060 800 a62 aa2 882 662 882 6ff 000`
- text screens $18fe2: `000 000 f00 600 0f0 060 ff0 660 fff 666 000 000 000 000 000 300`
  (res_print colour codes pick pairs: 2/3 red, 4/5 green, 6/7 yellow, 8/9 white/grey)
- HUD $176be: `000 00f f00 f0f 0f0 0ff ff0 fff 000 000 c66 a60 444 888 640 000` (colours 8/9 are
  animated at run time by the kernel message system, $10836).

### d.2 Room background pictures (10) — table $18f9a, data $19400
Picture n (1..10) starts at $19400 + long[$18f9a + 4*(n-1)] (offsets 0, $49af, $91fc, $dab8, $123f0,
$16da2, $1b5a4, $1fe7a, $247ca, $291cd; pictures are contiguous, the last ends at $46e5e).
Format (decoder $17604): 4 planes one after the other; each plane starts with an escape byte E, then
tokens: byte b != E → output b; b == E → value v, count c (c = 0 means 256) → output v c times. Each
plane is exactly $17c0 bytes (152 rows x 40 bytes; a run is cut when the plane is full). Only rows
0..143 are copied to the screen. Output: `assets/pic01..10.png` (red line = row 144).
Room type → picture ($18f1d): types 0-2 → 4, 3-4 → 5, 5-6 → 6 (right turns); 7-8 → 7, 9-10 → 8,
11-12 → 9 (left turns); 13 → 1, 14 → 2, 15 → 3 (T-junctions); 16 → 10 (bunker with Barnes' foxhole).

### d.3 Bobs — directory $47400 (96 entries x 8 bytes), data $47700.. $57a63
Entry: long ofs (data = $47700 + ofs), word words-1, word rows-1. Data: long header (words-1, rows-1),
then MASK plane (rows x words words), then bitplanes 0..3 (rows x words words each), row-major.
Objects point +6 at a directory entry and use entries (frame + anim>>1) relative to it.
| entries | use |
|---|---|
| 0-58 | player (3 sizes, §b.8) — dir $47400 |
| 59-68 | soldier — dir $475d8 |
| 69-71 | Barnes (facing left/centre/right) — dir $47628 |
| 72-74 | (bushes, unused) |
| 75-77 | mines (object types 3-5) |
| 78-80 | barbed wire (types 6-8) |
| 81-83 | logs (types 9-11) |
| 84 | player bullet / idle shot in flight ($476a0) |
| 85 | grenade ($476a8) |
| 86 | enemy bullet ($476b0) |
| 87 | unused ($476b8) |
| 88 | idle shot first tick ($476c0) |
| 89-91 | rocks (types 0-2) |
| 92-95 | explosion ($476e0) |
Output: `assets/bobs.png` (index labels), `bobs.json`.

### d.4 Map — $18ea4, 12 rows x 10 columns (room index = row*10 + col), one byte = room type 0..16
```
  0: 00 00 00 00 08 0b 00 00 00 00
 10: 00 00 00 00 10 06 0c 00 00 00
 20: 00 00 00 05 10 08 02 07 00 00
 30: 00 00 06 0c 10 01 0a 04 09 00
 40: 00 04 09 05 0b 06 07 06 0b 00
 50: 05 07 03 08 03 0c 05 07 00 00
 60: 02 0f 07 01 09 00 01 0c 00 00
 70: 00 01 08 05 0a 0b 07 06 0a 00
 80: 00 00 06 0a 02 05 06 0c 03 09
 90: 00 00 00 01 0c 00 04 08 02 0c
100: 00 00 00 00 0e 0d 0f 01 0b 00
110: 00 00 00 00 07 09 09 0a 00 00
```
Type → exits ($18f2e): 0-6 → 2 (right only), 7-12 → 1 (left only), 13-15 → 3 (both), 16 → 0 (bunker).
Start room $69 = 105 (type 13), heading "north" (F = -10). Graph analysis (maze_graph.json): 72
(room, heading) states are reachable, every state except the 4 bunker states has its exits, every
state has in-degree 1 — the maze is a tree with 4 T-junctions whose every branch ends in a bunker room
(rooms 34 N, 24 E, 24 W, 14 S at 14, 17, 21 and 26 transitions), plus one loop (the right branch of the
start room leads round back to the start via 115). No exit ever leads into a type-0 cell.
Shortest route: `L R L R L R L R R L R L R L` (rooms 104 94 93 83 82 72 71 61 62 52 53 43 44 34)
**[verified in the emulator]**. `assets/map.png` shows every cell with its room render and the route.

### d.5 Room object lists — $18866 (17 longs), entries: word object type ($ffff ends), word x, word y
(type: list) 0: none; 1 & 11: (7,96,50) (9,144,14) (8,168,76); 2 & 12: (3,96,20) (3,184,32) (4,136,54)
(5,176,76) (5,120,80); 3 & 13: (10,112,48); 4 & 14: (6,128,18) (7,72,48) (7,176,52); 5 & 15: (10,120,50)
(0,96,26) (3,200,16); 6: (0,85,20) (9,128,20) (10,160,64) (7,104,54); 7: none; 8: (4,216,40) (3,88,16)
(3,188,16) (4,144,38) (5,112,66) (5,160,72); 9: (9,112,24); 10: (9,160,32) (11,96,72); 16: none (Barnes is
set up by room_setup). Max 6 objects (slots 10-15). `assets/rooms/room_TT.png` = picture + objects +
player at the entry, rendered with the exact blit/sort model: **pixel-identical to the emulator** for
room 13 (start) and room 16 (bunker, only an in-flight enemy bullet differs) **[verified]**.

### d.6 Texts
In-game messages $189e0 (col, row $12, text, $ff): 0 GET GOING!, 1 KEEP MOVING!, 2/3 GOOD SHOOTING!,
4 GOT YA !, 5 NOT LONG BEFORE THE NAPALM, 6 GO GET 'EM, 7 STAY ALERT, 8 THAT'S THE WAY TO DO IT!,
9 KILLED IN ACTION, $a YOU'RE HIT, $b A COMPASS WOULD HELP !, $c JUNGLE CONFRONTATION, $d KILL BARNES
WITH THE GRENADES., $e DIRECT HIT !, $f YOU GOT HIM!, $10 GET TO THE BUNKER - NOW!.
Text screens (res_print format: col,row, codes 1-4 + value = colour slot, 0 = new col,row, $ff end):
intro $18c6d, won $18b5f, napalm $18bb8, withdrawn $18c14 (unused), destroyed $18ce7, one more chance
$18d2c. Full decode in `assets/messages.json`.

### d.7 Other tables
grenade arc $18400; exit parameters $18f48/$18f4c/$18f52/$18f58; score per kill 4-byte BCD 00000300 at
$18ffe; slot init $18df0 — all in `assets/tables.json`.

---------------------------------------------------------------------------------------------------
## (e) Per-frame flow and timing
- Main loop: HUD update, logic that spawns (idle shot, soldiers, hints), `k_wait_swap` (waits until the
  level-6 split interrupt at line $cc has installed the copper list requested by the previous `k_swap`),
  background restore, object logic + draw into the back buffer, `k_swap` (toggle $62(a6), request the
  other copper list). There is no explicit vblank wait: the loop is paced by the swap, i.e. **one logic
  tick per displayed frame (50 Hz)**, a tick is only stretched to 2 frames when its work does not fit
  (route run, 1361 ticks measured with --bp $17118: 1335+11 ticks of one frame (11 fell twice into the
  same emulator frame number because the swap point is line $cc, not vblank), 1 tick of 2 frames, and the
  14 room transitions of ~18 frames each (fade-out + RLE decode)).
- Level 3 (vblank, kernel $10eac): music, pause key (Tab), F10 music/fx toggle, RNG, and the timer:
  `$6a(a6)` counts down each vblank; when it goes negative (and $68(a6) != 0) it is reloaded with $31 and
  the BCD seconds/minutes at $6c/$6d are decremented (so 1 second = 50 vblanks; the first second after a
  (re)start takes 51). 2:00 = 6000 frames **[verified: 00:00 at frame 6000]**. During a fade-out the
  section's hook $172c2 runs first.
- Level 6 (kernel $10faa): copper list swap at the split, BPLCON1 from $72(a6) (0 here).
- The timer is never stopped during room changes, text screens after death reset it to 2:00
  (fj_restart); the win/lose screens stop mattering (game over).

## (f) Rendering
- Display (kernel copper lists $115d0/$116a8): 4 bitplanes, lowres 320 px; playfield window DIWSTRT
  $3c71 (first line $3c, canvas x=17 in the emulator's 384x290 shots, y=36); playfield bitplanes at
  $70000 or $78000 (+$2000 per plane, modulo 0, rows 0..143); `WAIT $cc01` then the HUD from $79680
  (planes +$2000) with the HUD palette. Top palette = game palette $18fc2 (copied into the copper list
  by kernel $f878). No sprites, no scrolling, no playfield splits other than the HUD.
- Double buffering: draw into ($62(a6)), displayed buffer = the other; toggled by $f84c each tick.
- Blit 1 `bg_restore` ($17558), 4x: BLTCON0 $09f0 (A→D), BLTCON1 0, A = $68000+p*$2000, D = back+p*$2000,
  AMOD = DMOD = 0, BLTSIZE $2414 (144 rows x 20 words). AFWM/ALWM are not written (kernel leaves $ffff).
- Blit 2 `draw_bob` ($17850) per object: (a) clear buffer: BLTCON0 $0100, D = $58190, DMOD 0,
  BLTSIZE $4b06 (300 x 6 words); (b) copy bob: BLTCON0 $09f0, A = bob data (after the header), D = $58190,
  AMOD 0, DMOD 2, BLTSIZE = (5*rows)<<6 | words → every row gets one extra zero word; (c) 4x cookie-cut:
  BLTCON0 = (x&15)<<12 | $0fce, BLTCON1 = (x&15)<<12, A = $58190 (mask block), B = $58190 +
  rows*(words+1)*2 for plane 0 and then continuing (BMOD 0), C = D = back + row*40 + ((x>>3)&$fffe) +
  p*$2000, AMOD = BMOD = 0, CMOD = DMOD = 40-2*(words+1), BLTSIZE = rows<<6 | (words+1). Screen row =
  $8f - depth - (rows-1 of the directory's entry 0). No clipping: x beyond 320 wraps into the next row.
  Reference implementation: `extract.py` `blit_bob`/`draw_objects` (pixel-exact, §d.5).
- Text screens use the kernel/resident 2bpp font via res_print into both buffers.

## (g) Input
Joystick port 2 via res $410 (bit0 down, bit1 right, bit2 up, bit3 left, bit7 fire). UP = walk away
from the camera (depth +2), DOWN = towards it (depth -2), LEFT/RIGHT = x ∓4 (diagonals combine; UP+side
animates forwards, UP alone backwards). FIRE = rifle (one shot per press) in normal rooms; in the bunker
room FIRE and the '.' key (raw $39) throw a grenade (one per press each). CAPS LOCK ($62) wins instantly
with MEGA CHEAT. Kernel keys: Tab pause, F10 music/fx toggle. Fire on text screens: continue (after 1 s).

## (h) Gameplay summary
Find a bunker room within 2:00: walk to the far end of the path (depth >= $5a) and leave by the
available side exit(s). Dangers: soldiers walking across the far end (aimed shots, cooldown 20-35 ticks,
0-5 per room visit), the idle sniper shot (keep changing depth: 50 ticks, 100 after a room entry/hit),
mines (explode on contact), barbed wire (blocks and hurts), logs/rocks (block). Each hit: -$800 morale,
+1 hit; 4 hits = man dead: the first time the whole jungle restarts with man 1 and a fresh 2:00, the
second time (or morale 0) the game is over. In the bunker room kill Barnes with 5 grenade hits (he shoots
back), then enter the bunker (x $9f..$ae at depth $5f): "YOU MADE IT!" → game over/hiscore.
Random numbers: soldier count per room, spawn delay, fire cooldown, idle-shot side, hint choice/delay,
kill message, grenade hit message.

## (i) Sound and music calls
| call site | d0 | when |
|---|---|---|
| $17034/$17038, $1771e | music 5 | in-game jungle tune (after intro / after "one more chance") |
| $176de | music 3 | all end / death text screens |
| $1740c | sfx $82 | idle shot fired |
| $17ffc, $18076 | sfx $82 | soldier / Barnes fire |
| $18162 | sfx $82 | player rifle shot |
| $18334 | sfx $a | grenade throw |
| $180f6 (play_hit_sfx) | sfx ($57f64) = $80, or $81 after a mine | player hit, soldier killed |
| $183b4.. | sfx $81 | grenade hits Barnes; $85 when it misses |
| $1718a | sfx $81 | napalm (time up) |
(kernel k_fx: >= $80 = sample effects, played on two channels; see re/audio.)

## (j) Open questions / uncertainties
- Which of platoon_b.adf's track 127 bytes are exactly the original is inferred from the decoder landing
  exactly on the next picture; no second independent dump was compared. (High confidence.)
- The in-game soldier "4 - anim/2" standing frame formula yields frame 4 only because anim is always
  0..7 after the draw loop; if a port changes the draw order, keep the `anim &= 7` write-back.
- Barbed wire/mines do not test $57f54. Static objects run BEFORE the player handler (slot order 15..0),
  so they test the position after the previous tick's move and restore $57f46 = the position before that
  move; while dying $57f46 is frozen, so a repeated hit needs the pre-move position to overlap too —
  not observed, but a port must keep the slot order to reproduce this exactly.
- $54(a6) cleared on each room entry: kernel HUD meaning not investigated (belongs to the kernel module).
