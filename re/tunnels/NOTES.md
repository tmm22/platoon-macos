# Platoon (Amiga) — Section 1 "THE TUNNEL SYSTEM" (tunnels module)

Scope: load section 1 (tracks $54..$6e, $1b tracks → RAM $17000..$3c200). This module owns the tunnel
game (first-person maze, rooms, enemies, items, map/compass) and the shared engine code of section 1
(entry, main loop, object system, bob blitter routine, palettes, fades, game-over/restart texts).
The flare section (entered at `$18b0e`) lives in the same load and is documented in `re/flare/`; routines
that only the flare section uses are named here but not specified.

Files in this directory:
- `NOTES.md` (this spec), `labels.txt` (rdis labels), `icomments.txt` (inline comments),
  `flare_entries.txt` (flare object handler entry points so rdis finds them),
  `mklisting.py` → regenerates `tunnels.s` (rdis listing $17000-$1a0b2 + inline comments).
- `tlib.py` — Python port of the view/map/bob/room-picture algorithms (the reference implementation used
  for verification). `extract.py` — writes everything under `assets/` and pixel-verifies 30 emulator
  screenshots (`assets/ref/view_X_Y_D.png`) against the Python renderer (0 mismatches).
- `work/` scratch (emulator runs, test scripts `etest.py`, `itest.py`, `vtest.py`, `walk1.py`).

All addresses are absolute. `a6 = $12dde` (kernel globals) throughout; `a5 = $1e(a6)` = current soldier record.
"tick" = one pass of the section main loop = 4 vblanks (12.5 Hz PAL), see §e.

---------------------------------------------------------------------------------------------------------
## (a) How to reach it in the emulator

Boot recipe (frames absolute from power-on):
```
300 fire 1
305 fire 0
350 poke 12e4c 1 2        ; section index 1 (tunnels+flare)
600 fire 1
605 fire 0                ; -> section 1 loads, entry $17000 at ~f698, intro text "THE TUNNEL SYSTEM"
900 fire 1
905 fire 0                ; leave intro text -> tunnel play
912 save re/states/tunnels_start.state
```
State files made by this module:
- `re/states/tunnels_start.state` — frame 912, first tick of the first life: at (21,3) facing W, no enemy yet
  (first spawn after (rand&3)+2 ticks). Morale $9000, ammo $90, score 0, no map/compass/flares.
- `re/states/tunnels_room0.state` — standing in room 0 (map cell (8,3), the officer/guard room),
  ~40 frames after entering (guard alive, has not fired yet). Reached by `work/walk1.py` from tunnels_start:
  F×10, L, F×4, R, F×8, R, F×4, R, F×5 (F = hold up 8 frames + 6 idle, L/R = hold 6 frames + 6 idle),
  poking `3b237 ff 1` every 200 frames to suppress enemy spawns.
- Existing `re/states/section1_play.state` (frame 1000) is also in the tunnels (an enemy is already out).

Useful pokes (all while playing):
- teleport: `poke 1a0b0 XXYY 2` (x<<8|y), direction `poke 12e08 D 2` (0=N 1=E 2=S 3=W); the view is
  redrawn next tick. Walking into a room entrance cell (see rooms table) enters the room.
- suppress enemies: `poke 3b237 ff 1` (spawn countdown, only runs while no enemy; 255 ticks ≈ 20 s).
- force enemy now: `poke 3b237 1 1`.
- crosshair position: `poke 19d34 X 2`, `poke 19d36 Y 2`.
- map on: `poke 12e02 1 2`, `poke 3b3f8 0 4`, `poke 3b3fe a 4`. Flares: `poke 12e0a 8 2`.
- hits of current soldier: `poke 12de2 N 2` (4 = dead).
- IMPORTANT emulator usage note: script lines must be sorted by frame (events are consumed in file order;
  an out-of-order earlier frame fires late). Inputs must be held ≥4 frames (one tick) to be seen.

---------------------------------------------------------------------------------------------------------
## Memory map of section 1 (verified against the ADF image)

| range | content |
|---|---|
| $17000-$19374 | code (tunnels + shared + flare). $19356-$19373 unused routine |
| $19374-$1941c | message pointer table (42 entries) for the kernel message system |
| $1941c-$1981c | message texts: `x.b, $12, text…, $ff` |
| $1981c-$199bc | text-screen strings (resident `$408` print format) |
| $199bc-$19d32 | item handlers, room tables, hotspots, sway table, direction tables, water-enemy tables |
| $19d32-$19e0a | tunnel objects 0..7 (18 bytes each, 8 slots; initial contents in ADF) |
| $19e0a-$1a012 | flare section objects/data (re/flare) |
| $1a012-$1a0b2 | palettes, map-cache pointers, score constants, crosshair speed, player position |
| $1a400-$1c400 | 256 view tiles (8×8, 32 bytes) |
| $1c400-$1e020 | 40 view tile-maps (10×18 tile indices = 180 bytes each) |
| $1e020-$1e140 | bob frame table (8-byte entries) |
| $1e220-$26ece | bob graphics (header + mask + 4 planes) |
| $29220-$29720 | 40 map-display tiles (32 bytes each, index = map cell value) |
| $29720-$29e59 | maze map 43×43 bytes |
| $2a220-$35628 | 4 room pictures (2 + 20×144×4 bytes each: $2a220, $2cf22, $2fc24, $32926) |
| $36242-$3a50c | flare section picture (byte RLE, see re/flare) ; $3a50c.. more flare data |
| $3b220-$3b3fc | variables (cleared at entry) and tables built at entry (see §c) |
| $3b402-$3b722 | line offset table (200 longs) |
| $3b722 | 16-word fade palette buffer; $3b742-$3cd22 bob scratch (5600 bytes); $3cd22 flare scratch |
| $3d182, $3d4a2 | two 360-byte map tile caches (filled with $ff at each life start: $3d182..$3d7c4) |

