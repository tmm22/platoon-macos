# Platoon (Amiga) — Section 0 engine + JUNGLE  (module `jungle`)

Author: re/jungle agent. Scope: everything executed from the section-0 code block ($17000-$19fd8) —
the shared section-0 engine (main loop, player/enemy state machines, bullets, tile renderer, bob
renderer, scrolling, collision, input) and the jungle content (paths, VC soldiers, tree snipers,
spider-hole VC, booby traps, grenades, supply boxes, explosives, the bridge, game-over at the bridge).
The village-specific parts (hut entry, hut interiors, item search table, trap door) are shared code
in the same block; they are documented here at pseudocode level too (routines `pl_st4..6`,
`hut_*`, `item_*`, `trapdoor_*`), the `village` agent owns their gameplay interpretation.
Kernel ($f800-$12dde) routines are only described at interface level (see re/kernel/).

Everything below was derived from the listing `jungle.s` (rdis with `labels.txt`) and verified
experimentally where marked **[verified]**. Numbers are hex unless decimal is obvious.

Files in this directory
- `NOTES.md` — this spec.
- `labels.txt`, `jungle.s` — annotated recursive-descent listing of code $17000-$19fd7 plus the section
  tables up to $1b000 (regenerate: `python3 ../../tools/rdis.py ../dumps/ram_section0.bin 17000 1b000
  --cov ../cov/section0.hist --labels labels.txt --follow-hi 19fd8 > jungle.s`). v_/d_/k_ labels name
  variables, data and kernel entry points in operands.
- `render_test.sh` — reproduces the renderer validation (§f.6).
- `extract.py` — pulls all section-0 assets from `re/platoon_darc.adf` into `assets/`.
- `render_sim.py` — blit-exact Python re-implementation of `draw_tiles` ($18cf4) and `draw_bob`
  ($1920a) with a small blitter model; validated byte-for-byte against the emulator (see §f.6).
- `probe.py` — helper: run the emulator with a script and sample the game variables every N frames.
- `assets/` — map_full.png (whole map), map_level0-5.png, map_attr_full.png, tiles.png, tile_attr.png,
  bobs.png/json, frames.png/json, palettes.png/json, map.json, messages.json, tables.json.

---------------------------------------------------------------------------------------------------
## (a) Scope, and how to reach it in the emulator

Section 0 = disk tracks $15..$4c (56 tracks) loaded **uncompressed, 1:1** to $17000-$63fff
(RAM A == ADF offset A-$17000+$1ce00). Only the variable area $5f880-$60fe1 and the colour word
$1a005 differ from disk at run time. The section runs from `jmp $17000` (kernel $fd48).

States (all in `re/states/`):
| state | what | how made |
|---|---|---|
| `jungle_start.state` | first main-loop iteration of a fresh game (pc=$17186, frame 813 of boot), level 1, T=5, men full, nothing on screen | boot script below + `800 breaksave 17186 ../states/jungle_start.state` |
| `jungle_warp.state` | section init just after `move.l $1a6da,$60c24` (pc=$1707a). Poke `$60c24` (long = xtile<<16 \| level) at frame 0 to start anywhere | boot script + `700 breaksave 17070 ../states/jungle_warp.state` |
| `section0_play.state` (shared) | frame 1000 — NOTE: the player is already being hit (state 8) in it; prefer jungle_start | |

Boot script (frames absolute from power-on; **events must be sorted by frame**, the emulator
processes the script sequentially):
```
300 fire 1
305 fire 0
350 poke 12e4c 0 2
600 fire 1
605 fire 0
800 breaksave 17186 ../states/jungle_start.state
```
Useful pokes: `1 poke 60ca0 ff 1` = invincibility (same as cheat F5); `0 poke 60c24 00520004 4`
from jungle_warp.state = start at x tile $52 on level 4.  Examples used during RE:
```
# walk right from the start and take the first down-path (col 13) to level 2   [verified]
1 poke 60ca0 ff 1
2 right 1
166 right 0
168 down 1
200 down 0
```

---------------------------------------------------------------------------------------------------
## (b) Code map

Conventions: `a6` = $12dde (kernel globals) throughout. `rand()` = kernel $f850 (returns d0 = 0..255,
see §h.10). `sfx(n)` = `jmp $f86c` with d0=n. `msg(n)` = kernel $f82c (queue message n of the table
at $4a(a6)=$1a6de). "tick" = one main-loop iteration (= 2 video frames, §e).
Signedness: all positions are 16-bit words; comparisons marked `u<`/`u>=` are unsigned (bcs/bcc),
`s<` signed. Most range checks in this code are unsigned, which makes negative x values count as huge.

### b.1 Section init — `sec0_start` $17000-$1706c, `sec0_restart` $17070-$17184
```
sec0_start:
  SP = $400
  *( *$f888 ) = $3c81      ; $115f6 = DIWSTRT value in the shared copper tail (playfield window)
  *( *$f88c ) = $0088      ; $1165e = BPLCON1 of the HUD part (fixed delay 8/8, see §f)
  clear bytes $5f880..$60fe1  ($1762 bytes: every section variable below = 0 unless set)
  $60cb0 = 8                ; fine-scroll counter
  $1b209 = $8c, $1b20a = $8d   ; repair the bridge in the map (level 1, row 2, cols 71/72)
  $5f896 = 6                ; enemy speed
  $34(a6) = $19fd8          ; message colour-fade table (8 longs) for the kernel message system
  $4a(a6) = $1a6de          ; message text pointer table (25 messages)
  clr.w $24(a6),$26(a6),$2c(a6),$28(a6),$54(a6)   ; carried items (map, ?, ?, explosives, alt-ammo)
sec0_restart:                ; also target of the F1-F4 cheat warps
  $60c24.l = $1a6da.l       ; start pos: word x-tile T, word level  (disk: $0005,$0001)
  kernel $f880(d0=$8f)      ; HUD split: HUD bitplanes at $78000+$90*40, raster IRQ at line $cb/$cc
  kernel $f878(a0=$19ff8)   ; upper (playfield) palette
  kernel $f87c(a0=$1a038)   ; lower (HUD) palette = all black (faded in below)
  $1e(a6) = a6 ; $22(a6) = 0                ; current man = man 0
  for i in 0..4: man[i] = {+0 grenades: 9, +2 ammo: $90, +4 hits: 0}   ; at a6+6*i
  $f854 fill: $60cc2[0..199] = i*40 (long)            ; row offset table
  $f854 fill: $5f89c[0..5]   = $1b000 + i*$10e       ; map level pointers
  $f854 fill: $5f8b4[0..151] = $1c000 + i*$600       ; tile graphics pointers
  $f854 fill: $5fcb4[0..151] = $5dc00 + i*$30        ; tile attribute pointers
  kernel $f840 (clear both screens $70000,$78000) ; $f84c (swap) ; $f830 (full HUD redraw)
  kernel $f870(a0=$1a018, a3=$5e(a6), a4=$f87c)  ; fade HUD palette in (16 steps, 2 frames each)
  kernel $f878(a0=$19ff8)
  level_enter()                    ; §b.9
  kernel $f85c (wait swap done)
  draw_tiles()                     ; into back buffer
  backbuf_to_68000()               ; $1988a
  dissolve_in()                    ; $19926 (8 steps)
  kernel $f868(d0=2)               ; start in-game music 2
  fall into main_loop
```
Note: every restart (also cheat warp) re-initialises all 5 men.

### b.2 Main loop — `main_loop` $17186-$1734e
```
main_loop:
  ($60cb4).l += 1                       ; tick counter; bit0 of byte $60cb7 paces walk animation
  read_input()                          ; $19f34 (also runs kernel HUD update $f834)
  if $60cae u< 8: $60cae = 8
  $60cae -= 1                           ; enemy "noise"/spawn chance decays to minimum 7
  if key($64 = Left-Alt) and enemy_state($5f888)==0:        [verified]
      dissolve_out(); man_select()      ; voluntary change of soldier
  if $70(a6) != 0 (cheat mode):         ; keys F1..F6 = raw $50..$55
      F1: $1a6da.l=$00050001 ; goto sec0_restart     (x5, level1  = start)
      F2: $1a6da.l=$002d0004 ; goto sec0_restart     (x45, level4)
      F3: $1a6da.l=$00410001 ; goto sec0_restart     (x65, level1, before the bridge)
      F4: $1a6da.l=$00410000 ; goto sec0_restart     (x65, level0, village)
      F5: st.b $60ca0 (invincible)   F6: clr.w $60ca0
ml_frame:
  kernel $408(a0=$1a967)                ; text-attribute reset string (no visible text)
  kernel $f85c                          ; wait until the previous buffer swap happened
  $60c44 = 0                            ; world x-shift of this tick
  call player_state_table[$5f89a]       ; $1aaa4: 11 handlers (§b.4)
  player_fire_input()                   ; $1736a
  call enemy_state_table[$5f888]        ; $1aad0: 9 handlers (§b.6)
  -- priority line (legs hidden behind foreground bushes below this y):
  d2 = $60
  if $60c2a==1 and $1d0 <= $60c30 u< $2b1: d2 = $80     ; level 1 river/bridge stretch
  elif $60c2a==0 and $181 <= $60c30 u< $2aa: d2 = $70   ; level 0 village street
  $60cba = d2
  draw_tiles()            ; $18cf4   clear back buffer + background
  trap_spawn()            ; $19b72
  explosives_pickup()     ; $19c18
  bridge_logic()          ; $19cb2
  crate_open()            ; $19e0a
  trap_update()           ; $18f82   (draws)
  bomb_update()           ; $19094   (draws)
  crate_update()          ; $190ca   (draws)
  draw_enemy()            ; $19102   (also contact kill)
  bullets_update()        ; $174d2   (moves, collides, draws)
  explosion_update()      ; $18870   (draws)
  draw_player()           ; $191be
  kernel $f84c            ; toggle $62(a6), request copper-list swap at the HUD split
  $72(a6) = $60cb2*$11    ; BPLCON1 (both playfields) — latched into the copper list by the level-6 IRQ
  if $2e(a6) (morale) != 0: $2e(a6) -= 1; if != 0 goto main_loop
sec0_exit ($17350): clr.w $60ca0 ; jmp kernel $f864 (game over sequence)
```
So morale drops by 1 every tick; when it reaches 0 the game is over (§h.7).

