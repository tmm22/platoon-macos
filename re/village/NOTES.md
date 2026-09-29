# Platoon (Amiga) — VILLAGE and hut interiors (module `village`)

Author: re/village agent. Scope: the village half of load-section 0 ("THE JUNGLE & VILLAGE SECTIONS",
code $17000..$19fc7, data $19fc8..$1ab49, all in `village.s`): how the jungle connects to the village,
the village street (level 0), hut entry/exit, the hut-interior level (level 5), hut occupants (trap-door
prop, VC guard), the search/item table (torch, map, food..., booby traps), innocent villagers, the trap
door that ends the section, and the bridge logic that gates the village ("SET THE EXPLOSIVES...",
"YOU DID'NT BLOW UP THE BRIDGE..."). The shared section-0 engine (main loop, scrolling, bullets, bob and
tile renderer, generic enemy AI, choose-your-man) is owned by `re/jungle/` — it is summarised here only
as far as the village needs it; see `re/jungle/NOTES.md` for the full pseudocode. Kernel calls ($f8xx)
are described at interface level (see `re/kernel/`).

Conventions: numbers hex. a6 = $12dde always. "tick" = one main-loop iteration = 2 video frames (25 Hz).
`u<`/`u>=` = unsigned compare (bcs/bcc). `rand()` = kernel $f850 (d0 = 0..255). `msg(n)` = kernel $f82c
(queue message n; table $1a6de). `sfx(n)` = kernel $f86c. `score += X` = kernel $f80c with a0 pointing
*past* a 4-byte BCD constant (abcd -(a0),-(a1) into score $4e(a6)..$51(a6)). All claims marked
**[V]** were verified in the emulator; everything else is from the listing.

Files: `NOTES.md` (this), `labels.txt` (rdis labels; base names shared with re/jungle), `village.s`
(annotated listing $17000-$1ab4a), `extract.py` (assets from the ADF → `assets/`), `assets/*`
(renders, emulator screenshots, `village.json`).

---------------------------------------------------------------------------------------------------
## (a) Scope, structure and how to reach it

### a.1 What "the village" is
There is **no separate village load**: section 0 holds one map of 6 "levels" (depth layers) × 3 tile
rows × 90 tile columns ($1b000, $10e bytes per level). Level 1 is the front jungle (start), levels 2..4
are deeper jungle, **level 0 is the top/rearmost layer and contains the village street**, and
**level 5 is the "hut-interior overlay"**: a copy of level 0's village columns with the front walls of
the six huts removed (furniture visible) plus solid wall cells; columns 0..$2c of level 5 are unused
(tile 0). Entering a hut simply switches the displayed/collision level from 0 to 5 at the *same scroll
position* (no scrolling, no screen change other than the redraw).

Village geography (level 0, tile columns = 64-px tiles, `$60c28` = player tile column):
- cols $00..$2e: jungle part of level 0, reachable from level 1 through up-paths; closed on the east by
  a solid tree at col $2f (tile $5c). It does **not** connect to the huts.
- cols $30..$54: **the village street**. Walkable world range $60c30 = $182..$2aa (**[V]** computed from
  the attribute cells and matched by walking). Closed by trees at col $2f and col $55 (tile $53).
- the only access: level 1 col $54 has an up-path tile (3); level 0 col $54 has the matching
  down-path (4). Level 1 col $54 lies east of the bridge (river/bridge tiles $87..$97 on level 1 cols $45..$51; the
  breakable planks are cols $47/$48), so the village can only
  be reached after the bridge logic (§h.9) has been passed = after the bridge has been blown **[V]**.
- 6 huts, door tile columns (table $1aaf4) and interior spans (level 5 wall tiles $70/$71 left, $6f right):

| hut# ($60c40) | door col | $60c30 at door | interior span (cols) | walkable $60c30 inside | occupant / special |
|---|---|---|---|---|---|
| 0 | $31 | $18c | $30..$33 | $18c..$196 | booby trap, TORCH |
| 1 | $37 | $1bc | $35..$39 | $1b4..$1c6 | **trap door** at $1c4 (prop bob $3b) |
| 2 | $3c | $1e4 | $3b..$3e | $1e4..$1ee | **VC guard** (shoots); MAP (after guard dead) |
| 3 | $42 | $214 | $40..$43 | $20c..$216 | rubbish, flour, rice |
| 4 | $49 | $24c | $46..$4a | $23c..$24e | booby trap, provisions, table, stools |
| 5 | $4d | $26c | $4c..$4f | $26c..$276 | flour, stools |

(Walk limits **[V]** for huts 0 and 4 by walking; the others computed with the same rule, §h.3.)

### a.2 Emulator recipes and states (all in `re/states/`, made from `section0_play.state`)
Events in `--script` files **must be sorted by frame** (the emulator processes them sequentially), and
`dumpr` file names are relative to `--out` (an absolute path crashes the emulator, see emulator_issues).
Key names for `key` must be given in hex (`key 0x53 1`, `%i` parsing).