---------------------------------------------------------------------------------------------------------
## Kernel / resident calls used (semantics needed by the port; details in re/kernel)

| call | target | use here |
|---|---|---|
| `$408` | resident print | print a text-screen string (a0) |
| `$40c` | resident key test | d0 = raw key code; returns d0≠0 / Z clear if held ($5f = HELP) |
| `$410` | resident joystick | d0: bit0 down, bit1 right, bit2 up, bit3 left, bit7 fire (port 2) |
| `f808` | $1058a | refresh HUD item icons (flares $2c, map $24, compass $26 showing dir $2a, $28) |
| `f80c` | $10638 | score += 4-byte BCD **ending at a0** (abcd -(a0),-(a1) ×4 into $4e(a6)..$51); clears $52(a6) |
| `f818` | $10656 | redraw hit icons of current soldier ($1e(a6)→+4) |
| `f82c` | $1070c | queue message d0 (index into `$4a(a6)` = $19374); ≤4 queued, count in `$48(a6)` |
| `f830` | $1084a | force full HUD redraw |
| `f834` | $108a0 | HUD update (message scroll, score, bars, icons) — called every vblank while waiting |
| `f840` | $104aa | clear both 32K screen buffers $70000/$78000 |
| `f844` | $10acc | wait d0+1 vblanks |
| `f848` | $10ad6 | wait next vblank |
| `f84c` | $10ae2 | swap buffers: `$62(a6) ^= $8000` (draw buffer), queue other copper list (applied by level-6 int) |
| `f850` | $10bcc | random byte → d0.l (0..255); 8-step LFSR on $12d70 (also stirred by vblank) |
| `f85c` | $10b14 | wait until queued copper swap happened |
| `f864` | $fee8 | game over (hiscore, back to title) |
| `f868` | $10c00 | start tune d0 |
| `f86c` | $10c50 | sound effect d0 |
| `f874` | $11076 | section finished → next section (used at flare end) |
| `f878` | $11010 | set playfield palette from a0 (16 words), `$5a(a6)=a0` |
| `f87c` | $11000 | set HUD (lower split) palette from a0, `$5e(a6)=a0` |

Globals (a6 = $12dde) used by the section: `+$00..$1d` 5 soldier records {w grenades=9, w ammo=$90,
w hits=0} (6 bytes each; only records 0 and 1 are used here), `$1e.l` current soldier, `$22.w` soldier
index (0/1), `$24.w` map owned, `$26.w` compass owned, `$2a.w` facing (0 N,1 E,2 S,3 W), `$2c.w` flares,
`$2e.w` morale (unsigned; carried in from earlier sections, $9000 in the poke-boot), `$48.w` queued
messages, `$4a.l` message table, `$4e.l` BCD score, `$54.b` ($ff: HUD grenade slot shows flares),
`$56.b` vblank flag, `$5a.l` current palette ptr, `$62.l` draw buffer ($70000/$78000), `$6a.w` vblank
down-counter (tick pacing), `$71` bit1 = cheat enabled (kernel keyboard cheat).

---------------------------------------------------------------------------------------------------------
## (b) Code map (every routine in scope, with faithful pseudocode)

Notation: `b[]`/`w[]`/`l[]` = byte/word/long memory; all compares signed unless noted.