`morale_sub` $1735c (d0): `$2e(a6) -= d0; if borrow: $2e(a6)=0`. No overflow check on the
additions elsewhere (`add.w d0,$2e(a6)`), so morale can wrap past $ffff (quirk, unlikely in play).

### b.3 Input — `read_input` $19f34
```
kernel $f834                           ; per-tick HUD refresh (score, bars, clock)
d0 = joy()  ($410: bit0 down, bit1 right, bit2 up, bit3 left, bit7 fire; port 2)   [verified]
$60cc1 = d0 & $8f
if key($40 = SPACE): bset #4,$60cc1
if $70(a6) and $60ca0 and $48(a6)==0: msg($16 "CHEAT!")   ; shown while invincible
```
Keys used by section 0: Space ($40, grenade), Left-Alt ($64, change man), F1-F6 ($50-$55, cheat only),
N ($36) / Y ($15) at the trap-door prompt. Kernel: Tab ($42) = pause, F10 ($59) = music/sfx toggle.

### b.4 Player state machine ($5f89a, table $1aaa4)
| state | handler | meaning |
|---|---|---|
| 0 | `pl_st0_walk` $177ca | standing / walking / crouch; starts jump, path change, hut entry |
| 1 | `pl_st1_jump` $17918 | jump (16 ticks) |
| 2 | `pl_st2_down` $17986 | walk down a side path to level+1 |
| 3 | `pl_st3_up` $179e6 | walk up a side path to level-1 |
| 4 | `pl_st4_enter_hut` $17abc | (village) walk into hut door |
| 5 | `pl_st5_in_hut` $17bc4 | (village) inside hut, level 5 |
| 6 | `pl_st6_leave_hut` $17e72 | (village) walk out of hut |
| 7 | `pl_st7_throw` $17ee8 | grenade throw animation |
| 8 | `pl_st8_hit` $17f56 | hit / dying |
| 9 | `pl_st9_blocked` $18050 | frozen at the un-blown bridge (doomed) |
| 10 | `pl_st10_plant` $18076 | planting the charge, then forced walk right |

**pl_st0_walk** $177ca
```
$5f880.l = $00940050            ; x=$94, y=$50 — the player never moves on screen, the world scrolls
if $60c32 != 0: goto pl_keep_walking        ; not on an 8-px boundary: finish the step
v = $60cc1 & 5                  ; vertical bits (down=1, up=4)
if v==0 or v==5: goto pl_horizontal
a0 = $60c2c                     ; map byte of bottom tile row under the player
if v & 1 (DOWN):
    if (a0)==4:                 ; down-path tile
        d = |$60c34|; if d u< 3 or d u>= 6:        ; i.e. $60c34 in {0,±2,±6}
            $60c38 = facing; state = 2; $60c3a = 0; $60c3c = 0; $60c32 &= 8 (->0); return
    frame = $a (crouch); return   ; pl_crouch: no movement while crouching
UP (pl_up_pressed):
    if level ($60c26) == 0:     ; top level: hut doors instead of paths
        if hut_door_check()==ok: $60c40 = hut#; $60c38=facing; $60c3a=$18; state=4; return
        goto pl_start_jump
    if (a0)==3:                 ; up-path tile
        d = |$60c34|; if d u< 3 or d u>= 6:
            $60c38 = facing; state = 3; $60c3a = $ffff; $60c32 = 0; return
pl_start_jump:
    $60c3c = 0; state = 1; $60cbf = $60cc1          ; remember input (direction) at take-off
pl_horizontal:
    h = $60cc1 & $a  (right=2, left=8)
    if h==0 or h==$a: frame = 8 (stand); return      ; pl_stand_frame
    $60cc0 = h; goto pl_move(h)                      ; $1896e
pl_keep_walking: h = $60cc0; same as pl_horizontal from the test on h
```
**pl_move** $1896e (d0 = direction bits; `d6 = 4` pixels):
```
if $60c5c != 0: return            ; cannot walk while own grenade is in the air (grenade y != 0)
scroll_step(d0, d6)               ; $189fe
calc_player_pos()                 ; $18980
```
**scroll_step** $189fe:
```
if d0 & 8 (LEFT): goto scroll_left_chk
RIGHT:
  if facing != 0: toggle facing; return             ; first press only turns round
  if $60c9c==2 and $60c2a==1 and $60c30==$238: msg($18 "PLEASE DON'T ATTEMPT SUICIDE!!"); return
  if $60c32==0: probe ($5f880+$20, $5f882+8) = ($b4,$58); if solid_at(): frame=8; return
  $60c44 = -4                                     ; all world objects move 4 px left this tick
  if byte $60cb7 bit0: frame = (frame+1) & 7      ; walk cycle 0..7, one step every 2 ticks
  $60cb0 = ($60cb0 - d6) & $f
  if $60cb0 != $c: return
  $60c34 += 2
  if $60c34 u< 8 or $60c34 u>= $fff9: return      ; still inside -6..+6
  $60c34 = 0 ; $60c24 += 1
  shift attribute window left 8 bytes: for 18 rows copy bytes [8..55] -> [0..47]  ($600bc->$600b4)
  attr_copy_cols(a0=$600e4, a1=map[level]+$60c24+6, 1 column x 3 rows)
LEFT (scroll_left_chk / scroll_left):
  if facing == 0: toggle facing; return
  if $60c9c==2 and $60c2a==1 and $60c30==$246: msg($18); return
  if $60c32==0: probe ($5f880-$10, $5f882+8) = ($84,$58); if solid: frame=8; return
  $60c44 = +4 ; walk anim as above
  $60cb0 = ($60cb0 + d6) & $f ; if != 0: return
  $60c34 -= 2 ; if $60c34 u< 8 or u>= $fff9: return
  $60c34 = 0 ; $60c24 -= 1
  shift attribute window right 8 bytes (backwards copy, 18 rows) ; new column 0 from map[level]+$60c24
```
There are **no map-edge checks**: the level edges are closed only by trees (solid cells).
Walking past column 89 would read the next map row (verified by warping past a tree).

**calc_player_pos** $18980:
```
$60c28.l = $60c24.l                         ; copies T and level into $60c28/$60c2a
$60c28 = $60c24 + (($60c34 + $1b) u>> 3)    ; player tile column (lsr on the 16-bit sum)
$60c2c = map[$60c26] + $60c28 + $b4         ; bottom-row (row 2) map byte under the player
$60c30 = $60c24*8 + $60c34 + $1c            ; player world position in 8-px units (0..719)
$60cb2 = ($60cb0 + $10) & $f                ; == $60cb0
$60c32 = $60cb2 & 7                         ; 0 when on an 8-px boundary
```
**pl_st1_jump** $17918:
```
d0 = ($60cc1 & $b5) | $60cbf ; $60cc1 = d0       ; horizontal bits frozen at take-off
h = d0 & $a ; if h is exactly one direction: pl_move(h)
frame = $c
$5f882 = $50 - jump_arc[$60c3c]                  ; jump_arc $1a194 = 8,15,22,28,33,37,39,40,39,37,33,28,22,15,8,0
$60c3c = ($60c3c+1) & $f ; if 0: state = 0, frame = 0
```
**pl_st2_down** $17986 / **pl_st3_up** $179e6 (path change, 24 ticks total)  **[verified]**
```
st2: $60c3c=($60c3c+1)&3; frame = $60c3c+$d (13..16, walking towards camera); facing = 0
     $60c3a += 2; if $60c3a==0: goto pl_path_done
     y = $60c3a + $50; if y u< $68: return
     $60c3a = -$18; $60c26 += 1; goto pl_level_changed
st3: frame = $60c3c+$11 (17..20, back view); $60c3a -= 2; if 0: pl_path_done
     y = $60c3a + $50; if y u>= $38: return
     $60c3a = $18; $60c26 -= 1; goto pl_level_changed
pl_level_changed ($17a3c): enemy_reset(); kill_player_bullets(); trap_clear(); level_enter()
pl_path_done ($17aa4): facing = $60c38; state = 0; frame = 0
```
(st3 starts at $60c3a=$ffff so it never hits 0 before the level switch.) Observed: y $52..$66 on the
old level, switch, y $3a..$4e on the new one, then state 0 at y=$50.

**pl_st7_throw** $17ee8: `$60c3c--; if !=0 return; $60c3c=2; frame++; if frame==$30: grenade_launch;
if frame u>= $31: frame=8, state=0`. Frames $2f,$30 two ticks each.
`grenade_launch` $17f28: grenade $60c5a = {y=$50, x=$98, dx=+$e} (facing right) or {x=$90, dx=-$e}.

**pl_st8_hit** $17f56 (entered via `player_hit`, $60c3c=$10, frame $31):
```
if $60c3c != 0:
   i = $60c3c ; $60c3c -= 1
   base = ($60c26==5) ? $3d : $50
   y = base - (jump_arc[i] >> 2)       ; i=16 reads the word after the table ($1a1b4 = 0)
   if $60c3c u>= 6: return ; frame = $32 ; if $60c3c u>= 3: return ; frame = $33 ; return
ph_done:
   if byte $60cbc: state = 0; $60cbc = 0; return          ; bridge-blast knock-back, no damage
   if enemy_state == 8: goto all_dead                      ; shot by the bridge runner => GAME OVER
   msg($e "YOU'RE HIT")
   man.hits += 1 ; if man.hits u>= 5: man.hits = 4
   morale_sub($800)
   kernel $f818 (redraw hit markers) ; dissolve_out()
   if morale == 0: goto sec0_exit
   state = ($60c26==5) ? 5 : 0
   enemy_reset(); frame = 8; kill_player_bullets(); goto man_select
```
**pl_st9_blocked** $18050: `if y u< $50: y += 8 else y = $50, frame = 8`. No input handling at all.
**pl_st10_plant** $18076:
```
if y != $50: y += 8; if y u>= $50: y = $50; return
if $60c3c != 0: $60c3c--; frame = $a; facing = 0; return      ; kneel 5 ticks
$60cc1 = ($60cc1 & ~8) | 2 ; pl_move($60cc1)                   ; forced walk right every tick
```
(the state stays 10 until the bridge blows, see bridge_logic).