`village_start.state` — level 0, $60c24=$2e, $60c34=0, standing in front of hut 0's door (the first
hut), facing right, frame 1481 (from section0_play.state + 481). Made with the cheat warp F4 whose
immediate was patched to column $2e:
```
1 poke 12e4e 1 2              # $70(a6) = cheat mode on
1 poke 17232 002e0000 4       # F4 warp target (normally $00410000 = col $41, level 0)
150 fire 1                    # leave the choose-your-man screen the state is in
156 fire 0
240 key 0x53 1                # F4 -> sec0_restart with $1a6da = $002e0000
250 key 0x53 0
300 poke 12e4e 0 2            # cheat mode off again (no "CHEAT!" messages)
300 poke 17232 00410000 4     # restore the code
481 save re/states/village_start.state
```
Other states:
| state | content |
|---|---|
| `village_bridge_approach.state` | level 1, $60c24=$41 (F3 warp), bridge ahead; no explosives. Add `1 poke 12e06 ff00 2` to carry explosives |
| `village_entry.state` | level 1, $60c24=$51, c28=$54 (up-path to the village), bridge already blown ($60c9c=2), score 10000. `up 1` enters the village **[V]** |
| `village_hut0.state` .. `village_hut5.state` | inside hut N, standing in the door, 6 ticks after entering (invincibility off) |
| `village_hut1_torch.state` | inside hut 1 with the torch |
| `village_trapdoor_prompt.state` | torch carried, trap-door prompt on screen; `5 key 0x15 1`/`12 key 0x15 0` (Y) ends the section **[V]** |
| `village_trapdoor_notorch.state` | after answering Y without torch ("YOU NEED TO FIND A TORCH") |
| `village_hut2_map.state` | hut 2, guard killed, map taken (HUD map icon) |

Invincibility for experiments: `1 poke 60ca0 ff 1` (same as cheat F5; no "CHEAT!" text while $70(a6)=0).
Example (enter hut 0, step right, take the torch) **[V]**:
```
1 poke 60ca0 ff 1
2 up 1
25 up 0        # state 4 for 10 ticks, then level 5 / state 5
29 right 1
59 right 0     # $60c30: $18c -> $194
64 up 1        # search: "YOU HAVE FOUND A TORCH", +500, morale +$200
67 up 0
```

---------------------------------------------------------------------------------------------------
## (b) Code map (village-specific routines in full; shared routines summarised)

Addresses of all routines/labels are in `labels.txt`; names follow re/jungle where they agree.
Village-specific code: $17a48-$17a87, $17abc-$17e71 (+$17e72-$17ee7), $18632-$1868f, $1880e-$18853,
$19102-$19145, $19c18-$19e09 (explosives/bridge), data $1aaf4-$1ab49.

### b.1 `level_enter` $17a48-$17a87 (called on every level change)
```
d1 = $0ca2
if $60c26 != 0 and $60c26 != 5: d1 = $000d
$1a004 = d1                          ; colour 6 of the playfield palette $19ff8 (village/hut: straw)
if $5a(a6) == $19ff8: kernel $f878(a0=$19ff8)   ; reload upper palette into the copper list
calc_player_pos()                    ; $18980 ($60c28/$60c2c/$60c30/$60cb2/$60c32)
build_attr_map()                     ; $18c86: 7 cols x 3 rows of attribute cells from map[$60c26]+$60c24
```

### b.2 Player state 0 — hut entry part of `pl_st0_walk` $177ca (UP on level 0)
```
; reached when ($60cc1 & 5) == 4 (UP only) and $60c32 == 0
pl_up_pressed ($178e2):
  if $60c26 != 0: goto pl_up_path            ; levels 1..4: up-path tile 3 handling
  if hut_door_check() == fail (d7 != 0): goto pl_start_jump   ; UP elsewhere in the street = jump
  $60c40 = d1 (hut# 0..5)
  $60c38 = $5f886 (facing)
  $60c3a = $18
  $5f89a = 4                                   ; -> pl_st4_enter_hut
```
Note: on level 0, DOWN on tile 4 (cols $4,$11,$15,$1f,$21,$25,$28,$54,$58) goes down to level 1 (state 2);
inside the village that is only col $54 (the way back). Level-0 tile-3 cells (cols $00,$56) are never
used as up-paths (level 0 has no level above).

### b.3 `hut_door_check` $1880e-$18849
```
a0 = $1aaf4 ; d0 = $60c28 ; d1 = 5
repeat: if byte(a0++) == d0.b: break ; d1 -= 1 ; until d1 == -1    (dbeq)
if no match: d7 = $ff ; return
d0 = |$60c34| (abs_d0 $1884a: if d0 >= 0 return d0 (via rts_common) else -d0)
if d0 == 7: d7 = 0 ; return
if d0 u>= 2: d7 = $ff ; return
d7 = 0 ; return                         ; d1 = hut# : $4d->5, $49->4, $42->3, $3c->2, $37->1, $31->0
```
$60c34 is always even (-6..6), so in practice the door is usable only with $60c34 == 0, i.e. at
$60c30 = door_col*8 - 4 ($18c,$1bc,$1e4,$214,$24c,$26c). The comparison is on the low byte of $60c28.

### b.4 Player state 4 — `pl_st4_enter_hut` $17abc-$17b2b **[V]**
```
$5f884 = $60c3c + $11 ; $60c3c = ($60c3c + 1) & 3      ; back-view walk frames $11..$14
      ; NB: the first tick uses the stale $60c3c (normally 0..3)
$5f886 = 0                                             ; facing right during the animation
$60c3a -= 2
$5f882 = $60c3a + $38
if $5f882 u>= $3d: return                              ; y: $4e,$4c,...,$3e (9 ticks)
; 10th tick ($60c3a = 4, y = $3c):
$5f886 = $60c38                                        ; restore facing
enemy_reset()                                          ; $18854: clears $5f888/$5f88e/$5f898 + enemy bullet
                                                       ;   (NOT the enemy x $5f88a -> quirk §h.6)
$5f89a = 5 ; $60c26 = 5
hut_setup_enemy()                                      ; §b.5
goto level_enter                                       ; palette colour 6 stays $ca2, attr map of level 5
```