### $17000 sec1_entry (runs once per section load)
```
SSP = $400
clear b[$3b220..$3b3fb]                       ; $1dc bytes
for n in 0..24:  l[$3b248+4n] = n*$140        ; char-row (8 lines) byte offsets
for n in 0..42:  l[$3b2ac+4n] = n*43          ; maze row offsets
for n in 0..199: l[$3b402+4n] = n*40          ; line offsets
for n in 0..39:  l[$3b358+4n] = n*180         ; view tile-map offsets
f840
textscreen($1981c)                            ; "THE TUNNEL SYSTEM / PRESS FIRE TO CONTINUE" (no tune 3 here)
$1e(a6) = a6+0; w[$22(a6)] = 0
for i in 0..4: soldier[i] = {9, $90, 0}       ; at a6+6i
l[$4a(a6)] = $19374; b[$54(a6)] = $ff; w[$3b23c] = w[$24(a6)]   ; remember map flag at entry
fall into life_start
```
### $170c4 life_start (start of each life; also after the first soldier dies)
```
b[$19d7b]=0 (guard frame); l[$19d84]=$17b0c (guard handler reset); b[$3b233]=0
b[$3b237] = (rand & 3) + 2                    ; first spawn after 2..5 ticks
w[$24(a6)] = w[$3b23c]                        ; a map found in this section is lost with the soldier
if $24(a6)==0: l[$3b3f8]=10, l[$3b3fe]=20 else: l[$3b3f8]=0, l[$3b3fe]=10   ; byte columns of view halves
a5 = $1e(a6); f830; b[$3b236]=b[$3b235]=0
pos = (21,3) (b[$1a0b0]=$15, b[$1a0b1]=3); w[$2a(a6)]=3 (W); w[$26(a6)]=0 (compass); w[$2c(a6)]=0 (flares)
for each word at $19a60.. until word<0: clear bit7   ; all items available again
b[$3b230]=0; copy 16 words $1a032→$1a012; f878($1a012); f87c($1a06e); f830
recolour_crosshair()                          ; $1897a
fill $3d182..$3d7c4 with $ffff (801 words)    ; invalidate both map caches
```
### $171c6 main_loop
```
loop:
  do { f848; f834 } while w[$6a(a6)] >= 0      ; vblank handler decrements $6a (see §e)
  w[$6a(a6)] = 3
  draw_map()                                  ; $17640
  draw_view()                                 ; $17406
  if b[$19d56]==0 and b[$19d68]==0:           ; obj2 and obj3 inactive (obj1 NOT checked)
      if --b[$3b237] == 0:
          b[$3b237] = (rand & $31) + $10      ; 16..65 ticks
          if b[$3b230]==0: spawn_enemy()      ; not in a room
  objects_tunnel()                            ; $177b8 (handlers + bob drawing)
  f84c                                        ; swap buffers
  w[$1a096] ^= 4                              ; map cache belonging to the new draw buffer
  if b[$3b236]: goto end_soldier_lost
  if w[$2e(a6)]==0: goto end_withdrawn
  if b[$3b235]: goto end_destroyed
```
### $17252 end_destroyed / $17262 end_withdrawn / $172f6 end_soldier_lost / $17272 / $1727e textscreen
```
end_destroyed:  textscreen_music3($19851); jmp f864      ; "YOUR PLATOON HAS BEEN DESTROYED"
end_withdrawn:  textscreen_music3($198a3); jmp f864      ; "…HAS WITHDRAWN FROM ACTION"
end_soldier_lost: textscreen_music3($198fc); goto life_start   ; "ONLY ONE OF YOUR PLATOON MEMBERS REMAINS…"
textscreen_music3(a0): f868(3); textscreen(a0)
textscreen(a0): f840; f878($1a052); f87c($1a06e); print(a0) via $408; f844(49) (=50 vblanks)
                wait until ($410 & $80); f868(4); f840; copy $1a032→$1a012; f878($1a012)
```
### $17304 spawn_enemy
```
w[$1a0ae] = 2                                  ; crosshair speed reset
L = b[$3b22c] (left view code), R = b[$3b22d]
if L & $18:                                    ; wall or room door ahead within 4 cells
    obj3 = {active=$ff, frame 0, x=$23, y=$3b, frametab=$1e108, handler=h_water, e=0,c=0}   ; b[$19d69]=0, l[$19d76]=0
elif (L & 7) == 5:                             ; left side opening 2 cells ahead
    obj2 = {active, x=$23, y=$36, frametab $1e080 (unchanged), handler=h_enemy_aim, e=0, frame=2}
elif (R & 7) == 5:
    obj2 = {active, x=$69, y=$36, handler=h_enemy_aim, e=0, frame=2}
else:
    obj2 = {active, frame 0, x=$41, y=$27, handler=h_enemy_walk, e=0}
```
(obj2 frametab pointer is not written; it stays $1e080 from the ADF.)

### $17406 draw_view (verified pixel-exact on 80 random positions)
```
if b[$3b230]: goto draw_roompic                 ; in a room
(lo, ro, fo) = words at l[$19cca + 4*(dir&3)]   ; map offsets left/right/forward
   dir0 N: (-1,+1,-43)  dir1 E: (-43,+43,+1)  dir2 S: (+1,-1,+43)  dir3 W: (+43,-43,-1)
c(o) = b[$29720 + y*43 + x + o]
; forward scan (done identically for each half)
F=0; o=fo; for d4 = 3,2,1,0: if c(o)==3 {F=$10|d4; break}; if c(o)!=2 {F=$08|d4; break}; o+=fo
; left half
d6 = F; o=lo; for d4=3..0: if c(o)==2 {d6 |= 4|d4; break}; o+=fo
; right half  (NOTE asymmetry: wall-distance bits are dropped when an opening is found)
d7 = F; o=ro; for d4=3..0: if c(o)==2 {d7 = ((d7|4) & $fc) | d4; break}; o+=fo
if d6==0 and d7==0: d6 = d7 = (dir&1 ? x : y) & 3     ; plain corridor: 4-phase "walking" animation
elif d6==0: d6 = d7 & 3
elif d7==0: d7 = d6 & 3
b[$3b22c]=d6; b[$3b22d]=d7
draw_viewhalf(d6, column=l[$3b3f8]); draw_viewhalf(d7+$14, column=l[$3b3fe])
```
d4 = 3 − distance (distance 0 = the cell right ahead / right beside the player). Observed code set over
the whole maze (all cells × 4 dirs): 0..$13 on both sides; $14..$17 never occur. Meaning table in
`assets/viewcodes.json`; pictures in `assets/viewmaps_sheet.png` (L00..L13 = left maps 0..$13,
R00..R13 = right maps $14..$27):
- 0-3 corridor continues ≥4 cells, no side opening (animation phase);
- 4-7 side opening, 4 = 3 cells ahead … 7 = adjacent;  8-$b wall ahead, 8 = 3 ahead … $b = directly ahead;
- $c-$f wall + opening (left: OR of both distances; right: opening distance only);
- $10-$13 room door ahead ($10 far … $13 directly ahead).

### $1756c draw_viewhalf(d1=code, a4=byte column)
```
src = $1c400 + code*180
for row 0..17: for col 0..9:
   t = b[src++]; tile = $1a400 + t*32
   dst = $62(a6) + row*$140 + col + a4
   for r 0..7: for p 0..3: b[dst + r*40 + p*$2000] = b[tile + r*4 + p]
```
(CPU copy, 4 planes $2000 apart, 40 bytes/line.)