Village states (shared code, summary): `pl_st4_enter_hut` walks up (frames $11..$14, y=$38+$60c3a
decreasing by 2) until y < $3d, then facing=$60c38, enemy_reset, state 5, level=5, hut_setup_enemy,
level_enter. `pl_st5_in_hut`: pos=($94,$3d); trap-door check at T=$35,c34=0,c32=0,facing right →
`trapdoor_prompt`; UP = search (`hut_search` once per press, latch $60cbe, frame $11); DOWN =
leave (`hut_door_check` ok → $60c3a=-$e, $60c38=facing, state 6) else frame 8; no vertical → clear latch, pl_horizontal.
`hut_setup_enemy` $17b2c (also called every tick by en_st0 while on level 5): hut 1 ($60c40==1): prop
$60c72 = ($d0-($60c30-$1bc)*8, $3d), enemy state 4 without frame; hut 2: enemy state 4 at
($d0-($60c30-$1e4)*8, $3d) facing left, frame $34 (alive, fires every $19 ticks) or $33 (dead, if $60c70); other huts: none. `pl_st6_leave_hut`:
y=$50+$60c3a rising to $50 then level=0, state=0, enemy cleared, level_enter.
`hut_search` $17c9c: d0=$60c30-$18f; for each of the 20 entries (lo,hi,msg,msg2) at $1aafa with
lo<=d0<=hi: sfx 0 and msg(entry.msg) with specials: msg $10 = torch spot (first time: set $60cbd,
morale+$200, +500 pts, msg 2 "TORCH"; later msg 3), msg $f = hut booby trap (explosion, player_hit,
hits:=3, entry.msg:=entry.msg2, msg $f), msg $17 = map (needs $60c70 set; sets $24(a6), HUD, morale
+$200, +500, msg 8; else msg 7). `trapdoor_prompt`: msg $b and loop until N (return) or Y; Y without
torch → msg $d; Y with torch → bonus 1000 BCD per living man added to score, dissolve_out, kernel
$f874 (load next section = tunnels).

### b.5 Fire / grenade input — `player_fire_input` $1736a
```
if state != 0:
    if state != 5: return
    if frame u>= $c: return
    goto pf_fire
if $60cc1 bit4 (SPACE): goto pf_grenade
pf_fire:
  if !(bit7 FIRE) or $60c46 != 0 or man.ammo == 0: return
  slot = first of 3 bullets at $60c48 (6 bytes x,y,dx) with x==0, else return
  $60c46 = 2                                   ; auto-fire: one shot per 2 ticks max
  slot.y = y + (frame u>= $a ? $e : 7)         ; lower when crouching
  facing right: slot.x=$98, dx=+$a ; left: slot.x=$90, dx=-$a
  sfx($82)
  if $60c44 == 0: $60c3e ^= 1; frame += 1      ; firing pose only when not moving (8->9, $a->$b)
  man.ammo -= 1
  noise_add(8)
pf_grenade:
  if $60c42 != 0 or ($60cc1 & $f) != 0 or man.grenades == 0: goto pf_fire
  sfx($a); man.grenades -= 1; $60c42 = $ff; $60c66 = 8
  state = 7; $60c3c = 2; frame = $2f
  noise_add($20)
noise_add ($1744e, d0): $60cae += d0; if $60cae u>= $ff: $60cae = $ff
```
So: FIRE = rifle (hold for auto-fire), SPACE with no joystick direction = grenade.

### b.6 Enemy state machine ($5f888, table $1aad0) — only ONE enemy exists at a time
| state | handler | meaning |
|---|---|---|
| 0 | `en_st0_spawn` $180da | none; spawn logic |
| 1 | `en_st1_drop` $182c0 | sniper dropping from the canopy |
| 2 | `en_st2_walk` $182f2 | walking soldier / villager |
| 3 | `en_st3_jumpdown` $1856e | dying (small hop, falls) |
| 4 | `en_st4_in_hut` $1864c | (village) VC in hut, shoots periodically |
| 5 | `en_st5_trap` $18696 | spider-hole VC: pops up, fires once, drops back |
| 6 | `en_st6_crouchfire` $18706 | kneeling after firing |
| 7 | `en_st7_blown` $18722 | jumps over a booby trap |
| 8 | `en_st8_runner` $187c6 | the bridge runner (fires 3 shots) |