### b.5 `hut_setup_enemy` $17b2c-$17bc3 (called at entry and by `en_st0_spawn` every tick while
enemy state = 0 on level 5)
```
if $60c40 == 1: goto hut1_trapdoor_place
if $60c40 != 2: return
hut 2 (VC guard):
  $5f890 = 1                          ; faces left (towards the door)
  $5f88e = $33                        ; dead-body frame
  if $60c70 == 0:                     ; guard not yet killed
      $5f88e = $34                    ; aiming frame (bobs $2c,$0e / left: $5f,$4d)
      $5f894 = $f                     ; first shot after 15 ticks
  $5f888 = 4
  $5f88a.l = $00d0003d                ; x = $d0, y = $3d
  $5f88a += -(($60c30 - $1e4) << 3)   ; asl.w #3 then neg: x relative to the door position
  return
hut1_trapdoor_place ($17b96):
  $5f890 = 0
  $60c72.l = $00d0003d ; $60c72 += -(($60c30 - $1bc) << 3)     ; trap-door prop position
  $5f888 = 4                          ; dummy enemy (frame 0 = invisible) -> no random spawns
```
Because the door check forces $60c30 == door position at entry, x is always $d0 at entry.

### b.6 Player state 5 — `pl_st5_in_hut` $17bc4-$17c9b **[V]**
```
$5f880.l = $0094003d                  ; x=$94, y=$3d (every tick)
if $60c32 != 0: goto pl_keep_walking  ; finish an 8-px step in direction $60cc0
if $60c24 == $35 and $60c34 == 0 and $60c32 == 0 and $5f886 == 0:   ; hut 1, trap door, facing right
    trapdoor_prompt()                 ; §b.9 (returns on N, or on Y without torch)
    bset #3,$60cc1 ; bclr #1,$60cc1   ; fake LEFT
    toggle_facing()                   ; $18c7c: $5f886 ^= 1
    kernel $f85c                      ; wait for buffer swap
ih_input ($17c20):
d0 = $60cc1 & 5
if d0 == 0 or d0 == 5: $60cbe = 0 ; goto pl_horizontal ($178ae)   ; walk left/right as outside
if d0 & 4 (UP):
    if $60cbe == 0: hut_search()      ; once per press
    $60cbe = $ff ; $5f884 = $11 ; return
DOWN:
    $60cbe = 0
    if hut_door_check() fails: $5f884 = 8 ; return
    $60c3a = -$e ; $5f89a = 6 ; $60c38 = $5f886 ; return
```
Inside huts: UP = search (never jump), DOWN at the door = leave; no path changes; FIRE works while
$5f884 u< $c (player_fire_input accepts state 5); grenades (SPACE) do not (only state 0).

### b.7 Player state 6 — `pl_st6_leave_hut` $17e72-$17ee7 **[V]**
```
$5f884 = $60c3c + $d ; $60c3c = ($60c3c + 1) & 3     ; front-view walk frames $0d..$10
$5f886 = 0
$60c3a += 2 ; $5f882 = $60c3a + $50                  ; y: $44,$46,...,$4e (7 ticks), then $50
if $5f882 != $50: return
$5f89a = 0 ; $5f884 = 0 ; $60c26 = 0 ; $5f888 = 0 ; $5f88e = 0
$5f886 = $60c38
goto level_enter
```
(The hut state is not remembered separately: re-entering hut 2 re-runs hut_setup_enemy — a live
guard is re-created with a fresh 15-tick timer; a dead guard ($60c70) re-appears as a body.)

### b.8 `hut_search` $17c9c-$17d0b and item handlers **[V]**
```
d0 = $60c30 - $18f                  ; only the low byte is used below
d1 = $13 ; a0 = $1aafa              ; 20 entries {lo, hi, msg, msg_after}
loop:
  push d0,d1,a0
  if byte(a0+0) u>= (d0.b + 1) (8-bit add): skip       ; i.e. require lo <= d0.b, and d0.b != $ff
  if byte(a0+1) u< d0.b: skip                           ; require d0.b <= hi
  sfx(0)                                                ; short beep (AUD0 $8b00, 64 words, per 487) [V]
  push #$17cfa                                          ; handlers "rts" into the msg call below
  if byte(a0+2) == $10: goto item_torch
  if byte(a0+2) == $0f: goto item_booby_trap
  if byte(a0+2) == $17: goto item_map
  pop (discard $17cfa)
  d0 = word(a0+2)                                       ; msg in the high byte ... see note
  msg(d0) ($17cfa: jsr $f82c)                           ; kernel masks d0 with $ff -> msg_after!? see note
skip:
  pop ; a0 += 4 ; dbra d1, loop
```
Note on `move.w 2(a0),d0`: the word is (msg<<8 | msg_after) and kernel $f82c does `andi.l #$ff,d0`,
so the message shown for a plain entry is **msg_after** (byte 3). For all plain entries msg == msg_after,
so this only matters for the two booby-trap entries after they fired: byte 2 is overwritten with byte 3,
both become the "after" message.  The special handlers return a message number in d0 which the
pushed return address feeds into $f82c:
```
item_torch ($17d46):   d0 = 3 ; if $60cbd != 0: return           -> "A POT OF RICE."
                       $60cbd = $ff ; $2e(a6) += $200 (morale) ; score += 500 ($1a6d2..$1a6d5)
                       d0 = 2 ; return                            -> "YOU HAVE FOUND A TORCH"
item_booby_trap ($17d0c):
                       $60c68 = 0 ; $60c6e = 3 ; $60c6a = $5f880 (x) ; $60c6c = $3d   ; explosion anim
                       byte(a0+2) = byte(a0+3)                   ; one-shot (flour / pot of water later)
                       player_hit()                              ; state 8 (skipped if $60ca0)
                       man.hits ($4(a5), a5=$1e(a6)) = 3         ; set AFTER player_hit, unconditional
                       d0 = $f ; return                          -> "A VIET CONG BOOBY TRAP!!"
item_map ($17d74):     d0 = 7 ; if $24(a6) != 0: return          -> "A TABLE." (already have it)
                       if $60c70 == 0: return                    -> "A TABLE." (guard alive)
                       st.b $24(a6) ; kernel $f808 (HUD item icons: map icon appears)
                       $2e(a6) += $200 ; score += 500 ; d0 = 8   -> "YOU HAVE FOUND A MAP"
```
Booby trap outcome **[V]**: hits := 3, and pl_st8_hit adds 1 at the end → hits 4 → "KILLED IN ACTION"
and the choose-your-man screen; morale -$800. With invincibility the hit is skipped but hits is still 3.