### $17640 draw_map
```
cell = &map[y][x]; save = b[cell]; stored into the immediate byte at $177b5 (self-modifying code)
b[cell] = $21 + w[$2a(a6)]                        ; arrow tile
wx = clamp(x-10, 0, 23); wy = clamp(y-9, 0, 25)   ; signed byte compare
if w[$24(a6)] != 0:
   cache = l[$1a08e + w[$1a096]]                  ; $3d182 or $3d4a2
   for j 0..17: for i 0..19:
       v = map[wy+j][wx+i]
       if v != b[cache]: b[cache] = v; draw 8x8 tile $29220+v*32 at char row j, byte column 20+i
       cache++
b[cell] = save                                   ; ($177b2 move.b #save,(a0))
```
Map window always at byte columns 20..39 (not relative to $3b3f8). Verified pixel-exact.

### $177b8 objects_tunnel
```
for slot = 7 downto 0:  a3 = $19d32 + 18*slot
   if b[a3]: call l[a3+$a](a3); if b[a3]:
      draw_bob(x=w[a3+2], y=w[a3+4], data = $1e220 + l[l[a3+6] + 8*b[a3+1]])
```
Handlers run with a3=object, a5=soldier, a6=globals; drawing is interleaved (slot 7 first, crosshair last
= on top).

Object record (18 bytes): `+0 b active ($ff/0)`, `+1 b frame`, `+2 w x`, `+4 w y` (pixels relative to
view origin: x from byte column $3b3f8, y from line 0), `+6 l frame table`, `+$a l handler`, `+$e w cnt`,
`+$10 w cnt2`. Slots: 0 crosshair, 1 enemy shot ("flash"), 2 corridor enemy, 3 water enemy,
4 room-0 guard, 5-7 unused. Initial ADF contents in `assets/tables.json` (objects_initial_19d32):
obj0 {ff,0,x=$64,y=$6b,$1e020,h_crosshair,e=$10,c=8}, obj1 {0,0,..,$1e058,h_flash}, obj2 {..,$1e080,..},
obj3 {..,$1e108,h_water}, obj4 {0,0,x=$1e,y=$23,$1e0e0,h_roomguard}.

### $178be h_crosshair (object 0)
```
if (b[$71(a6)] & 2) and key($5f HELP): goto cheat_to_flare         ; $18afe
input_tunnel()        ; may "return twice" (addq #4,a7) in combat/room modes -> no sway
if b[$3b233]==0 and (x,y)==($44,$78): return                          ; at rest
b[$3b233]=0
i = w[a3+$e]; nx = w[$19bc2+i] + $24; ny = w[$19bc4+i] + $68
w[a3+$e] += w[a3+$10]; if (signed byte)b[a3+$f] < 0: w[a3+$e] -= w[a3+$10]; w[a3+$10] = -w[a3+$10]
x,y = nx,ny
```
Sway table $19bc2: 32 (dx,dy) words (arc from (64,0) down to (32,16) and up to (0,1)); step ±8 bytes =
2 entries/tick; index bounces between 0 and $78 (each end entry used twice). While walking the crosshair
swings; when stopped it keeps swinging until it reaches index $40 = (68,120).

### $18330 input_tunnel (called from h_crosshair, a3 = obj0)
```
d0 = joystick ($410)
if b[$19d56] or b[$19d68] or b[$19d44]: goto in_combat              ; any enemy or shot alive
if b[$3b230]:                                                        ; in room
    if b[$19d7a]==0: goto in_room
    if b[$19d7b] != 4: goto in_combat                                ; guard alive
    goto in_room
in_nav ($18378):
  if fire:
     if b[$3b238]: goto dirs                                         ; latch after leaving a room
     if ammo(w[a5+2]) != 0: ammo--; sfx($82)                         ; wasted shot, every tick while held
  b[$3b238]=0
dirs:
  if up:    b[$3b232] ^= $ff; if b[$3b232]: move_forward(); return   ; moves every 2nd tick
            else: b[$3b23a]=0; return
  if right: if bset(3,b[$3b23a]) was clear: dir=(dir+1)&3; return
  elif left: if bset(2,b[$3b23a]) was clear: dir=(dir-1)&3; return
  else b[$3b23a]=0
```
Up has priority over turning; down does nothing in corridor mode.

### $18410 move_forward
```
b[$3b233]=$ff; push w[$1a0b0]; b[$3b23a]=0
x += dx[dir] (b[$19cc2+2dir]); x<0→0; x>42→42 ; y += dy[dir] likewise
v = map[y][x]
if v==2: drop saved; return                                          ; walk
if v==3:                                                             ; room
    b[$3b230]=$ff
    k = index of word (x<<8|y) in $19aec[0..9] (if absent k ends as 9)
    w[$3b23e]=2k; t=w[$19a24+2k]; w[$3b240]=2t; l[$3b242]=l[$19a14+4t]
    w[$3b246] = saved pos
    if k==0: b[$19d7a]=$ff (guard active); w[$19d8a]=0 (guard fire counter)
    return
restore pos from stack                                               ; wall
```
Direction deltas $19cc2: N(0,-1) E(+1,0) S(0,+1) W(-1,0). Only the 10 entry cells (below) are adjacent to
corridors, so every 3-cell that can be entered is in the table.