**en_st0_spawn** $180da
```
if player_state == 9:                            ; stuck at the unblown bridge
    state=8; ($5f88a,$5f88c)=(0,$50); frame=$15; $5f892=$15; $60ca6=$60c48
    facing=0; $5f894=0; $60ca4=0; return
if player_state == $a: return
if level == 5: goto hut_setup_enemy               ; $17b2c (village)
if $60c2a==1 and $39 <= $60c28 u< $56: return     ; no spawns on level 1 cols 57..85 (river/bridge)
if rand() u>= $60cae: return
if level != 0 and (rand() & $f)==0:               ; TREE SNIPER
    frame=$1e; $5f892=$15; (x,y)=($90,0); facing=0; state=1; $5f894=1; return
if (rand() & 3)==0:                               ; SPIDER-HOLE VC, 2 tiles ahead
    t = byte ($60c2c+2)
    if t u< 5 and t != 2:
        facing=0; state=5; $5f894=4; frame=$2b; $5f892=1; x = $100 + $60c34; y=$50; return
SOLDIER:
    frame=$15; $5f892=$15; $5f898=0
    if level==0 and $60c24 u>= $33 and (rand() & 2): frame=$23; $5f892=$23; st.b $5f898   ; VILLAGER
    state=2; $5f896 = 5 + (rand() & 1)            ; speed 5 or 6
    facing = rand() & 1
    (x,y) = facing==0 ? ($0001,$50) : ($130,$50)  ; enter from the left edge / right edge
```
**en_st1_drop** $182c0: `y += $5f894; $5f894 += 2; if y u>= $50: y=$50, state=2, goto en_maybe_turn`.
**en_st2_walk** $182f2
```
if (rand() & $1f)==0: goto en_try_shoot
ew_step:
  $5f894 = ($5f894+1) & 7 ; frame = $5f894 + $5f892         ; 8-frame walk cycle
  probe y = enemy y ; probe x = facing==0 ? min(x,$11f)+$20 : max(x,$10)-$10
  if solid_at(): en_turn()                                   ; turn at trees
  x += facing ? -$5f896 : +$5f896
  if $60c7a != 0 (trap on screen):
      d = $60c76 - x ; if |d| u< $40:
          if (facing==1 and d<0) or (facing==0 and d>=0): state=7; $5f894=0     ; jump over it
  if facing != player facing:                  ; walking towards the player's back side
      if facing==1 and x u< $50: en_maybe_turn ; if facing==0 and x u>= $f0: en_maybe_turn
  if x u< $130: return
  if x u>= $136: goto enemy_clear              ; left the screen (negative x counts as huge)
  en_maybe_turn
en_maybe_turn ($18440): if (rand() & $f)==0: en_turn     en_turn: facing ^= 1
```
**en_try_shoot** $18458
```
if $60c62 != 0 (enemy bullet already flying) or $5f898 (villager): goto ew_step
d1 = 8
if state == 5: d1=$18; facing=1; en_fire(); facing=0; return       ; spider-hole VC fires left
if state != 4 and (rand() & 1): d1=$10; frame=$21; state=6; $5f894=3   ; kneel & fire
en_fire ($184ca):
  $60c64 = (facing ? -10 : 10) * 2          ; asl -> +-20 px per tick
  $60c60.l = enemy (x,y) ; $60c62 += d1
  sfx(state==8 ? $a : $84)
```
**en_st6_crouchfire** $18706: `frame=$21; $5f894--; if 0: state=2`.
**en_st5_trap** $18696 (spider hole, frames $2b..$2e = bob 59..62):
```
$5f894--; if != 0: return
$5f894 = 3 ; frame += $5f892
if frame u< $2b: goto enemy_clear
if frame u< $2e: return
$5f894 = 4; $5f892 = -1; goto en_try_shoot        ; at the top: fire once, then go back down
```
**en_st3_jumpdown** $1856e (dying; started by `enemy_killed_common` with $5f892=$10, frame $1f):
```
if $5f892 != 0:
   $5f892 -= 1 ; y = ($60c26==5 ? $3d : $50) - (jump_arc[$5f892] >> 2)
   if $5f892 u>= 6: return ; if $5f892 u>= 3: frame=$20 ; else frame=$33 ; return
if level == 5: $60c70=1; state=4; y=$3d; return      ; hut VC stays lying (hut "cleared")
if $60c9c==2 and !$5f898 and (rand() & 3)==0 and $60c86==0:
   crate at ($60c84,$60c86) = (enemy x, $50)        ; supply box drop (only after the bridge blew)
goto enemy_clear
```
**en_st7_blown** $18722 (jump over trap): `frame=$1d; y = $50 - jump_arc[$5f894]`; probe at
(x+$20 or x-$10, y); if not solid: x += ±speed; if x u>= $136: enemy_clear;
`$5f894=($5f894+1)&$f; if 0: state=2, y=$50`.
**en_st8_runner** $187c6: `$5f894=($5f894+1)&7; frame=$5f894+$5f892; x += 5; if x u< $20 return;
en_drop_grenade(); x=$21; frame=$34`.
**en_drop_grenade** $1850e (really: fires the runner's shots):
```
if $60caa != 0: $60caa--; return
$60caa = 2
if $60ca4 == 3: return
$60ca4 += 1 ; a0 = $60ca6 ; $60ca6 += 6         ; uses the PLAYER bullet slots $60c48..
a0 = {x: enemy x, y: enemy y + 7, dx: 8}
if $60ca4 == 1: sfx($a)
```
**en_st4_in_hut** $1864c: `if frame != $34 return; $5f894--; if 0: $5f894=$19; goto en_try_shoot`.
**enemy_clear** $186e0: clear $5f88e frame, $5f88a x, $5f894, $5f892, $5f888 state, $5f898.
**enemy_reset** $18854: clear state, frame, $5f898; bullet_kill($60c60).
**enemy_score** $1866e: villager: msg($17 "YOU SHOULDN'T SHOOT INNOCENT VILLAGERS"), morale_sub($1200);
else score += 300 (BCD at $1a6ce).

### b.7 Bullets — `bullets_update` $174d2 and helpers
Bullet record: 6 bytes `x.w, y.w, dx.w` (x==0/y==0 → free). Slots: $60c48,$60c4e,$60c54 (player),
$60c5a (grenade), $60c60 (enemy).
```
bullets_update:
  if $60c46: $60c46 -= 1
  if $60ca4 != 0:                                   ; runner shots active: only they are processed
      $60c88.l = player (x,y)
      for i in 0..$60ca4-1: bullet_move_one($60c48+6i, bob=$30+i, handler=hit_ebullet)
      return
  $60c88.l = player (x,y) ; bullet_move_one($60c60, bob $4e, hit_ebullet)          ; enemy bullet
  $60c88.l = enemy (x,y)  ; for 3 slots: bullet_move_one($60c48.., bob $4e, hit_pbullet)
  grenade $60c5a: if y==0 return
     if $60c66 == 0: goto bullet_kill(grenade)       ; end of flight -> explosion
     y = $70 - grenade_arc[$60c66] ; $60c66 -= 1     ; grenade_arc $1a1b4 = 0,8,16,24,32,40,44,40,32
     bullet_move_one($60c5a, bob $53, hit_grenade)
bullet_move_one ($175b6, a0, d1=bob, a2=handler):
  if y==0: return
  if solid_at(x,y): goto bullet_kill                  ; hits tree / wall
  $60c8c.l = (x,y) ; x += dx
  if x u>= $140 and dx < 0: x = 0                     ; left edge
  $60c90.l = (x,y)
  if bullet_xrange_test(): jmp (a2)
bullet_draw ($17610):
  if x==0 or x u>= $140: goto bullet_kill
  if solid_at(x,y): goto bullet_kill
  draw_bob((x,y), d1)
bullet_xrange_test ($17788): lo=min(old x,new x), hi=max(..)+4, t=$60c88 (target x)
  hit  <=>  lo u>= t  and  hi u< t+$18          ; y is NOT compared at all
bullet_kill ($17644, a0):
  if a0 == $60c5a (grenade): explosion {frame $60c68=0, timer $60c6e=3, pos $60c6a=(x,$50)};
      $60c42 = 0; sfx($85)
  clear x, y, dx
kill_player_bullets ($17a88): bullet_kill on the 3 player slots; $60c42 = 0
```
Hit handlers (called with the bullet in a0):
```
hit_pbullet ($1768e):  enemy state 2 -> enemy_shot
                       state 5 -> only if a0==$60c5a and $60c66 u< 2 (never true: player bullets
                                  cannot kill spider-hole VC) -> enemy_shot ; else bullet_draw
                       state 4 and $60c70==0 -> enemy_shot ; else bullet_draw
hit_grenade ($1770e):  enemy state 2 or 5 -> enemy_shot ; else bullet_draw
hit_ebullet ($1772a):  player state 9 -> player_hit (bullet continues)
                       state 5 -> bullet_kill, player_hit
                       state 0 -> bullet_kill, player_hit      (standing, walking and crouching!)
                       other states (jumping, path, throw...) -> bullet_draw (passes through)
enemy_shot ($176bc):   bullet_kill(a0); enemy_score(); enemy_killed_common
enemy_killed_common ($176c4): sfx($80); if state==5: enemy_clear
                       else state=3; $5f892=$10; frame=$1f
player_hit ($17750):   if $60ca0: return ; $60cbc=0; player state=8; $60c3c=$10; frame=$31; sfx($81)
```
**explosion_update** $18870: `if $60c6e==0 return; $60c6e--; if !=0: draw; else $60c6e=3, draw,
$60c68++, if u>=4: $60c6e=0`. draw: `$60c6a += $60c44; if u>= $130 stop; draw_bob($60c6a.l, $34+$60c68)`.
The explosion itself does no damage.

### b.8 Jungle objects
**trap_spawn** $19b72 (booby trap / tripwire, bob $0f):
```
if $60c7a != 0 or $60c44 == 0 or $60c32 != 0 or (rand() & 3) != 0: return
d0.w = $60c34                       ; high byte kept!  (quirk)
if facing == 1 (left):  a0 = $60c2c-2 ; d0.b = byte(a0) ; base = 0
else:                   a0 = $60c2c+2 ; d0.b = byte(a0) ; base = $128
t = byte(a0) ; if t u>= 5 or t == 2: return
$60c76.l = (0,$50) ; $60c76 += base + d0.w ; $60c7a = 1
```
Quirk: x = base + ((hi byte of $60c34)<<8 | tile). With $60c34 >= 0 the trap appears at the screen
edge in the walking direction (x = 0..4 or $128..$12c: the tile value 0/1/3/4 is added!). With
$60c34 < 0 the high byte is $ff: left case x=$ff00+t (immediately removed by trap_update), right case
x=($128+$ff00+t)&$ffff = $28+t, i.e. behind the player. Port must reproduce this literally.

**trap_update** $18f82:
```
if $60c7a == 0: return
if $60c7a == 2 (exploding):
   $60c82--; if != 0: draw expl ; else $60c82=3, draw expl, $60c80++, if $60c80 u>=4: trap_clear
   draw expl: $60c76 += $60c44 ; draw_bob($60c76.l, $34+$60c80)
   return
$60c76 += $60c44 ; if $60c76 u>= $130: trap_clear
if $8c <= $60c76 u< $9c and player_state == 0:   ; jumping (state 1) avoids it
   player_hit(); man.hits = 3 (death on the following hit count); $60c7a=2; $60c82=3; $60c80=0; sfx($85); return
trap_draw: $60c36 = 0 ; draw_bob($60c76.l, $0f)
trap_clear ($19066): $60c7a = 0 ; $60c76.l = 0
```
**bomb_update** $19094 (object $60c7c: explosives box on level 4 / the planted charge):
`if $60c7c.l==0 return; $60c7c += $60c44; if u>= $140: bomb_clear; draw_bob($60c7c.l, $33)`.
**explosives_pickup** $19c18:
```
if $28(a6) (carrying explosives) or $60c2a != 4: return
if $60c28 u>= $36 or $60c28 u< $31: bomb_clear; return
if $60c28 == $31 and $60c32==0 and $60c34==2: $60c7c.l = ($138,$50); return      ; box appears at right edge
if $90 <= $60c7c u< $98:                           ; player walked onto it
    bomb_clear; st $28(a6); msg($10 "YOU HAVE FOUND SOME EXPLOSIVES"); kernel $f808; score += 500
```
**bridge_logic** $19cb2 (level 1 only):
```
if $60c2a != 1: return
if $45 <= $60c28 u< $4b and $60c9c==0 and $48(a6)==0: msg($11 "SET THE EXPLOSIVES ON THE BRIDGE")
if $60c28 == $48 and $28(a6) and $60c9c != 2 and player_state != $a:          ; PLANT
    $60c7c = (player x, $50); player_state = $a; $60c3c = 5; $60c9c = 1; $28(a6) = 0; kernel $f808
    return
if $60c28 u< $4e: return
if $60c9c == 0:                                     ; walked past without planting
    if enemy_state == 8: return
    player_state = 9
    if enemy_state == 2: goto enemy_killed_common   ; remove a walking soldier
    return
if $60c9c == 2: return
bridge_blow ($19dd0):                               ; charge planted, player now at col >= $4e
    $1b209 = $95; $1b20a = $96                      ; broken bridge tiles in the map
    player_hit(); st.b $60cbc                       ; knock-back animation, no damage (ph_done)
    $60c9c = 2 ; score += 10000
```
**crate_update** $190ca: `if $60c86==0 return; $60c84 += $60c44; if u>= $141: crate_clear;
draw_bob($60c84.l, $3a)`.   **crate_open** $19e0a:
```
if $60c86==0 or !( $90 <= $60c84 u< $98 ): return
r = rand() & 3
r==0: msg($13 "A BOX OF VIET CONG AMMUNITION."); man.ammo += $48; if u>= $90: $90 ; crate_done
r==1: msg($c "MEDICAL SUPPLIES"); morale += $300; if man.hits: man.hits -= 1, kernel $f818 ; crate_done
r==2: msg(0 "A FOOD PACKAGE") ; crate_done
r==3: msg($14 "AN EMPTY BOX"); crate_clear; return
crate_done: morale += $200; crate_clear; score += 500
```
**draw_enemy** $19102:
```
if (player_state==5 or 6) and $60c40==1:          ; village hut #1 prop instead of the enemy
    $60c72 += $60c44; $60c36=0; draw_bob($60c72.l, $3b); return
if enemy frame == 0: return
$60c36 = enemy facing ; enemy x += $60c44          ; enemies scroll with the world here
if player_state==0 and $5f898==0 and enemy_state in {2,5} and $80 <= enemy x u< $a8:
    player_hit()                                   ; bodily contact kills  [verified]
draw_frame(enemy (x,y), enemy frame)
```
**draw_player** $191be: `$60c36 = facing; draw_frame($5f880.l, $5f884)`.

### b.9 Level / attribute helpers
`level_enter` $17a48: `$1a004 = (level==0 or level==5) ? $0ca2 : $000d` (palette colour 6);
if `$5a(a6)==$19ff8` reload the upper palette ($f878); `calc_player_pos(); build_attr_map()`.
`build_attr_map` $18c86: `attr_copy_cols($600b4, map[level]+$60c24, 7 cols, 3 rows)`.
`attr_copy_cols` $18caa (a0 dest, a1 map, d0=cols<<16|rows): for each row: for each col: tile=*a1++;
copy the tile's 6x8 attribute bytes to dest rows (dest stride $38); dest += 8 per column; after a row
dest = rowstart+$150, map = rowstart+$5a.
`solid_at` $19ed2: `cell = byte[$600b4 + ($60c96 u>>3)*$38 + ($60c94 u>>3) + 8 + $60c34]`;
solid (d7=$ff) iff cell==$b0 or cell==$da or $c0<=cell<=$d0. No bounds checks (y>=$90 reads past
the window into the bob buffer).
`hut_door_check` $1880e: col $60c28 must be one of $4d,$49,$42,$3c,$37,$31 ($1aaf4; d1=5..0 becomes
$60c40) and |$60c34| must be 7 or u< 2 (effectively 0). `abs_d0` $1884a.

### b.10 Death / choose-your-man — `man_select` $19518 (village agent: same code)
```
kernel $f878($1a038) (black) ; $f848 ; if $62(a6) != $70000: $f84c ; $f85c ; clear_buf_78000()
if man.hits == 4:
    msg($12 "KILLED IN ACTION")
    first man i (0..4) with hits u< 4 ; none -> sec0_exit (game over)
    $22(a6) = $60c9e = i ; $1e(a6) = a6+6i
ms_draw: box in the non-displayed... (buffer $62(a6)^$8000)+$28b: 113 rows x 18 bytes:
         plane0 = $ff, planes1-3 = 0 (colour 1); print "CHOOSE YOUR MAN:" ($1a9cd)
         per man i: dead -> "KILLED IN ACTION" at text row 5+2i ($1a9fe, y patched);
         alive -> bars: grenades*8 px (icon $13294) at $1a158[i], ammo/2 px (icon $13274) at
         $1a16c[i], one red hit marker ($132b4) per hit at $1a180[i]
         fade in palette $1a018 as the UPPER palette ($f870 with a3=$5a(a6))
ms_loop: print number of $60c9e normal ($1aa18[..]), select $22(a6), print it highlighted ($1aa5e[..]),
         kernel $f818
         wait until joystick released; then wait for input (every 2 frames, read_input each time):
         FIRE: $f818; msg($15 "TAKE CONTROL OF YOUR MAN...."); clear explosion/trap; clear_buf_78000;
               draw_tiles; palette $19ff8; dissolve_in (restores the scene saved in $68000); return
         UP: previous living man (stop at 0) ; DOWN: next living man (stop at 4)
```
`all_dead` $19d8c (killed by the bridge runner): man.hits=4, $f818, msg $12, dissolve_out, music 3,
palette $1a018, print "YOU DID'NT BLOW UP THE BRIDGE, YOUR PLATOON HAS BEEN WIPED OUT!" ($1a970),
wait for fire press+release (`wait_fire_press` $19850), jmp $f864 (game over).

### b.11 Screen transitions
`backbuf_to_68000` $1988a: 4 blits A=$62(a6)+p*$2000 -> D=$68000+p*$2000, size $3214
(200 rows x 20 words = full 320x200 plane). `restore_68000_to_backbuf` $188d6: reverse direction.
`clear_buf_78000` $194fa: clear 4 planes x $1680 bytes at $78000 (playfield part of buffer 2).
`dissolve` $19946 (a5 = mask group table, d3 = +-$20, a1 = "random" source pointer):
```
a1 &= ~1
for step in 0..7:
    dst = $62(a6) ; src = $68000
    for byte in 0..5759 (144 lines x 40):
        d4 += word(a1) ; a1 += 2           ; (a1 wraps inside the low 64K every 8 bytes: a1 &= $ffff)
        mask = byte of long a5[(d4 & $1c)/4]          ; 8 masks per step
        for p in 0..3: dst[p*$2000+byte] = src[p*$2000+byte] & mask
    kernel $f84c ; read_input ; kernel $f85c        ; show it (1 swap per step)
    a5 += d3
restore_68000_to_backbuf()
dissolve_out ($19936): backbuf_to_68000(); d3=+$20, a5=$1a058 (masks with 7,6,..,1 bits set)
dissolve_in  ($19926): d3=-$20, a5=$1a138 (step0 all-zero masks, then $1a118..$1a058)
```
The per-byte mask choice comes from whatever memory a1 points at (effectively pseudo-random); a port
may use any PRNG. Mask groups ($1a058, 8 groups x 8 longs, each long = 4 equal bytes):
fe fd fb f7 ef df bd 7f / 77 af bb bd dd ee be af / b5 6e d9 67 ad ad d5 ce / 55 aa 33 cc 4d 9a 6c c5 /
4a 91 26 98 52 52 2a 31 / 88 50 44 42 22 11 41 50 / 01 02 04 08 10 20 40 80 / 00 x8 ($1a138).

### b.12 Kernel / resident calls used by section 0 (interfaces; implementation in re/kernel)
| call | target | used as |
|---|---|---|
| $f808 | $1058a | redraw HUD item icons ($24/$28/$2c/$26 flags of a6) |
| $f80c | $10638 | score += 4-byte BCD ending at a0 (abcd x4 into $4e(a6)); marks score for redraw |
| $f818 | $10656 | redraw the current man's hit markers (man+4) |
| $f82c | $1070c | queue message d0 (max 4 queued in $3c(a6), count $48(a6)); shown in the HUD message line with colour fade $34(a6) |
| $f830 | $1084a | full HUD redraw |
| $f834 | $108a0 | per-tick HUD update (score, grenade/ammo/morale bars, clock); loops while paused (Tab) |
| $f838 / $f83c | $10968 / $109be | draw a bar of d0 px (8-px icons at a0) at a1 / draw one 8x8 4-plane icon masked by d2 |
| $f840 | $104aa | clear $70000-$7ffff |
| $f848 | $10ad6 | wait for vertical blank |
| $f84c | $10ae2 | swap: $62(a6) ^= $8000, next copper list = the other one, set flag $12d74 |
| $f850 | $10bcc | random byte in d0 (0..255) |
| $f854 | $11062 | fill longs: a0 dest, d0 first, d1 count-1, d2 step |
| $f85c | $10b14 | wait until $12d74 == 0 (swap performed by the level-6 IRQ) |
| $f864 | $fee8 | game over (fade, hiscore, back to title) — never returns |
| $f868 | $10c00 | start music d0 |
| $f86c | $10c50 | sound effect d0 (if sfx enabled) |
| $f870 | $fade | fade palette: a0 target, a3 -> palette var, a4 = setter ($f878/$f87c), 16 steps x 2 frames |
| $f874 | $11076 | end section, load next ($6e(a6)+1) — never returns |
| $f878 / $f87c | $11010 / $11000 | set upper (playfield) / lower (HUD) palette from a0 (16 words) |
| $f880 | $fd4e | set HUD split line d0 (HUD bitplane pointers + CIA-B TOD alarm) |
| $404 / $408 | resident | print char / print string (x,y,attribute codes, text, $ff) |
| $40c | resident $1ca6 | key test: d0 = raw keycode -> d0 = $ff if held |
| $410 | resident $1c30 | joystick port 2 -> d0 bits: 0 down, 1 right, 2 up, 3 left, 7 fire |

### b.13 Unused / dead code
- `dead_19002` $19002-$19027: after an unconditional `bra` in trap_update: old "trap kills enemy"
  (if trapx u>= enemy x and trapx+8 ... -> enemy_killed_common). Never executed.
- `unused_19b1a` $19b1a-$19b70: unreferenced 17-pass bit-shuffling wipe over buffer $62(a6)^$8000.
- `unused_kernel_stubs` $19f88-$19fc6: jsr $f81c/$f820/$f824/$f828 stubs and a debug "ESCAPE"
  print + TRAP #14 (monitor). Unreferenced.

---------------------------------------------------------------------------------------------------
## (c) RAM variables

Section variables (all cleared to 0 by `sec0_start` unless an init value is given).
W = written by, R = read by (main users only).

| addr | size | name / meaning | init | W / R |
|---|---|---|---|---|
| $5f880 | w | player x (screen coords +16, always $94) | $94 | st0,st5 / draw, fire |
| $5f882 | w | player y ($50 ground, $3d inside hut; jump/hit arcs subtract) | $50 | player states |
| $5f884 | w | player animation frame (index into frame table, §d.5) | 0 | all player code |
| $5f886 | w | player facing: 0 right, 1 left | 0 | scroll_step toggles |
| $5f888 | w | enemy state 0..8 | 0 | enemy states, bridge_logic |
| $5f88a | w | enemy x | 0 | enemy code, draw_enemy (+scroll) |
| $5f88c | w | enemy y | 0 | |
| $5f88e | w | enemy frame (0 = invisible) | 0 | |
| $5f890 | w | enemy facing 0 right / 1 left | 0 | |
| $5f892 | w | enemy base frame (walk) / death counter / anim step (+1/-1) | 0 | |
| $5f894 | w | enemy anim counter / fall speed / timer | 0 | |
| $5f896 | w | enemy walk speed px/tick | 6 (5-6 at spawn) | en_st0 |
| $5f898 | w | villager flag (st.b -> $ff00) | 0 | en_st0 / score, shoot, contact |
| $5f89a | w | player state 0..10 | 0 | |
| $5f89c | 6 l | map level pointers $1b000+n*$10e | table | init |
| $5f8b4 | 152 l | tile gfx pointers $1c000+n*$600 | table | init / draw_tiles |
| $5fcb4 | 152 l | tile attribute pointers $5dc00+n*$30 | table | init / attr_copy_cols |
| $600b4 | $3f0 | attribute window: 18 rows x 56 bytes (7 tiles x 8 cells, 3 tile rows x 6 cells) starting at map col $60c24 | built | build_attr_map, scroll_step / solid_at |
| $604a4 | $3c0 | bob work buffer (mask+4 planes, rows of W+1 words) | | draw_bob |
| $60864 | $3c0 | bob background-priority mask buffer | | draw_bob |
| $60c24 | w | T = map column of the leftmost (partly hidden) tile of the attribute window | $1a6da hi (5) | scroll |
| $60c26 | w | level 0..5 (map strip) | $1a6da lo (1) | path/hut code |
| $60c28 | w | player map column (calc_player_pos) | | |
| $60c2a | w | copy of level | | |
| $60c2c | l | ptr to bottom-row map byte at player column | | path checks, spawns |
| $60c30 | w | player world x in 8-px units = T*8+$60c34+$1c | | bridge, village, priority |
| $60c32 | w | $60cb2 & 7 (0 = player on 8-px boundary) | | |
| $60c34 | w | coarse scroll inside tile, bytes, even, -6..+6 | 0 | scroll_step |
| $60c36 | w | flip flag for draw_frame (+$40 frames) | | draw_* |
| $60c38 | w | facing saved during path/hut transition | | |
| $60c3a | w | path/hut walk offset | | st2/3/4/6 |
| $60c3c | w | player sub-counter (jump index, walk cycle, hit timer, throw timer, plant timer) | | |
| $60c3e | w | toggled on each shot (unused) | | |
| $60c40 | w | hut number 0..5 (door table index) | | |
| $60c42 | w | grenade in use | 0 | fire, bullet_kill |
| $60c44 | w | world x delta this tick (-4/0/+4); every object adds it | 0 each tick | scroll_step |
| $60c46 | w | rifle cooldown (2 ticks) | 0 | |
| $60c48 | 3x6 | player bullets {x,y,dx}; also the bridge runner's 3 shots | 0 | |
| $60c5a | 6 | grenade {x,y,dx} ($60c5c = y != 0: in flight) | 0 | |
| $60c60 | 6 | enemy bullet {x,y,dx} ($60c62 = y) | 0 | |
| $60c66 | w | grenade flight counter 8..0 | | |
| $60c68 | w | grenade-explosion frame 0..3 | | |
| $60c6a | l | grenade-explosion pos (x,y=$50) | | |
| $60c6e | w | grenade-explosion tick timer (3) / active | | |
| $60c70 | w | hut enemy killed flag (village) | | |
| $60c72 | l | hut prop position (village) | | |
| $60c76 | l | booby trap pos (x, y=$50) | | trap_* |
| $60c7a | w | trap state 0 none / 1 armed / 2 exploding | | |
| $60c7c | l | explosives object pos (box on level 4, planted charge on level 1); 0 = none | | |
| $60c80 | w | trap explosion frame | | |
| $60c82 | w | trap explosion tick timer | | |
| $60c84 | l | supply crate pos; $60c86 = y (0 = none) | | |
| $60c88 | l | hit-test target position (x used only) | | bullets |
| $60c8c,$60c90 | l,l | bullet old / new position | | |
| $60c94,$60c96 | w,w | solid_at probe x,y | | |
| $60c98 | 4 | BCD bonus (trap door) | | |
| $60c9c | w | bridge state: 0 intact, 1 charge set, 2 blown | 0 | bridge_logic |
| $60c9e | w | man number shown highlighted on the choose screen | | |
| $60ca0 | w | invincible (cheat F5/F6, cleared on section exit) | 0 | player_hit |
| $60ca4 | w | runner shots fired 0..3 | | |
| $60ca6 | l | next bullet slot for runner shots | | |
| $60caa | w | runner fire interval counter | | |
| $60cae | w | enemy spawn chance / "noise" (7..$ff) | 0 (->7) | main loop, fire |
| $60cb0 | w | pixel scroll counter 0..15 | 8 | scroll_step |
| $60cb2 | w | hardware fine scroll (= $60cb0) | | draw_bob, main |
| $60cb4 | l | tick counter ($60cb7 bit0 = walk anim pacing) | | |
| $60cba | w | foreground priority line y ($60/$70/$80) | | draw_bob |
| $60cbc | b | bridge-blast knock-back flag | | |
| $60cbd | b | torch found (village) | | |
| $60cbe | b | hut search latch | | |
| $60cbf | b | input at jump start | | |
| $60cc0 | b | last horizontal direction bits | | |
| $60cc1 | b | input: b0 down b1 right b2 up b3 left b4 space b7 fire | | read_input |
| $60cc2 | 200 l | y*40 table | table | draw_bob |
| $1a004 | w | palette colour 6 (patched per level) | $000d on disk | level_enter |
| $1a6da | l | start position (T<<16 \| level); F1-F4 overwrite it | $00050001 | |
| $1b209,$1b20a | b | bridge tiles in map ($8c,$8d intact / $95,$96 blown) | $8c,$8d | init, bridge_blow |

Kernel globals used (a6 = $12dde; see re/kernel for full list):
| a6+ | meaning in section 0 |
|---|---|
| $00-$1d | 5 men x 6 bytes: +0 grenades (9; HUD bar grenades*8 px, round icons), +2 ammo ($90 = 144 rounds; HUD bar ammo/2 px, bullet icons), +4 hits (0..4; 4 = dead; red hit markers at the HUD's left) |
| $1e.l / $22.w | current man pointer / index |
| $24.w | map found (village; HUD icon) |
| $28.w | explosives carried (HUD icon) |
| $26,$2c,$54 | cleared at start (other items / alternate ammo display; used in other sections) |
| $2e.w | MORALE, 16-bit; HUD heart bar = (morale>>8)/2 px drawn with 8-px heart icons (last one partial), max 72 px = 9 hearts; -1 per tick; 0 = game over. Set to $9000 by the kernel at a new game ($fcb6) |
| $34.l,$4a.l | message colour table / message text table |
| $48.w | number of queued messages (0 = none showing) |
| $4e.l | score (BCD, 8 digits) |
| $5a.l,$5e.l | current upper / lower palette pointer |
| $62.l | back buffer ($70000 or $78000) |
| $70.w | cheat mode ("MEGA CHEAT", kernel) |
| $72.w | BPLCON1 value for the playfield |

---------------------------------------------------------------------------------------------------
## (d) Data formats (all verified by `extract.py`; addresses = RAM = ADF-$1ce00+$17000)

### d.1 Section memory layout
| range | content |
|---|---|
| $17000-$19fc7 | code |
| $19fc8-$19fd7 | "ESCAPE" debug text (unused) |
| $19fd8-$19ff7 | message colour-fade table: 8 longs $00000000,$00220002,$00440004,...,$00ff000f (2 colours each, used by the kernel message fader via $34(a6)) |
| $19ff8-$1a017 | playfield palette, 16 words: 000 a60 0c2 c40 620 06f [00d / ca2] 060 682 ca6 c64 c42 8aa 688 100 fff |
| $1a018-$1a037 | HUD palette: 000 00f f00 f0f 0f0 0ff ff0 fff 000 000 c66 a60 444 888 840 000 |
| $1a038-$1a057 | all-black palette |
| $1a058-$1a157 | dissolve masks (8 groups x 8 longs) + zero group at $1a138 |
| $1a158/$1a16c/$1a180 | choose-man screen positions (5 longs each: grenade bar, ammo bar, hit markers) |
| $1a194 | jump arc, 16 words: 8,15,22,28,33,37,39,40,39,37,33,28,22,15,8,0 |
| $1a1b4 | grenade arc, 9 words: 0,8,16,24,32,40,44,40,32 (index = remaining flight ticks) |
| $1a1c6 | frame table, 128 longs -> bob lists |
| $1a3c6-$1a535 | bob lists (bytes, $ff-terminated) |
| $1a536-$1a6c9 | per-bob draw offset, 101 x (x.w, y.w) |
| $1a6ca-$1a6d9 | BCD score constants: $1a6ce "00000300", $1a6d2 "00000500", $1a6d6 "00010000" (kernel $f80c takes a0 = END of the 4 bytes) |
| $1a6da | start position long ($0005,$0001) |
| $1a6de-$1a741 | 25 message pointers; $1a742-$1a966 message texts |
| $1a967-$1aa9f | kernel $408 text strings (attribute reset, bridge game-over text, GAME OVER, CHOOSE YOUR MAN, KILLED IN ACTION, man numbers) |
| $1aaa4 | player state table (11 longs) |
| $1aad0 | enemy state table (9 longs) |
| $1aaf4 | hut door columns $4d,$49,$42,$3c,$37,$31 |
| $1aafa | village search table, 20 x (lo,hi,msg,msg2) vs $60c30-$18f |
| $1b000-$1b653 | MAP, 6 levels x 3 rows x 90 bytes |
| $1c000-$54fff | 152 tiles x $600 |
| $55000-$553ff | bob directory, 128 x 8 bytes (101 used) |
| $55400-$5dbff | bob data |
| $5dc00-$5f87f | tile attributes, 152 x $30 |
| $5f880-$60fe1 | variables (cleared) |
| $68000-$6ffff | scratch screen copy for dissolves (4 planes x $2000) |
| $70000/$78000 | the two screen buffers (4 planes, $2000 apart, 40 bytes/line; lines 0-143 playfield, HUD from line $90 of $78000 only) |

### d.2 Map ($1b000)  -> `assets/map_full.png`, `map_level<N>.png`, `map.json`
`byte map[level 0..5][row 0..2][col 0..89]`, address `$1b000 + level*$10e + row*90 + col`. Each byte
is a tile number 0..$97. One level = one horizontal strip 3 tiles (144 px) high, 90 tiles (5760 px)
wide. Row 0 = canopy, row 1 = trunks/bushes, row 2 = path/foreground. Levels 1-4 = jungle,
level 0 = jungle cols 0-44 + village street cols 45-89, level 5 = hut interiors (cols 45-83; cols 0-44
empty tile 0).  Bottom-row tile **3 = path leading up** (to level-1), **4 = path leading down**
(to level+1). The connections are consistent (down-columns of level L == up-columns of L+1):

| level | up (tile 3) cols | down (tile 4) cols |
|---|---|---|
| 0 | (0, 86: no effect, UP on level 0 = hut doors) | 4,17,21,31,33,37,40,84,88 |
| 1 | 4,17,21,31,33,37,40,84,88 | 1,3,13,26,39,42,45,48,51,53,56,59,66,68,82 |
| 2 | 1,3,13,26,39,42,45,48,51,53,56,59,66,68,82 | 4,9,16,19,23,30,33,37,40,43,52,63,73,80,86,88 |
| 3 | 4,9,16,19,23,30,33,37,40,43,52,63,73,80,86,88 | 3,6,26,31,34,46,48,55,60,65,68,75,77,83 |
| 4 | 3,6,26,31,34,46,48,55,60,65,68,75,77,83 | 0,86,88 |
| 5 | 86 | 84,88 (would go to level 6 = garbage map pointers; unverified whether reachable) |

Blocking trees (columns whose middle-row tile has solid cells in attribute rows 10-11, i.e. at the
player's probe height): L0: 2,18,36,41,47,85 · L1: 2,5,14,22,27,32,38,52,55,57,86 ·
L2: 0,2,7,29,35,36,41,50,55,60,64,67,77,81,84,87 · L3: 1,2,8,18,27,32,35,44,49,50,57,62,71,79,85 ·
L4: 2,33,47,53,66,76,85. The start (L1, T=5, player col 8) is boxed in by trees at cols 5 and 14 (walking left stops at
$60c30=$30, right at $60c30=$70), so the only way out is the down-path at col 13 (to level 2).
Trees cannot be jumped over (the collision probe ignores y). **[verified]**
Key places: explosives on L4 cols $31-$35 (49-53); bridge L1 cols 71/72 (tiles $8c/$8d), "set
explosives" hint L1 cols 69-74, plant at col 72, blow/doom at col >= 78; village L0 cols 45-84 with
hut doors at cols 49,55,60,66,73,77.

### d.3 Tiles ($1c000) -> `assets/tiles.png`
Tile n at `$1c000 + n*$600`: 4 bitplanes stored **plane-sequentially**, each plane 48 rows x 8 bytes
($180 bytes), plane 0 = bit 0 of the colour index. 64x48 pixels, colours from the playfield palette.
### d.4 Tile attributes ($5dc00) -> `assets/tile_attr.png`, `map_attr_full.png`
Tile n at `$5dc00 + n*$30`: 6 rows x 8 bytes, one byte per 8x8 cell. The code only distinguishes
solid (= $b0, $da, $c0..$d0) from non-solid; other values (mostly $01, $0c-$0f, $1f-$27...) have no
effect in section 0.
### d.5 Bobs ($55000/$55400) -> `assets/bobs.png`, `bobs.json`
Directory entry i (8 bytes at $55000+8i): `+0 offset.l` (from $55400), `+4` copy of the header (not
used by code). Entries 101..127 are zero. Data at $55400+offset:
`header.l = (W-1)<<16 | (H-1)` (W in 16-px words), then `mask plane` (H rows x W words), then
colour planes 0,1,2,3 (each H rows x W words). mask == OR of the 4 planes for every bob (checked).
Sizes: 1-2 words wide, 1..35 rows. Bob draw offset (x.w,y.w) at $1a536+4i is added (as one long)
to the object position before drawing.
### d.6 Animation frames ($1a1c6) -> `assets/frames.png`, `frames.json`
128 pointers; frame f+$40 = same frame facing left (separate mirrored bobs, no runtime flipping).
Each points to a byte list of bob numbers terminated by $ff, all drawn at the same object position
(each with its own bob offset). Frame usage:
| frames | use |
|---|---|
| 0-7 | player walk cycle | 
| 8 / 9 | player stand / stand firing |
| $a / $b | player crouch / crouch firing |
| $c | player jump |
| $d-$10 | walking down a path (towards camera) |
| $11-$14 | walking up a path / into a hut (back view) |
| $15-$1c | VC soldier walk cycle |
| $1d | soldier jumping over a trap |
| $1e | sniper dropping from a tree |
| $1f,$20,$33 | enemy dying sequence (also player hit $31,$32,$33) |
| $21 | soldier kneeling/firing |
| $23-$2a | villager walk cycle (conical hat) |
| $2b-$2e | spider hole opening / VC rising |
| $2f,$30 | player grenade throw |
| $31-$33 | player hit / falling / lying |
| $34 | runner kneeling & firing (bridge) / hut VC |
| $35-$3f | unused (bob 0 twice) |
Single bobs drawn directly: $0f booby trap, $30-$32 runner shots, $33 explosives/charge, $34-$37
explosion frames, $3a supply crate, $3b hut prop, $4e bullet (1x1), $53 grenade.
### d.7 Messages ($1a6de) -> `assets/messages.json`
Pointer table of 25 entries; each message = `x.b, y.b, ASCII..., $ff` (x,y = text position in the
HUD message line, used by the kernel message system $f82c). Ids: 0 A FOOD PACKAGE, 1 A SACK OF FLOUR,
2 YOU HAVE FOUND A TORCH, 3 A POT OF RICE, 4 RUBBISH., 5 A STOOL., 6 EMPTY., 7 A TABLE., 8 YOU HAVE
FOUND A MAP, 9 PROVISIONS, $a A POT OF WATER, $b HERE IS A TRAP DOOR.... GO DOWN (Y/N)?, $c MEDICAL
SUPPLIES, $d YOU NEED TO FIND A TORCH, $e YOU'RE HIT, $f A VIET CONG BOOBY TRAP!!, $10 YOU HAVE FOUND
SOME EXPLOSIVES, $11 SET THE EXPLOSIVES ON THE BRIDGE, $12 KILLED IN ACTION, $13 A BOX OF VIET CONG
AMMUNITION., $14 AN EMPTY BOX, $15 TAKE CONTROL OF YOUR MAN...., $16 CHEAT!, $17 YOU SHOULDN'T
SHOOT INNOCENT VILLAGERS, $18 PLEASE DON'T ATTEMPT SUICIDE!!
### d.8 Palettes -> `assets/palettes.png/json`
see d.1. Colour 6 of the playfield palette = $000d on levels 1-4, $0ca2 on levels 0 and 5.

---------------------------------------------------------------------------------------------------
## (e) Per-frame flow and timing

- Interrupts (kernel): level 3 (vblank, $10eac): music driver, clock, keyboard/pause/F10, sets the
  vblank flag $56(a6). Level 6 (CIA-B TOD alarm at hsync count $cc, i.e. the HUD split line):
  if $12d74 set, COP1LC := $12d76 (the copper list of the buffer just finished) and clears the flag;
  copies $72(a6) into the copper BPLCON1 word ($115f2). So the new frame and its scroll value become
  visible together at the next vertical blank.
- Main loop: `f85c` (wait for swap) ... logic ... render into $62(a6) ... `f84c` (request swap).
  Rendering (full clear + 18 tile blits + bobs) takes more than one frame, so the loop runs at
  **25 Hz: one tick every 2 frames in tools/amiga/emu** (measured: 234 of 249 intervals = 2 frames, a few 1 or 3
  frames from blit/CPU phase; 500 frames = 250 ticks). All speeds in this document are per tick.
  On a real A500 (cycle-exact vAmiga, port/verify/timing.md) it is ~2.8 frames per tick (mostly 3, ~18 Hz): the
  emulator gives the CPU every bus cycle and does the blits in zero time.
- Order inside a tick: input -> keys -> player state -> fire input -> enemy state -> priority line ->
  background -> spawners/triggers -> objects (trap, charge, crate) -> enemy (+contact) -> bullets ->
  explosion -> player -> swap -> morale-1.
- Double buffering: $62(a6) toggles $70000/$78000 (eori $8000). Copper list $115d0 shows $70000,
  $116a8 shows $78000; both jump (COPJMP2) into the common tail at $115f0.

---------------------------------------------------------------------------------------------------
## (f) Rendering

### f.1 Display (copper tail $115f0, set up by the kernel; section 0 patches two words)
```
list A $115d0: BPL1PT=$70000 BPL2PT=$72000 BPL3PT=$74000 BPL4PT=$76000   (list B $116a8: $78000..$7e000, then COPJMP2)
tail $115f0:   BPLCON1 = $72(a6)          (fine scroll, both playfields: $60cb2*$11)
               DIWSTRT = $3c81            (patched by sec0_start via ($f888))
               COLOR00-15 = upper palette ($f878 writes here)
               WAIT ($cc,$01)             (line $cc = $8f+$3d, from f880(d0=$8f))
               BPL1-4PT = $79680,$7b680,$7d680,$7f680   (HUD = lines $90.. of buffer $78000)
               BPLCON1 = $0088            (patched via ($f88c))
               DIWSTRT = $3c71
               COLOR00-15 = HUD palette ($f87c writes here)
               END
static (kernel $10b1e): BPLCON0 = $4200 (4 planes lowres), BPLCON2=0, BPL1MOD=BPL2MOD=0,
               DDFSTRT=$30, DDFSTOP=$c8, DIWSTOP=$04b1, sprites off (SPRxDATA cleared, DMA $83c0 = no sprite DMA)
```
Playfield: 4 bitplanes, 320x144, lines $3c..$cb, 40 bytes per line fetched from DDFSTRT $30
(16 px earlier than normal) so that BPLCON1 delay 0..15 scrolls smoothly; with DIWSTRT h=$81 the
visible area shows fetched pixels 16-d .. 335-d where d = $60cb2 (the last 16-d visible pixels are
beyond the 320 fetched ones). HUD: lines $cc.., BPLCON1=$88 fixed. No hardware sprites are used —
all objects are blitter bobs.
### f.2 Coordinates
Object (x,y): y = playfield line (0 = top), x such that screen pixel = x - 16 (independent of fine
scroll, because draw_bob subtracts $60cb2 and the display adds it back). Objects are visible for
x-$60cb2 in [0,$140). World-to-screen: the fetched byte 0 of a line is world byte
(T+1)*8 + ($60c34 & ~1) (8-px units), i.e. world pixel of screen x=0 is 64*(T+1)+8*$60c34+16-$60cb2.
### f.3 Background blits — `draw_tiles` $18cf4 (verified by render_sim.py)
```
clear $62(a6)+p*$2000, p=0..3, $1680 bytes each (CPU)
save $60c34 ; $60c34 &= ~1 ; d5 = $60c34 asr 1   (-3..3, in 16-px units) ; restore at the end
src = map[level] + $60c24 + (d5 >= 0 ? 1 : 0)
BLTCON1=0, FWM=LWM=$ffff (kernel), all blits BLTCON0=$09f0 (D=A), 4 blits per tile (planes, dest +$2000,
A pointer continues from plane to plane)
for row 0..2 (dest line row*48):
   if d5 > 0 : first tile shows its right 8-c bytes: A=tile+c, AMOD=c, DMOD=$20+c, size 48x(4-d5) words, dest x=0
   if d5 < 0 : first tile shows its right |c| bytes:  A=tile+8+c, AMOD=8+c, DMOD=$28+c, size 48x(-d5) words
   full tiles (5 if d5==0 else 4): AMOD=0, DMOD=$20, BLTSIZE=$0c04 (48 rows x 4 words)
   if d5 > 0 : last tile shows its left c bytes: AMOD=8-c, DMOD=$28-c, size 48xd5 words   (tile NOT consumed)
   if d5 < 0 : last tile shows its left 8+c bytes: AMOD=-c, DMOD=$20-c, size 48x(4+d5) words
   src += 85 (next map row)            (c = $60c34 & ~1)
```
### f.4 Bob blits — `draw_bob` $1920a (d0 = x<<16|y, d1 = bob#)  (verified)
```
d0 += offset_long[bob]; ytop = d0.w; x' = d0.hi - $60cb2; if (x'<<16|y) u>= $01400000: return (x' outside 0..319)
1  clear  $604a4: BLTCON0=$0100, all mods 0, D=$604a4, BLTSIZE=$2806 (160 rows x 6 words)
2  copy   bob data (mask+4 planes, 5H rows x W words) to $604a4 with DMOD=2 -> rows of W+1 words,
          last word 0 (room for the shift). BLTCON0=$09f0, BLTSIZE=(5H<<6)|W
   scr = $62(a6) + y*40 + ((x'>>3)&$fe); shift s = x'&15; size = (H<<6)|(W+1); SMOD = 40-2(W+1)
3  bg     $60864 = scr.plane1                       (BLTCON0 $09f0, AMOD=SMOD, DMOD=0)
4,5       $60864 |= scr.plane2, |= scr.plane3       (BLTCON0 $0bfa: D = A|C, C=D=$60864)
   (so the background mask = pixels whose colour index >= 2)
6  priority vs line L=$60cba:
   ytop >= L          : mask = shift(mask) & ~bg for all rows        (BLTCON0 = s<<12|$0d30, A=B? A=$604a4 B=$60864 D=$604a4)
   ytop+H <= L        : no change, cookie uses A shift               (con = s<<12|$0fca)
   straddling         : rows above L: $60864 = shift(mask) (s<<12|$09f0), then $604a4 = $60864 ($09f0);
                        rows below: mask = shift(mask) & ~bg ($0d30 with A shift); cookie A unshifted
7  cookie-cut 4 planes: BLTCON0 = con ($0fca, A shift if not pre-shifted), BLTCON1 = s<<12 (B shift),
   A = $604a4 (mask, reset per plane), B = colour planes (continuing), C = D = scr + p*$2000,
   AMOD=0, BMOD=0, CMOD=DMOD=SMOD; D = A&B | ~A&C
```
Effect: below line $60cba (normally y=$60, i.e. from the knees down when standing at y=$50) an
object is only drawn over background colours 0 and 1 (black and the brown path), so bushes and
other foreground scenery (colours >= 2) hide the legs. $70 in the village street, $80 on the
level-1 river section.
### f.5 Draw order (painter's algorithm): background, trap, explosives/charge, crate, (hut prop),
enemy, enemy bullet, player bullets, grenade, explosion, player. Composite frames draw their bob
list in list order.
### f.6 Verification
`render_sim.py PRE POST EVENTS` re-renders a frame from a RAM dump taken at $172f8 plus the logged
draw_bob calls and compared **23040/23040 bytes identical** with the real back buffer for 9 frames
covering $60c34 = -6,-4,-2,0,2,4,6 on level 1, with bobs above, straddling and below the
priority line. Recipe: `render_test.sh NAME SCRIPT FRAME` (breaksave $172f8 -> run with
`--bp 1920a` + dump -> breaksave $17328 -> dump -> render_sim.py), e.g.
`./render_test.sh r45 <(printf "1 poke 60ca0 ff 1\n2 right 1\n") 45`.

---------------------------------------------------------------------------------------------------
## (g) Input semantics (joystick in port 2, keyboard)

| input | state 0 (walking) | notes |
|---|---|---|
| RIGHT / LEFT | walk 4 px/tick (world scrolls; player stays at screen x=$94). First tick in the other direction only turns round | stops only on 8-px boundaries; blocked by solid cells 16 px ahead |
| DOWN | on a tile-4 path spot (|$60c34| in 0,2,6): go down to level+1; elsewhere: crouch (frame $a), no movement | crouch does NOT protect from bullets |
| UP | on a tile-3 path spot: go up to level-1. Level 0: enter hut at a door column. Elsewhere: JUMP (16 ticks, 40 px high, keeps the horizontal direction held at take-off) | jumping avoids booby traps, enemy bullets and contact |
| diagonal up+left/right | = UP (vertical is checked first) | |
| UP+DOWN together | treated as no vertical | |
| FIRE (hold) | rifle shot every 2 ticks while ammo > 0; bullet 10 px/tick | also works in state 5 (hut) |
| SPACE (no direction) | throw grenade (if grenades > 0 and none in flight) | with a direction held SPACE does nothing (falls to FIRE check) |
| Left-Alt | choose-your-man screen (only while no enemy on screen) | |
| F1-F6 | cheat warps / invincibility, only with MEGA CHEAT active | |
| choose screen | UP/DOWN select living man, FIRE confirm | |
| trap door (village) | Y = go down (needs torch), N = stay | |
Walking is not possible while the own grenade is flying. During path/hut transitions, jump,
throw, hit, planting: no control.

---------------------------------------------------------------------------------------------------
## (h) Gameplay mechanics (jungle)

1. **Movement**: 4 px/tick horizontally (100 px/s). Jump: 16 ticks, y = $50 - arc (max 40 px up),
   covers 64 px. Path change: 24 ticks (12 on each level), requires standing on the gap of a tile-3/4.
2. **Soldiers (state 2)** enter from the left (x=1, facing right) or right edge (x=$130, facing left)
   with 5 or 6 px/tick, turn at trees (probe 32 px ahead / 16 px behind at their y). While their facing
   differs from the player's they may turn back (1/16 per tick) once near the far side (x u< $50 when
   walking left, x u>= $f0 when walking right); also 1/16 per tick while x in [$130,$136); removed
   when x u>= $136 (negative x included). Each tick with probability 1/32 they try to shoot: if no enemy bullet
   is flying, 50% kneel & fire (bullet at y+16, then 3 ticks kneeling), else fire walking (y+8).
   Enemy bullet speed 20 px/tick.  Villagers (level 0, T >= $33, 50% of spawns): never shoot,
   killing one = message + morale -$1200.
3. **Snipers** (levels 1-4, 1/16 of spawns): drop from (x=$90,y=0) with accelerating fall
   (1,3,5... px) — right onto the player column — then walk.
4. **Spider-hole VC** (1/4 of the remaining spawns, only when the bottom tile 2 columns ahead is
   0,1,3,4): at x=$100+$60c34, rises through 4 frames (3 ticks each), fires once to the LEFT
   (bullet y+$18), sinks again. Immune to rifle bullets; killable by a grenade in flight or avoided.
5. **Booby traps** (bob $f): spawned while scrolling with probability 1/4 per aligned step when none
   exists, at the edge of the screen ahead (+tile value quirk, §b.8); walking into x in [$8c,$9c) in
   state 0 = the current man is killed (hits := 3 then +1). Jump over them. Enemies jump over them.
6. **Spawn rate**: when no enemy exists, a spawn happens with probability $60cae/256 per tick;
   $60cae decays by 1 per tick to 7, +8 per rifle shot, +$20 per grenade (max $ff). No spawns on
   level 1 between cols 57 and 85 (except the bridge runner).
7. **Damage / morale / men**: 5 men, each 9 grenades, 144 rounds, 4 hits. Being hit (enemy bullet,
   contact, trap): death animation, "YOU'RE HIT", hits+1, morale -$800, dissolve, choose-your-man
   (you may keep the same man if he still has < 4 hits). A man with 4 hits is KIA. All 5 KIA or
   morale 0 = game over (kernel $f864). Morale starts at $9000 and decreases by 1 per tick
   (36864 ticks = 24.6 min of play if nothing else happens); HUD shows morale high byte/2 px of hearts.
8. **Score** (BCD): enemy +300, supply box +500, explosives +500, blowing the bridge +10000,
   (village: torch/map +500, trap door 1000 per living man).
9. **Items**: explosives box on level 4 cols 49-53 (appears at the right edge when arriving at col 49
   with $60c34==2; walk over it). Supply crates: after the bridge is blown, a killed soldier
   (not villager) drops one with probability 1/4; walking onto it gives randomly ammo +72
   (max 144) / medical (morale +$500, heal 1 hit) / food (morale +$200) / empty box, +500 pts
   except for the empty box.
10. **Random numbers**: kernel $f850: 32-bit LFSR at $12d70 (8 iterations of: if negative
    eor #$76b553; rol #1), returns the low byte; the vblank IRQ also adds d1 and 1 to the seed every
    frame, so results depend on timing (not reproducible across a port — use any PRNG with the same
    distribution: byte 0..255).
11. **The bridge sequence** (level 1): cols 69-74 show "SET THE EXPLOSIVES ON THE BRIDGE" while no
    charge is set. At col 72 with the explosives: planting (state 10, 5 ticks kneel) then the player
    walks right automatically to col 78 where the bridge (map cols 71/72, tiles $8c,$8d -> $95,$96)
    blows: knock-back animation without damage, +10000, bridge state 2. The broken bridge then blocks
    walking at world positions $238 (from the left) / $246 (from the right) with "PLEASE DON'T
    ATTEMPT SUICIDE!!". Reaching col 78 WITHOUT having planted: the player freezes (state 9), a VC runner
    enters from the left, kneels at x=$21 and fires 3 shots; the hit ends the game immediately:
    "YOU DID'NT BLOW UP THE BRIDGE, YOUR PLATOON HAS BEEN WIPED OUT!".
12. **Exit to the village / next section**: the jungle continues on level 0 (reached through up-paths
    from level 1) whose right half is the village; the section ends in a village hut trap door
    (needs the torch) -> kernel $f874 loads section 1 (tunnels).
13. **Hitboxes**: all x-only. Player bullet vs enemy: the bullet's swept segment [min(old,new),
    max(old,new)+4] must lie inside [enemy x, enemy x+24). Enemy bullet vs player: inside
    [$94,$ac). Contact: enemy x in [$80,$a8). Trap: trap x in [$8c,$9c). Crate/explosives pickup:
    object x in [$90,$98). No y tests anywhere (height only matters through the player state).

---------------------------------------------------------------------------------------------------
## (i) Sound / music calls (kernel $f86c = sfx(d0), $f868 = music(d0))
| call site | id | event |
|---|---|---|
| sec0_restart $17180 | music 2 | in-game music start |
| all_dead $19daa | music 3 | game-over tune |
| pf_spawn_bullet $17422 | sfx $82 | rifle shot |
| pf_grenade $17492 | sfx $0a | grenade throw |
| bullet_kill $1767a | sfx $85 | grenade explosion |
| trap_update $18ff6 | sfx $85 | booby trap explosion |
| enemy_killed_common $176c8 | sfx $80 | enemy hit |
| player_hit $1777e | sfx $81 | player hit |
| en_fire $18502/$1850a | sfx $84 (soldier) / $0a (runner) | enemy shot |
| en_drop_grenade $1856a | sfx $0a | first runner shot |
| hut_search $17ccc | sfx 0 | item found (village) |
Kernel $10c50 semantics: ids with bit7 set are "special" ($80,$81 play on 2 channels, $82+ ...),
see re/audio.

---------------------------------------------------------------------------------------------------
## (j) Open questions / uncertainties
- Exact real-hardware tick rate: RESOLVED with vAmiga (port/verify/timing.md): 2.77-2.79 frames/tick on identical
  games (2:~25 %, 3:~75 %, a few 4), against 2.00 in tools/amiga/emu. The code has no fixed-rate logic.
- Level 5 col 88 down-path (level 6 = pointer table overrun) — reachability not verified.
- Attribute byte values other than the solid ones are unused here — maybe used by other sections.
- The trap spawn x "tile value" offset (§b.8) looks like a bug (d0 high byte kept) but is the
  behaviour; negative $60c34 makes traps appear behind the player (x=$28..$2c) when walking right.
- $60cbc bridge-blast: player_hit is called, so an active invincibility cheat skips the knock-back
  (harmless).
- Choose-your-man text layout details are in kernel $408 format (re/kernel).