### b.9 `trapdoor_prompt` $17dae-$17e71 **[V]**
```
tp_loop:
  read_input()                          ; $19f34 (also kernel HUD tick $f834)
  if $48(a6) == 0: msg($b)              ; keep "HERE IS A TRAP DOOR.... GO DOWN (Y/N)?" queued
  kernel $f85c
  draw_tiles() ; draw_enemy() (draws the trap-door prop) ; $5f884 = 8 ; draw_player()
  kernel $f84c                          ; swap
  if key($36 'N'): goto wait_messages   ; returns to pl_st5 (turn round + step left)
  if !key($15 'Y'): goto tp_loop
  if $60cbd == 0: jmp msg($d)           ; "YOU NEED TO FIND A TORCH" -> returns to pl_st5 (turn + step)
trapdoor_yes ($17e12):
  a5 = $1e(a6) ; d0 = 4 ; d1.l = 0
  repeat 5 times: if hits($4(a5)) u< 4: d1 += $1000 ; a5 += 6        ; NB starts at the CURRENT man
  $60c98.l = d1 ; score += BCD($60c98..$60c9b)     ; a0=$60c9c: +1000 per living man (5 men: 5000)
  dissolve_out() ; read_input() ; jmp kernel $f874 ; section complete -> loads section 1
wait_messages ($17e52): repeat { $f848 x3 ; read_input() } until $48(a6) == 0 ; return
```
While the prompt loop runs the main loop is frozen (no enemies, no morale countdown **[V]**).
Quirk: the living-man count starts at `$1e(a6)` (current man) and walks 5 records forward, so if the
current man is not man 0 it reads past man 4 into a6+$1e.. (kernel globals: $22(a6)/$26(a6)... as "hits").
**[V]** only for man 0 (score 500+5000 = 5500). Port: reproduce literally (count records a5..a5+24).
After Y: dissolve, then "THE TUNNEL SYSTEM / PRESS FIRE TO CONTINUE" (section 1) **[V]**.

### b.10 Hut enemy states / scoring (shared engine, village branches)
```
en_st0_spawn ($180da) on level 5:  goto hut_setup_enemy (no random spawns in huts)
en_st4_in_hut ($1864c):  if $5f88e != $34: return      ; dead body / hut-1 dummy do nothing
                         $5f894 -= 1 ; if != 0: return
                         $5f894 = $19 ; goto en_try_shoot   ; fires every 25 ticks
en_try_shoot ($18458) for state 4: (enemy bullet free and not villager) d1 = 8 -> en_fire:
                         $60c64 = -20 (facing left) ; $60c60.l = ($5f88a,$5f88c) ; $60c62 += 8 (y=$45)
                         sfx($84)                     [V: bullet (d0,45) dx -20, hits 3 ticks later]
                         (if the enemy bullet is still flying, it falls into the walk code ew_step —
                          never happens in practice: the bullet leaves the hut in < 25 ticks)
hit_pbullet ($1768e):    state 4 and $60c70 == 0 -> enemy_shot   (hut-2 guard, and the hut-1 dummy!)
enemy_shot ($176bc):     bullet_kill ; enemy_score ; sfx($80) ; state 3 (dying) with $5f892=$10, frame $1f
en_st3_jumpdown ($1856e):  y = ($60c26==5 ? $3d : $50) - (jump_arc[$5f892] >> 2) while $5f892 counts down
                         frame $1f, then $20 (<6), then $33 (<3)
e3_hut ($18632):         at the end on level 5: $60c70 = 1 ; $5f888 = 4 ; $5f88c = $3d   ; body stays
enemy_score ($1866e):    if $5f898 (villager): msg($17) ; morale_sub($1200) ; return
                         score += 300 ($1a6ce..$1a6d1)
draw_enemy ($19102):     if ($5f89a == 5 or 6) and $60c40 == 1:
                             $60c72 += $60c44 ; $60c36 = 0 ; draw_bob($60c72.l, $3b) ; return  ; trap-door prop
                         (else normal enemy drawing; contact kill only for states 2/5, not villagers)
```