### $1850e draw_roompic
```
src = l[$3b242]; wb=b[src]=20; hc=b[src+1]=18; src+=2
dst = $62(a6) + l[$3b3f8]
for line 0..hc*8-1: for word 0..wb/2-1:
    p0,p1,p2,p3 = 4 words; w[dst+2*word + p*$2000] = pN   ; plane-interleaved per 16 px
```
### $1858c in_combat
```
if (d0&$f)==0: w[$1a0ae]=2   (no movement this tick)
else: sp = w[$1a0ae]; if w[$1a0ae] < 15 (unsigned): w[$1a0ae] += 2      ; sp = 2,4,..,14,16,16..
b[$3b22f]=0
if ammo!=0 and fire:
    if b[$3b238]==0: b[$3b22f]=$ff; combat_shot()
b[$3b238]=0
if up:    y -= sp; if y<0: y=0
if down:  y += sp; if y>=$7e: y=$7d
if left:  x -= sp; if x<0: x=0
if right: x += sp; if x>=$8e: x=$8d
pop return (skip sway)
```
Auto-fire: one shot per tick while fire is held (12.5 shots/s).
### $18f3c combat_shot
```
ammo--; sfx($83)
x += rand&7; if x>=$8e: x=$8d ;  x -= rand&7; if x<0: x=0
y += rand&7; if y>=$7e: y=$7d ;  y -= rand&7; if y<0: y=0          ; recoil jitter (4 rand calls)
```
### $18654 in_room
```
if (d0&$f)==0: w[$1a0ae]=4 (and sp undefined/unused)
else: sp = w[$1a0ae] >> 2; if w[$1a0ae] < $1f: w[$1a0ae] += 2       ; sp = 1,1,2,2,..,7,7,8
up/down/left/right exactly as in_combat (same bounds)
if fire: if b[$3b22f]==0: b[$3b22f]=$ff; room_click()                 ; one click per press
else b[$3b22f]=0
pop return
```
(Quirk: the speed accumulator is shared; entering combat with w[$1a0ae]=$20 gives 32 px/tick until the
stick is released. spawn_enemy resets it to 2, the room guard does not.)

### $18706 room_click
```
cx=x, cy=y (unsigned byte compares)
list = l[$19b00 + 2*w[$3b240]]  ; groups = w[list]
for g in 0..groups-1: n = w[..]; for each rect (x1,y1,x2,y2 bytes):
     if x1<=cx<=x2 and y1<=cy<=y2: goto found(g)
return (pop)                                                          ; nothing
found: a4 = l[$19a38 + 2*w[$3b23e]] + 2g; code = w[a4]
   if code & $80: code = (code&$7f in {5,$a,$11,$13}) ? $b : 6         ; NOTHING IN THIS DRAWER / EMPTY
   d7 = code; sfx(0); jmp l[$199bc + 4*code]
```
Rects are compared with the crosshair object position (bob top-left); the visible crosshair centre is +9,+9.
### Item handlers ($199bc table, index = item code = message index)
All end by popping the extra return address (return from h_crosshair) unless noted. `+500` = f80c($1a0a8).
```
0  $187d6 leave:   msg d7; pos=w[$3b246]; b[$3b230]=0; b[$3b22f]=0; b[$3b238]=$ff; b[$19d7a]=0; dir=(dir+2)&3
1  $18810 map:     msg d7; if map: msg $1c else { map_slide(); l[$3b3f8]=0; l[$3b3fe]=10; w[$24]=1; f808; +500 }
4  $18862 flares:  w[$2c]=min(w[$2c]+5, 8); f808; → 5
5  $18880 score:   +500 → $13
$13 $1888c taken:  b[a4+1] |= $80; w[$2e(a6)] += $200 (morale, no clamp) → generic
generic $18898:    msg d7          (codes 2,3,6,7,8,9,$b,$e,$10,$14,$16)
$a $188a4 food:    msg $a; msg $1d; +500  (never marked taken: repeatable score)
$c $188ba ammo:    if ammo==$90: generic else ammo=$90 → 5
$d $188ce medic:   if hits==0: generic else hits--; f818 → 5
$f $188e6 blocked: msg $f; msg $1e
$11 $188fc compass: w[$26]=1; f808 → 5
$12 $1890c roman:  msg $12; msg $1f
$15 $18922 EXIT:   msg $f; msg $15; if flares<5: msg $21; return
                   if flares<8: msg $22; return
                   if !compass: msg $23; +30000 (f80c($1a0ac)); goto flare_start ($18b0e, never returns)
```
### $18f1a map_slide
```
loop: f85c; l[$3b3f8] -= 2; if 0: return; draw_roompic(); f84c
```
(picture drawn at byte columns 8,6,4,2 into alternating buffers; the main loop then draws at 0.)