### b.11 Bridge / explosives (gates the village) — `explosives_pickup` $19c18, `bridge_logic` $19cb2
```
explosives_pickup (level 4 only; see re/jungle): at level 4 col $31..$35 an explosives box appears;
    walking onto it: $28(a6) = $ff, msg($10), HUD icon, score += 500.
bridge_logic (every tick, level 1 only):
  if $60c28 in [$45,$4b) and $60c9c == 0 and $48(a6) == 0: msg($11)   ; "SET THE EXPLOSIVES ON THE BRIDGE"
  if $60c28 == $48 and $28(a6) and $60c9c != 2 and $5f89a != $a:     ; PLANT (on the bridge, col $48)
      $60c7c = ($5f880, $50) (bomb object, bob $33) ; $5f89a = $a ; $60c3c = 5 ; $60c9c = 1
      $28(a6) = 0 ; jmp kernel $f808 (HUD icons)                  [V]
  if $60c28 u< $4e: return
  if $60c9c == 0:                                  ; reached col $4e without planting
      if $5f888 == 8: return
      $5f89a = 9                                   ; pl_st9_blocked: player frozen
      if $5f888 == 2: goto enemy_killed_common      ; remove a walking soldier
      return
  if $60c9c == 2: return
bridge_blow ($19dd0):                              ; planted and now at col >= $4e     [V]
  $1b209 = $95 ; $1b20a = $96                      ; level 1 row 2 cols $47,$48 -> broken bridge tiles
  player_hit() ; st.b $60cbc                       ; knock-back (pl_st8 ends without damage)
  $60c9c = 2 ; score += 10000 ($1a6d6..$1a6d9)
```
Doom sequence **[V]**: state 9 → `en_st0_spawn` sees player state 9 → enemy state 8 (runner from the
left, x += 5 per tick; at x u>= $20: x=$21, frame $34, fires 3 shots via the player bullet slots, 2 ticks
apart, dx=+8, bobs $30..$32) → hit_ebullet with player state 9 → player_hit → pl_st8 end → enemy state 8
→ `all_dead` $19d8c:
```
man.hits = 4 ; kernel $f818 ; msg($12 "KILLED IN ACTION") ; dissolve_out() ; kernel $f868(3) (music 3)
kernel $f878($1a018) ; kernel $408($1a970): "YOU DID'NT BLOW UP THE BRIDGE," / "YOUR PLATOON HAS BEEN WIPED OUT!"
wait_fire_press() ($19850) ; jmp kernel $f864 (game over)
```
Suicide guard (in `scroll_step` $189fe, **[V]**): on level 1 with $60c9c == 2, moving right at
$60c30 == $238 or left at $60c30 == $246 → msg($18 "PLEASE DON'T ATTEMPT SUICIDE!!") and no movement
(re-queued every tick while the stick is held; queue max 4). The blown bridge gap is between $238 and $246.
Explosives are only obtainable on level 4 (cols $31..$35), the village only via level 1 col $54.

---------------------------------------------------------------------------------------------------
## (c) RAM variables used by the village (section variables are cleared to 0 at section start,
$5f880..$60fe1; a6 globals persist across sections unless noted)

| addr | size | name | meaning (village use) | writers / readers |
|---|---|---|---|---|
| $12e0c = $2e(a6) | w | morale | decremented every tick; +$200 torch/map/food box; -$800 hit; -$1200 villager | main loop, items, enemy_score |
| $12e02 = $24(a6) | w | map | $ff00 = map found (HUD icon). Cleared at section-0 start. **Carried into section 1**: enables the tunnel map view **[V]** | item_map; section 1 |
| $12e06 = $28(a6) | w | explosives | carried explosives ($ff00) | explosives_pickup, bridge_logic |
| $12e26 = $48(a6) | w | msg queue length (0..4) | trapdoor prompt, bridge msg | kernel |
| $12e2c = $4e(a6) | l | score (BCD) | +300 VC, +500 torch/map/box/explosives, +10000 bridge, +1000/man trap door | $f80c |
| $12dde+6i | 6 | man[i] {grenades, ammo, hits} | booby trap sets hits=3; trap door counts hits u< 4 | |
| $1e(a6) | l | current man ptr | | |
| $5f880/2 | w,w | player x,y | $94,$50 street; $94,$3d in hut; y animates in states 4/6 | |
| $5f884 | w | player frame | $11..$14 enter, $0d..$10 leave, $11 search, 8 stand | |
| $5f886 | w | facing (0 right, 1 left) | | |
| $5f888 | w | enemy state | 4 = hut guard / hut-1 dummy | |
| $5f88a/$5f88c | w,w | enemy x,y | hut guard ($d0,$3d) | |
| $5f88e | w | enemy frame | $34 guard aiming, $33 body, $23..$2a villager walk | |
| $5f890 | w | enemy facing | guard 1 (left) | |
| $5f894 | w | enemy counter | guard shot timer ($f first, then $19) | |
| $5f898 | w (byte $ff) | villager flag | set by spawn on level 0; blocks shooting & contact kill | en_st0_spawn |
| $5f89a | w | player state 0..10 | 4 enter, 5 in hut, 6 leave, 9 doomed, 10 planting | |
| $60c24 | w | T: scroll tile column | trapdoor check T==$35; villager check T u>= $33 | |
| $60c26 | w | level 0..5 | 0 village street, 5 huts | |
| $60c28 | w | player tile column = T + (($60c34+$1b) u>> 3) | door check | calc_player_pos |
| $60c2a | w | copy of level (written with $60c28 as a long) | priority line, bridge | |
| $60c30 | w | player world position, 8-px units = T*8 + $60c34 + $1c (always even) | items, doors | |
| $60c32 | w | $60cb0 & 7 (0 on 8-px boundary) | | |
| $60c34 | w | fine column -6..6 (even) | | |
| $60c38 | w | saved facing (restored after states 4/6) | | |
| $60c3a | w | path/door y offset | $18 enter start, -$e leave start | |
| $60c3c | w | player anim counter | | |
| $60c40 | w | hut# 0..5 (from the door table) | set on entry, read in huts | pl_st0, hut_setup_enemy, draw_enemy |
| $60c44 | w | world x shift this tick (-4/0/+4) | moves prop/enemy with the scroll | |
| $60c68/$6a/$6c/$6e | w | explosion frame / x / y / timer | booby-trap explosion (y=$3d) | item_booby_trap |
| $60c70 | w | hut-2 guard dead (1) | enables the map, guard respawns as body | e3_hut; never cleared except section start |
| $60c72/$60c74 | w,w | trap-door prop x,y (hut 1) | | hut1_trapdoor_place, draw_enemy |
| $60c98 | l | trap-door bonus BCD | | trapdoor_yes |
| $60c9c | w | bridge 0 intact, 1 planted, 2 blown | village reachable only with 2; boxes only drop with 2 | bridge_logic |
| $60ca0 | w | invincibility (cheat F5) | | |
| $60cba | w | sprite priority line: $70 on level 0 when $181 <= $60c30 u< $2aa (street), $60 in huts | main loop |
| $60cbc | b | "knock-back only" flag (bridge blast) | | |
| $60cbd | b | **torch** ($ff) | only gates the trap door; section-local | item_torch |
| $60cbe | b | search latch (one search per UP press) | | pl_st5 |
| $60cc1 | b | input bits: 0 down, 1 right, 2 up, 3 left, 4 space, 7 fire | | read_input |
| $1aafa.. | 80 | item table | booby-trap entries are **patched in RAM** when fired (bytes $1aafc, $1ab30) | item_booby_trap |
| $1b209/$1b20a | b | level-1 bridge tiles ($8c/$8d → $95/$96) | reset to $8c/$8d at section start | |
| $1a004 | w | palette colour 6 ($0ca2 / $000d) | | level_enter |

---------------------------------------------------------------------------------------------------
## (d) Data formats (all extracted by `extract.py` from the ADF; RAM A = ADF (A-$17000)+$1ce00)

d.1 **Map** $1b000: level L, row r (0 top..2 bottom), col c: byte at $1b000 + L*$10e + r*$5a + c = tile
index. Level 0 village cols $2e..$56 and level 5 cols $2d..$59 are in `assets/village.json`
(`village_level0_map`, `hut_level5_map`). Renders: `assets/village_level0.png`, `village_level5.png`
(cols $2a..$59), `village_both.png` (annotated), `hut<N>_interior(_annotated).png`.

d.2 **Tiles** $1c000 + t*$600: 64×48 px, 4 bitplanes plane-sequential, each plane 48 rows × 8 bytes.
**Attribute cells** $5dc00 + t*$30: 6 rows × 8 bytes, one byte per 8×8 px cell; solid iff
value == $b0 or == $da or $c0..$d0 (`solid_at` $19ed2). Hut walls: tiles $70/$71 (left wall, cell 13 = $d0)
and $6f (right wall, cell 0 = $b0), door frame tiles $76/$7d/$7e/$2d (cell 0 = $da).

d.3 **Palette** $19ff8 (16 words): `0000 0a60 00c2 0c40 0620 006f [0ca2] 0060 0682 0ca6 0c64 0c42 08aa 0688
0100 0fff` for levels 0 and 5 (word 6 is $000d in the jungle).

d.4 **Bobs**: directory $55000 (8 bytes per bob: long data offset from $55400, long (W-1)<<16|(H-1));
data = header long + 5 blocks of H rows × W words: block 0 = mask, blocks 1..4 = planes 0..3.
Bob position offsets $1a536 (long dx<<16|dy). **Animation frames** $1a1c6: 128 longs → byte lists of bob
numbers ($ff-terminated), frame+$40 = left-facing. Village frames (`assets/village_frames.png`):
villager walk $23..$2a (bobs $38/$39 + legs $04..$0b), hut guard $34 = {$2c,$0e} / left $74 = {$5f,$4d},
dying $1f={$19,$1a}, $20={$1c,$1d}, body $33={$1e,$1f} / $73={$5d,$5e}, player enter $11..$14, leave $0d..$10.
Trap-door prop = **bob $3b** (32×6, drawn directly).

d.5 **Door table** $1aaf4: `4d 49 42 3c 37 31` (hut 5..0).

d.6 **Item table** $1aafa: 20 × {lo, hi, msg, msg_after}. Matching uses d0.b = ($60c30-$18f) & $ff with
lo <= d0.b <= hi (unsigned) and d0.b != $ff. Since $60c30 is always even, d0 is always odd: only odd
values in [lo,hi] can match. Decoded (c30 = player $60c30 values that trigger it):

| # | lo-hi | msg | effect | reachable $60c30 | hut |
|---|---|---|---|---|---|
| 0 | 00-01 | $0f/$01 | BOOBY TRAP, then "A SACK OF FLOUR." | $190 | 0 |
| 1 | 04-06 | $10 | TORCH (then "A POT OF RICE.") | $194 | 0 |
| 2 | 24-25 | $04 | RUBBISH. | $1b4 | 1 |
| 3 | 26-28 | $03 | A POT OF RICE. | $1b6 | 1 |
| 4 | 2a-2b | $05 | A STOOL. | $1ba | 1 |
| 5 | 30-31 | $06 | EMPTY. | $1c0 | 1 |
| 6 | 59-5a | $05 | A STOOL. | $1e8 | 2 |
| 7 | 5d-60 | $17 | MAP (needs guard dead) else "A TABLE." | $1ec,$1ee | 2 |
| 8 | 6b-60 | $07 | A TABLE. — lo > hi: **never matches** (data bug) | — | (2) |
| 9 | 7d-7e | $04 | RUBBISH. | $20c | 3 |
| 10 | 7f-80 | $01 | A SACK OF FLOUR. | $20e | 3 |
| 11 | 81-83 | $03 | A POT OF RICE. | $210,$212 | 3 |
| 12 | ac-ad | $09 | PROVISIONS | $23c | 4 |
| 13 | ae-b0 | $0f/$0a | BOOBY TRAP, then "A POT OF WATER" | $23e | 4 |
| 14 | b2-b2 | $05 | A STOOL. — even only: **unreachable** | — | 4 |
| 15 | b3-b8 | $07 | A TABLE. | $242,$244,$246 | 4 |
| 16 | b9-b9 | $05 | A STOOL. | $248 | 4 |
| 17 | e0-e1 | $01 | A SACK OF FLOUR. | $270 | 5 |
| 18 | e2-e3 | $05 | A STOOL. | $272 | 5 |
| 19 | e6-e7 | $05 | A STOOL. | $276 | 5 |