### Enemy / shot handlers
`hit_*` routines test the crosshair (x+9, y+9) inclusive against a box and require `b[$3b22f]` (a shot was
fired in the crosshair update of the PREVIOUS tick — objects run 7→0, crosshair last) and `ammo != 0`
(tested after the shot's decrement: the last bullet can never kill). On success they switch the object to
its dying handler and play sfx $81, set b[$3b22e] (never read in the tunnels).
```
hit_enemy  $17ba4: box [x..x+30] × [y..y+25] of obj2 → frame=5, e=0, handler=h_enemy_die
hit_water  $17c1c: fixed box [60..100] × [64..110]  → e=3, c=5, handler=h_water_die, frametab=$1e128, x=50, y=64
hit_roomguard $17ca6: fixed box [30..62] × [35..69] → e=0, frame=3, handler=h_roomguard_die   (no score)

h_enemy_walk $17968: hit_enemy; e=(e+1)&3; if e: ret; frame++; if frame==2: handler=h_enemy_aim
h_enemy_aim  $17996: hit_enemy; e++; if e!=15: ret; e=0
                     obj1 = active, x=x-5, y=y+12 (frame/e as left); frame++ (3); handler=h_enemy_fired; sfx $83
h_enemy_fired $179e4: hit_enemy; e=(e+1)&3; if e: ret; frame=2; handler=hit_enemy (just keeps testing)
h_enemy_die  $17a08: e=(e+1)&1; if e: ret; frame++; if frame==8: y+=30, ret; if frame==12: active=0; +300
h_flash      $17936: (byte at +$e) = (+1)&3; if ≠0 ret; frame++; if frame==5:
                     b[$19d57]=0; frame=0; b[$19d56]=0 (obj2 removed!); active=0; player_hit()
h_water      $17a4a: hit_water; e++; if e!=3: ret; e=0; c++
                     if c==4: e=2 ; if c==5: active=0; player_hit(); ret
                     frametab = l[$19d12+4c]; x,y = $19cf2[c]
h_water_die  $17ab4: e=(e+1)&3; if e: ret; c=(c+1)&7; if c==0: active=0; +300; ret
                     frametab/x,y from tables[c]
h_roomguard  $17b0c: hit_roomguard; if b[a3+$10]: ret; e++; if e!=12: ret; e=0; frame++; c++ (word)
                     if c==3: obj1 = active, x=x-5, y=y+12; sfx $83; frame=0; b[a3+$10]=$ff; e=0
h_roomguard_die $17b76: e++; if e!=3 ret; e=0; frame++; if frame==4: handler=$1840e (rts: body stays)
```
Water tables: positions $19cf2 = (35,59),(35,39),(50,29),(35,39),(50,64),(50,64),(57,87),(60,104);
frame entries $19d12 = $1e108,$1e110,$1e118,$1e110,$1e120,$1e128,$1e130,$1e138.

Measured timelines (ticks): far enemy frames 0,1 (4 each) → aim 15 → fire → shot frames 0..4 (4 each) →
player hit ≈ 41-43 ticks after spawn (measured 164 frames); side enemy 15+20 = 35; water enemy 3+3+3+3+1 = 13 ticks.
Once an enemy has fired, killing it does NOT stop the shot: the player is still hit (verified). When the
shot lands it also removes whatever occupies obj2 (e.g. an enemy spawned meanwhile — spawn does not wait
for obj1). Guard: frames 0,1,2 (12 ticks each), fires on the 36th tick, frame 0 again.

### $17d1a player_hit
```
b[$3b22e]=0; sfx $80; msg $20 "YOU'RE HIT"
if b[$3b230]: pos=w[$3b246]; b[$3b230]=0; b[$19d7a]=0; l[$19d88]=0   ; out of the room, still facing it
hits++ (w[a5+4]); f818; flash_red()
if hits==4:
   msg $1b "KILLED IN ACTION"
   if w[$22(a6)]==1: b[$3b235]=$ff
   else: w[$22(a6)]=1; a5=a6+6; $1e(a6)=a5; b[$3b236]=$ff
do { f834; f848 } while w[$48(a6)]            ; wait until all queued messages scrolled
f818; morale_sub($c00); f834; msg 0 "GET GOING !"
```
(Runs inside the object loop; the game is frozen ~110 frames. Morale is reduced also on KIA.)
### $17e60 flash_red / $17ee8 fade_back
```
repeat { f848×3; for 16 colours of $1a012: if R!=$f: R++ ; if G: G-- ; if B: B-- ; f878($1a012) } until no change
if hits==4: return                                           ; screen stays red until the text screen
draw_view; f84c; draw_view; f84c                             ; (bobs are not drawn: view only)
repeat { f848; for each colour: step R/G/B by 1 toward $1a032 (R down, G up, B up); f878 } until equal
```
### $17f6e morale_sub: `w[$2e(a6)] -= d0; if borrow: w[$2e(a6)] = 0` (unsigned).
### $1897a recolour_crosshair
For bob 0 (header at $1e220: 2 words × 18): plane size ps = 4×18; for every word i < ps/2:
`plane1[i] = mask[i]; plane2[i]=plane3[i]=plane4[i]=0` → crosshair in colour 1 ($0aff).

### $17f7c draw_bob(d0 = x<<16|y, a1 = bob) — verified with --reglog
```
bob: long hdr = (w-1)<<16 | (h-1) (w in words); then 5 planes (mask, bp0..bp3), each h rows × w words.
wait blitter; BLTCON0=$0100 BLTCON1=0 BLTAMOD=BLTBMOD=BLTCMOD=BLTDMOD=0 BLTD=$3b742 BLTSIZE=$8c05 ; clear 560×5 words
BLTDMOD=2 BLTCON0=$09f0 (D=A) BLTA=bob+4 BLTD=$3b742 BLTSIZE=(5h)<<6 | w   ; copy, one zero word added per row
dst = $62(a6) + y*40 + l[$3b3f8] + ((x>>3) & $fe); s = x & 15; W = w+1
BLTCMOD=BLTDMOD = 40-2W; BLTCON0 = s<<12 | $0fce; BLTCON1 = s<<12; (AFWM=ALWM=$ffff set by kernel)
for plane p 0..3: BLTA=$3b742 (mask, reloaded), BLTB continues from $3b742+ps*(1+p) (not reloaded),
                  BLTC=BLTD=dst+p*$2000, BLTSIZE = h<<6 | W
```
Minterm $CE: D = B | (¬A & C) (cookie cut). No clipping of any kind.

### Flare-shared routines (specified in re/flare)
`$17810` objects_flare, `$17dd0` player_hit_flare, `$180ee` draw_bob_flare, `$189c0` recolour_flare,
`$18a20/$18a42/$18a98` fade-out (copy palette $5a(a6) to $3b722, decrement every non-zero component
per 3 frames until black and message queue empty, then clear lines 0..143 of both buffers),
`$18afe` cheat_to_flare (flares=9, msg $24), `$18b0e` flare_start, `$18fba`, `$19048..$192c4` flare objects.

---------------------------------------------------------------------------------------------------------
## (c) RAM variables

| addr | size | meaning | init / writers / readers |
|---|---|---|---|
| $1a012 | 16 w | working palette | copy of $1a032 at life start; flash_red |
| $1a08e | 2 l | map cache ptrs $3d182/$3d4a2 | const |
| $1a096 | w | map cache index 0/4 | ^=4 each tick |
| $1a0ae | w | crosshair speed accumulator | spawn=2, combat/room input |
| $1a0b0/$1a0b1 | b,b | player map x,y (read as word x<<8|y) | (21,3) at life start; move_forward, room exit, hit |
| $177b5 | b | SMC: saved map cell under the arrow | draw_map |
| $3b22c/$3b22d | b | left / right view code | draw_view → spawn_enemy |
| $3b22e | b | enemy hit flag (unused in tunnels) | hit_* set, player_hit clear |
| $3b22f | b | combat: shot this tick; room: fire latch | input, hit_* |
| $3b230 | b | in room | move_forward, leave, hit |
| $3b232 | b | walk toggle | in_nav |
| $3b233 | b | walked this tick (sway) | move_forward set, h_crosshair clear |
| $3b235 | b | platoon destroyed | player_hit |
| $3b236 | b | soldier lost → restart | player_hit |
| $3b237 | b | enemy spawn countdown | life start (2..5), main loop |
| $3b238 | b | "ignore fire" latch after leaving room | item_00 |
| $3b23a | b | turn latch (bit2 left, bit3 right) | in_nav |
| $3b23c | w | map flag at section entry | sec1_entry |
| $3b23e/$3b240 | w | room index*2 / room type*2 | move_forward |
| $3b242 | l | room picture | move_forward |
| $3b246 | w | position before entering room | move_forward |
| $3b248 | 25 l | n*$140 | entry |
| $3b2ac | 43 l | n*43 | entry |
| $3b358 | 40 l | n*180 | entry |
| $3b3f8 | l | byte column of left half / room picture (10, or 0 with map) | life start, map pickup |
| $3b3fe | l | byte column of right half (20, or 10) | same |
| $3b402 | 200 l | n*40 | entry |
| $3b742 | 5600 b | bob scratch | draw_bob |
| $3d182.. | 2×360 | map caches (last drawn tile per window cell, per buffer) | life start = $ff |
| $3b222..$3b22a, $3b231, $3b224 | | flare section | re/flare |

---------------------------------------------------------------------------------------------------------
## (d) Data formats (all extracted by extract.py; see assets/)

- Palettes (`assets/palettes.json`): tunnel $1a032 = 000 aff 00a 2af 06f 440 882 020 620 022 ca8 244
  062 a62 466 000 (used for corridor views, rooms, map and bobs); text $1a052; HUD $1a06e = 000 00f f00
  f0f 0f0 0ff ff0 fff 000 000 c66 a60 444 888 840 000.
- View tiles $1a400: 256 × 32 bytes; row r = 4 bytes (plane0..3), MSB = leftmost pixel.
- View tile-maps $1c400: 40 × 180 bytes, row-major 10×18 tile indices; 0..$13 left halves, $14..$27 right.
- Maze $29720: 43×43, cell = y*43+x. 2 corridor, 3 room, anything else = wall (the value is the map
  tile to draw). Map tiles $29220 + v*32 (same tile format); $21..$24 = player arrow N/E/S/W.
  `assets/maze.json` (cells), `maze_map.png` (as drawn), `maze_logic.png` (schematic, rooms numbered).
- Rooms (`assets/rooms.json`, `assets/rooms/`):

| # | entry cell | type | items (hotspot group order; last = EXIT hotspot → leave) |
|---|---|---|---|
| 0 | (8,3) from W | 0 | map, poetry, **flares**, documents, tea, empty, boots, leave (+ guard) |
| 1 | (36,3) from W | 1 | ammo, ammo, medical, weapons, empty, medical, leave |
| 2 | (7,10) from S | 2 | "doesn't work", map, diary, food, drawer, leave |
| 3 | (19,6) from S | 3 | ammo, medical, weapons, empty, exit-blocked, leave |
| 4 | (31,6) from S | 0 | map, handbook, **compass**, documents, tea, empty, medical, leave |
| 5 | (39,10) from S | 1 | ammo, weapons, medical, medical, weapons, medical, leave |
| 6 | (22,19) from E | 0 | map, roman empire, drawer, cards, tea, empty, empty, leave |
| 7 | (31,26) from S | 2 | "doesn't work", map, combat manual, food, drawer, leave |
| 8 | (14,35) from E | 1 | **flares**, empty, medical, weapons, medical, empty, leave |
| 9 | (39,30) from S | 3 | weapons, empty, ammo, medical, **real EXIT ($15)**, leave |

  Tables: $19aec entry cells (x<<8|y), $19a24 type, $19a14 picture per type, $19a38 item list per room
  (words; bit7 = taken), $19b00 hotspot lists per type: `w groups; per group: w nrects, nrects×(x1,y1,x2,y2 bytes)`.
  Type 0 has 8 groups, type 1 seven, types 2/3 six; the last group is always (124,122)-(141,125) "EXIT" label.
- Room pictures: `b width_bytes (20), b height_chars (18)`, then 144 lines × 10 groups of 4 words
  (plane0..3 for 16 pixels). $2a220 type0 (desk/officer room), $2cf22 type1, $2fc24 type2, $32926 type3 (ladder).
- Bobs: frame table entries (8 bytes: long offset from $1e220, long header copy — only the offset is used).
  `assets/frames.json`, `assets/bobs/`. Tunnel sets: crosshair $1e020 (32×18), enemy shot $1e058 (5 frames,
  16×13 → 32×22), corridor enemy $1e080 (frames 0-7 32×49, 8-11 32×17 body in water), room guard $1e0e0
  (5 × 32×34), water enemy $1e108.. (7 entries, 80×72 … 64×18). $1e028/$1e048 belong to the flare section.
- Messages (`assets/messages.json`): 42 entries `x.b, $12, text, $ff`; index = item code for 0..$16.
- Text screens (`assets/textscreens.json`) in resident print format (see re/kernel for control bytes).
- Score constants (BCD, passed by END address to f80c): $1a0a0 = 300 (kill), $1a0a4 = 500 (item),
  $1a0a8 = 30000 (exit).

---------------------------------------------------------------------------------------------------------
## (e) Per-frame flow and timing

- Vblank (level 3, kernel $10eac) decrements `$6a(a6)` while ≥0 (`$68(a6)`=0 in the tunnels, so the
  TIME display stays 00:00 and the counter just stops at −1), sets `$56(a6)`, runs music/sfx.
- main_loop waits (`f848` + `f834` HUD update each vblank) until `$6a<0`, then sets `$6a=3` → one logic
  tick per 4 vblanks = 12.5 Hz (measured: bp $171d8 hits every 4 frames). If a tick takes longer
  (player_hit, text screens, map slide) the next tick starts one vblank after it ends.
- Tick order: draw_map → draw_view (full redraw of view/room area into the draw buffer) → spawn timer →
  objects (handlers+bobs, 7→0) → f84c swap → end-condition checks. Everything is drawn into the back
  buffer `$62(a6)`; the swap becomes visible at the next display frame (level-6 raster int swaps COP1LC).
- Joystick is sampled once per tick in h_crosshair (so inputs shorter than 4 frames can be missed).

## (f) Rendering

- Display (kernel): lowres 320 px, 4 bitplanes, planes $2000 apart, 40 bytes/line, modulo 0,
  DDFSTRT $30, DIWSTRT $3c71, BPLCON1 0 (no scroll). Two buffers $70000/$78000 (copper lists $115d0 /
  $116a8). At VPOS $cc (line 144 of the display) the copper switches bitplanes to $79680.. (HUD, always
  from the $78000 buffer) and loads the HUD palette. So the game area is lines 0..143 of the draw buffer.
  No hardware sprites (DMACON $83c0: no SPREN); the crosshair is a blitter bob.
- Screen layout: view = byte columns $3b3f8..+19 (10..29 = x 80..239 without map; 0..19 with map);
  map window columns 20..39. In the emulator screenshot pixel (0,0) of the bitplanes is at (17,36).
- CPU draws: view halves (tile copy), map tiles, room picture. Blitter: bobs only (6 blits each).
- Palette changes: flash_red/fade_back (player hit), fade-out before the flare section, text palettes.

## (g) Input

| context | up | down | left | right | fire |
|---|---|---|---|---|---|
| corridor | walk 1 cell every 2nd tick (priority) | – | turn left (edge) | turn right (edge) | wastes 1 bullet per tick (sfx $82) |
| combat (enemy/shot alive) | crosshair up | down | left | right | auto-fire 1/tick with recoil |
| room | crosshair (slower) | | | | click hotspot (edge) |
Keys: HELP ($5f) with cheat bit `$71(a6)&2` → jump to flare section with 9 flares.

## (h) Gameplay rules (all verified in emulator unless marked)

- Start of each life at (21,3) facing W with flares 0, no compass, map = as at section entry, all items back.
- Walls block silently. Entering a room keeps facing; leaving turns 180°; hit in a room ejects you facing the door.
- Enemy spawn only in corridors, every 16..65 ticks while no enemy (obj2/obj3) alive; type chosen by view.
- Kill: 300 points (corridor + water enemies); room guard gives nothing. Ammo 144 (HUD bar = ammo/2).
- Hit: morale −$c00 (6 HUD units, 8 units/heart, HUD shows high byte/2), hits+1; 4 hits = soldier KIA;
  2 soldiers. Morale 0 → withdrawn (game over). Items: +500 and/or morale +$200 (see handlers).
- Exit: room 9 hotspot 4 with ≥8 flares (both flare boxes: rooms 0 and 8, +5 each, capped at 8)
  → +30000 → fade → flare section. Compass is not required (only a hint message). Map/compass only
  add HUD/map display.
- Random numbers (f850): spawn delay (&3, &$31), recoil (4×&7).

## (i) Sound calls (f86c sfx / f868 tune)

sfx $80 player hit (player_hit $17d20); $81 enemy hit (hit_* $17c0a,$17c94,$17d0a); $82 shot into empty
corridor ($18398); $83 gunshot (enemy fires $179d8/$17b5e, player combat shot $18f44); 0 hotspot click
($187c2). Tunes: 3 before death/game-over text screens ($17272), 4 after leaving any text screen ($172bc),
6 at flare start ($18b64, re/flare).

## (j) Open questions / uncertainties

- `$0(a5)` = 9 ("grenades"?) is initialised but not shown in this section ($54 set) — owner: jungle/kernel.
- `$28(a6)` HUD icon is refreshed by f808 but never set here.
- Whether `$24(a6)` (map) can arrive already set from section 0 (village) — not tested (poke-boot has 0).
- Morale +$200 has no overflow clamp (word add); unreachable in practice? (not tested).
- Edge cases derived from code but not provoked: new enemy spawned while an old shot is still in flight
  gets erased by h_flash; room enemy kept at frame 4 after death across visits in the same life.
- The cheat enable bit `$71(a6)` is set by the kernel keyboard cheat (see re/kernel).