Positions not in the table give nothing (no message). Only torch/map/booby traps have effects; food,
rice, water, flour, provisions are flavour text only. "MEDICAL SUPPLIES", "A FOOD PACKAGE", "A BOX OF
VIET CONG AMMUNITION", "AN EMPTY BOX" come from supply boxes dropped by killed VCs (crate_open $19e0a:
rand&3: 0 ammo +$48 (cap $90), 1 medical morale +$300 and hits-1, 2 food, 3 empty; 0..2 also morale +$200
and +500 pts), which only drop after the bridge was blown — i.e. in the village area.

d.7 **Messages** $1a6de: 25 pointers → {x char column, y row ($12 = HUD message line), text, $ff}; full
list in `village.json`. Village ones: 0..$d, $f, $12, $17 (villagers), $b (trap door prompt), $d (torch
needed), $10/$11 (explosives/bridge), $18 (suicide). Direct strings via kernel $408: $1a970 (wiped out),
$1a967 (attribute reset printed every tick).

d.8 **Screen mapping (for validating renders)**: in the emulator canvas, world pixel X of the current
level (X = column*64 + px) is shown at canvas x = X − $60c24*64 − $60c34*8 + $60cb0 − 47, play-area
row y at canvas y = y + 36 (the $60cb0 term inferred from two shots with $60cb0 = 0 and 8). **[V]** 100% pixel match of `render_level(5, ...)` against a hut-4 screenshot
(player sprite columns excluded), 99.5-99.7% on hut 1/3 shots (difference = sprites).
Player visible sprite spans world x = $60c30*8−11 .. $60c30*8+9.

---------------------------------------------------------------------------------------------------
## (e) Per-frame flow
Same main loop as the jungle (`main_loop` $17186, see re/jungle §b.2): logic runs once per 2 frames
(25 Hz) **[V]** (bp at $17186 hit every other frame; buffer swap $f84c at raster line ~$fd, then the loop
waits in $f85c for the level-6 raster IRQ to switch copper lists). Order per tick: tick++ → read_input →
spawn-chance decay → (keys) → $f85c → $60c44=0 → player state handler → player_fire_input → enemy
state handler → priority line → draw_tiles → trap_spawn → explosives_pickup → bridge_logic → crate_open →
trap_update → bomb_update → crate_update → draw_enemy → bullets_update → explosion_update → draw_player
→ $f84c → BPLCON1 value → morale -= 1 (0 → game over).
Village specifics: in state 5 the trap-door prompt runs its own render loop (§b.9, 1 frame per 2
vblanks via $f85c/$f84c, no game logic). Morale decreases 1 per tick everywhere (≈25/s).

## (f) Rendering (village specifics)
- Levels 0 and 5 use the same 4-bitplane 320×144 double-buffered playfield ($70000/$78000, plane stride
  $2000, 40 bytes/row) and tile blits as the jungle (`draw_tiles` $18cf4: clear, then 5-6 tile columns ×
  3 rows of 64×48 blits A→D, BLTSIZE $c04, D modulo $20; partial edge columns when $60c34 != 0).
- Palette colour 6 = $0ca2 on levels 0/5 (hut straw/wood) instead of $000d (jungle blue) — `level_enter`.
- Priority line $60cba = $70 on the village street ($181 <= $60c30 u< $2aa on level 0), $60 in huts and the
  west part of level 0 (bob pixels below the line are masked by the foreground; see re/jungle §f).
- Extra bobs: trap-door prop bob $3b (hut 1 only, drawn instead of the enemy in states 5/6), hut guard /
  body frames, villager frames, explosion bobs $34..$37 (booby trap), supply box bob $3a.
- The hut interior is just a different level: no special display setup; the outside of the hut stays
  visible around it (see `assets/emu_huts_inside_montage.png` = emulator shots of all six huts).

## (g) Input semantics in the village
Joystick port 2: DOWN bit0, RIGHT bit1, UP bit2, LEFT bit3, FIRE bit7; SPACE = bit4 (grenade).
- Street (state 0): LEFT/RIGHT walk (first press only turns), UP at a door (|$60c34|=0 and $60c28 = door
  col) = enter hut; UP elsewhere = jump; DOWN at col $54 (tile 4) = go down to level 1; DOWN elsewhere =
  crouch; FIRE = shoot (auto-fire every 2 ticks), SPACE with no direction = grenade.
- Hut (state 5): LEFT/RIGHT walk inside the walls; UP = search (once per press, frame $11); DOWN at the
  door = leave; FIRE = shoot (only if frame u< $c); no jump, no grenade.
- Trap-door prompt: Y (raw $15) / N (raw $36); everything else frozen.
- Left-Alt ($64) = change man; only while enemy state == 0, so it works in huts 0/3/4/5 but not in huts 1/2
  (their occupant/dummy is enemy state 4).

## (h) Gameplay mechanics
h.1 **Getting there**: level 1 → plant explosives at col $48 (having picked them up on level 4) → walk
right (forced, state 10) → at col $4e the bridge blows (+10000) → col $54 UP → level 0 village (east end)
**[V]**. Without explosives, col $4e dooms the platoon (§b.11) **[V]**.

h.2 **Village street**: enemies spawn as in the jungle with these level-0 rules (`en_st0_spawn`):
no tree snipers (level 0 excluded); spider-hole VC only where the row-2 tile two columns ahead is < 5 and
!= 2 (never on the street tiles $1b..$60; possible at cols $54+); tripwires likewise not on the street;
walking figures: speed 5 or 6, from the left (x=1) or right (x=$130) edge; **if level == 0 and
$60c24 u>= $33 and (rand() & 2): villager** (frames $23.., $5f898=$ff) **[V]**. Spawn chance per tick:
rand() u< $60cae ($60cae ≥ 7, +8 per shot, +$20 per grenade, decays 1/tick).

h.3 **Walls/doors**: moving right is blocked if the attribute cell at world cell ($60c30+2) is solid,
left if cell ($60c30−4) is solid (cells of tile row 1, cell row 2 in huts (y=$3d → probe y $45), cell
row 5 on the street (probe y $58)); checked on 8-px boundaries. Walk ranges in §a.1 follow from this.

h.4 **Huts**: see §b.4-b.10. Hut 2's guard fires 15 ticks after you enter, then every 25 ticks,
bullets at −20 px/tick from x=$d0, hit at the player's x-range regardless of y **[V]**; you face right
(towards him) on entry, so shoot at once. Killing him: +300, $60c70=1 → map becomes available at
$60c30 $1ec/$1ee. Re-entering hut 2 with a live guard re-creates him with a fresh timer.

h.5 **Innocent villagers**: they never shoot and don't kill by contact; shooting one: msg $17,
morale −$1200 (clamped at 0 → game over), no score **[V]**. Grenades also kill them (hit_grenade
state 2) with the same penalty. Killed villagers never drop boxes.

h.6 **Quirk — the hut-1 dummy can be shot** **[V]**: on entering hut 1 the dummy enemy (state 4, frame 0)
keeps the stale enemy x $5f88a of whatever walked in the street. A player bullet whose path covers
[$5f88a, $5f88a+$18) "kills" it: +300 points, invisible dying animation, and at the end `e3_hut` sets
**$60c70 = 1**, i.e. the hut-2 guard is considered dead (he appears as a body, the map can be taken
without fighting). Reproduced by `1 poke 5f88a 9c 2` + fire right in `village_hut1.state` (naturally the
stale x was $9c in one run).

h.7 **Booby traps** (hut 0 at $190, hut 4 at $23e): searching there kills the current man (§b.8); one-shot.

h.8 **Ending**: trap door in hut 1 at T=$35, $60c34=0, facing right — the prompt appears by walking onto
it facing right. Y requires the torch (hut 0); bonus = 1000 per living man; section 1 (tunnels) follows.
The map (hut 2) is optional: it shows the tunnel maze map in section 1 **[V]**
(`assets/emu_tunnel_without_vs_with_map.png`).

h.9 **Bridge messages**: "SET THE EXPLOSIVES ON THE BRIDGE" while $60c28 in [$45,$4b) on level 1 with
the bridge intact and no message showing (repeats); planting at col $48; blast at col >= $4e;
"PLEASE DON'T ATTEMPT SUICIDE!!" at the gap afterwards; "YOU DID'NT BLOW UP THE BRIDGE, YOUR PLATOON HAS
BEEN WIPED OUT!" if you walk past col $4e without planting (game over, all men lost).

h.10 **Random numbers**: kernel $f850: 32-bit state $12d70; 8 times { if bit31: state ^= $0076b553;
state = rol(state,1) }; return state & $ff. Used by spawns (villager bit 1), box contents (&3), box drop
(&3), enemy turning/firing.

## (i) Sound / music calls in the village code
| call site | id | when |
|---|---|---|
| $17ccc hut_search | sfx 0 | every matching search spot (short beep, AUD0 sample $8b00 len 64 words period 487) **[V]** |
| $1777e player_hit | sfx $81 | booby trap, guard bullet, bridge blast knock-back |
| $176c8 enemy_killed_common | sfx $80 | guard / villager / VC killed |
| $1850a en_fire | sfx $84 | guard shot ($18502: sfx $a for the bridge runner) |
| $17422 pf_fire | sfx $82 | player shot |
| $1767a bullet_kill (grenade) / $18ff6 trap | sfx $85 | explosions (booby-trap explosion anim itself is silent) |
| $19daa all_dead | music 3 (kernel $f868) | "wiped out" |
| $1717c sec0_restart | music 2 | in-game tune |

## (j) Open questions / uncertainties
- Trap-door bonus loop starting at the current man (§b.9) — behaviour for man != 0 not verified.
- Item #8 ($6b..$60) and #14 ($b2) are dead entries (probably data bugs); whether the table (and the
  booby traps patched in RAM) is re-loaded from disk on a new game depends on the kernel reloading
  section 0 (not verified here).
- `move.w 2(a0),d0` + kernel `andi.l #$ff` means plain entries display byte 3 (msg_after); equal to byte
  2 for all plain entries, so no visible effect (inferred from the kernel code at $10720).
- re/jungle §b.7 states the bullet x-range test as `lo u>= t and hi u< t+$18`; from the code at $17788
  it is `max(old,new) u>= t and min(old,new)+4 u< t+$18` (verified by the hut-1 dummy hit with t=$9c:
  old $98, new $a2 → hit). Please reconcile.
- The villager check uses $60c24 (scroll column), not the player column: villagers only from T >= $33.
- The HUD "TIME 00:00" is static in section 0 (no clock logic here).
