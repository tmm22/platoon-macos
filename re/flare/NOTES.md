# FLARE section ("dugout at night") — Platoon (Amiga, Ocean 1988)

Module owner: flare. Load section 1 ("THE TUNNEL & FLARE SECTIONS", ADF tracks $54.., 27 tracks, loaded to $17000).
The flare screen is the second half of load section 1. It runs **after the tunnels**, reuses the tunnel engine's object
lists / blitter bob routines / HUD / message system, and on success loads section 2 (jungle & foxhole).
Everything below was verified in the emulator unless marked *(unverified)*.

Files in this directory:
- `labels.txt` (rdis labels), `comments.txt` (inline comments), `annotate.py` (regenerates `flare.s` = rdis listing restricted
  to the flare scope with labels + comments), `flare.s` (annotated listing).
- `extract.py` — extracts all flare assets from `re/platoon_darc.adf` into `assets/` (see §d). `python3 extract.py
  --compare out/play560.png 17 36 19f92 d7 75` renders background + crosshair and compares with an emulator screenshot:
  **0 differing pixels**.
- `verify_render.py PRE.bin POST.bin` — Python model of both bob blits (incl. the colour-15 occlusion); reproduces the
  back buffer written by the game **byte-exactly** (0 differing bytes on 6 captured iterations; 343–393 bytes differ if the
  occlusion rule is removed).
- `verify/pre{140,300}.bin`, `post{140,300}.bin` — RAM at $18ca8 / $18cac of the same iteration, made with
  `emu_mod/emu --load-state re/states/flare_play.state --script S` where S = `10 key 0x40 1`, `14 key 0x40 0`,
  `F breakdump 18ca8 preF.bin` (second run: `F breakdump 18cac postF.bin`), F = 140 / 300 (enemies + muzzle flash).
- `section1_full_with_flare_labels.s` — rdis of all section-1 code $17000-$19374 with these labels (for context).
- `emu_mod/` — private copy of the emulator with one extra script command `breakdump HEXPC FILE` (dump chip RAM when PC hits).
- `flare_cov.hist` — PC histogram of all my flare runs (idle, kills, flares, win, diagonals).
- scripts: `mk_start.txt`, `s5.txt`, `win.txt`, `kill.txt`, `fl.txt`, `misc.txt`, `q.txt` (see below).

Address conventions: a6 = $12dde (kernel globals, "$xx(a6)"), a5 = $1e(a6) = current platoon member record.
All section addresses are RAM; ADF offset = $73800 + (addr − $17000) (data used here is unmodified vs. the RAM dump except
where noted).

---------------------------------------------------------------------------------------------------------------------
## (a) Scope and how to reach it

Scope (code): `$17810-$178bc` (object list update/draw), `$17dd0-$17f7a` (player-hit, red fade, morale),
`$17f7c-$1832e` (normal + night bob blits), `$18922-$18978` (tunnel exit → flare hand-over), `$189c0-$19354` (flare core:
init, main loop, flare launch, palette sequencer, background decoder, crosshair, flare, enemy, muzzle-flash handlers),
`$17252-$17302` (exit text screens). Data: `$19374` message table, `$19e0a-$1a011` objects/tables/palettes, `$1e020`
anim table, `$1e220` bob bank, `$36242` background RLE.

### Normal route
Tunnels: walk into the EXIT room object (object message code $15, handler `$18922`). You need **8 flares** (`$2c(a6)`)
— each "BOX OF FLARES" gives +5, capped at 8 (handler `$18862`), so two boxes are required; with <5 you get "YOU WILL NEED
SOME FLARES.", with 5..7 "YOU NEED MORE FLARES" and you stay in the tunnels. With 8: +30000 score, "WOULD A COMPASS HELP?"
is printed if you have no compass (`$26(a6)==0`, purely a message), then `bra flare_enter ($18b0e)`.

### Cheat route (used for the states)
In the tunnel crosshair handler (`$178be`): if bit 1 of `$71(a6)` (=$12e4f) is set and the HELP key (raw $5f) is down →
`flare_cheat_entry $18afe` (sets flares = 9, prints msg $24 "LET'S GO TO THE FLARE SCREEN!", falls into `flare_enter`).
In the flare main loop the same cheat (HELP + bit1) jumps straight to the win (`$18e6c`).

State files (all created with the current tools/amiga/emu):
- `re/states/flare_start.state` — made from `section1_play.state` with `mk_start.txt`:
  ```
  1 poke 12e4f 2 1        # enable cheat bit
  5 key 0x5f 1            # HELP down
  10 key 0x5f 0
  20 poke 12e0a 8 2       # flares = 8 (the legit amount; cheat had set 9)
  20 poke 12e4f 0 1       # cheat bit off again
  21 save re/states/flare_start.state
  ```
  The CPU is inside `fade_out_and_clear` (tunnel screen fading, msg $24 on screen). The flare main loop starts ≈543
  frames later (after the three intro messages).
- `re/states/flare_play.state` = flare_start + 560 frames (`s5.txt`): main loop running, crosshair at ($d7,$75), night
  palette, no enemy yet (first spawn after 36 iterations ≈ +53 frames). RAM dump: `re/flare/ram_flare_play.bin`.
- Useful: `key 0x40 1` = SPACE (fires a flare); `fire 1` with crosshair still at the start position also fires a flare
  (it sits on the flare box).

---------------------------------------------------------------------------------------------------------------------
## (b) Code map

Notation: "iteration" = one pass of the flare main loop (normally 2 video frames, see §e). Kernel calls: `$f82c` queue
message d0; `$f834` per-iteration HUD+message update; `$f848` wait vblank; `$f84c` flip buffers; `$f850` RNG (d0.l = 0..255);
`$f85c` wait for pending copper-list swap; `$f868` start music d0; `$f86c` sound effect d0; `$f874` load next section;
`$f864` game over/hi-score; `$f878` set playfield palette (a0 → 16 words); `$f80c` add BCD score (4 bytes *preceding* a0);
`$f818` redraw hits HUD; `$f840` clear screen/HUD for text screens.

### Object record (18 = $12 bytes), used by both lists
| off | size | meaning |
|---|---|---|
| +0 | b | active (0 = free, $ff = active) |
| +1 | b | frame index into the anim table |
| +2 | w | x (playfield pixel, 0..319) |
| +4 | w | y (playfield row) |
| +6 | l | anim table base (8 bytes per frame: long = bob offset from $1e220, long = copy of bob header) |
| +a | l | handler (called with a3 = record) |
| +e | w | timer / counter |
| +10 | w | second counter / phase / spawn-slot offset |

Lists: **list1** `$19e0a` 8 records: [0] flare ($19e0a, handler `h_flare_rise`, anim $1e028, x=$d8), [1] $19e1c never
used, [2..6] $19e2e..$19e7a enemies (handler set on spawn), [7] $19e8c empty. **list2** `$19eac` 8 records: [0] crosshair
(handler `h_crosshair`, anim $1e020), [k] = muzzle flash of list1[k] (record + $90, handler `h_muzzle_flash`, anim
$1e048), [7] empty. Initial record contents come from the loaded data (see ram dump at $19e0a).

### Routines (pseudocode faithful to the assembly)

**flare_update_draw_objects `$17810-$178bc`** (shared engine routine, used only by the flare loop)
```
for list in (list1 via blit_bob_night, list2 via blit_bob_normal):
  for i = 7 downto 0:  a3 = list + i*$12
    if a3.active: call a3.handler(a3)          # handler may deactivate or change a3/others
      if a3.active: d0 = x<<16|y ; a1 = $1e220 + long[a3.anim + a3.frame*8] ; blit(d0, a1)
```

**blit_bob_normal `$17f7c`** (cookie cut; also used by the tunnels). In: d0 = x<<16|y, a1 = bob (header long
(wwords-1)<<16|(h-1), then 5 planes of wwords*2*h bytes: mask, bpl0, bpl1, bpl2, bpl3).
```
wait blit; BLTCON0=$0100 BLTCON1=0 A/B/C/DMOD=0 BLTA/B/CPT=0 BLTDPT=$3b742 BLTSIZE=$8c05  # clear 5600 bytes
w=wwords, h ; wait; BLTDMOD=2 BLTCON0=$09f0 APT=a1+4 DPT=$3b742 BLTSIZE=(5h)<<6|w      # copy bob, +1 zero word/row
dst = long[$3b402 + y*4] (= y*40) + $62(a6) + $3b3f8 + ((x>>3)&$fe) ; s = x&15
W = w+1 ; d2 = W*2*h (bytes/plane) ; mod = 40-2W ; size = h<<6|W
for plane p=0..3: wait; BLTCMOD=BLTDMOD=mod; BLTCON0 = s<<12|$fce ; BLTCON1 = s<<12
   APT=$3b742 (mask) BPT=$3b742+d2 (+continues) CPT=DPT=dst+p*$2000 ; BLTSIZE=size      # D = B | (~A & C)
```
FWM/LWM stay $ffff (set by kernel). `$3b3f8` is 0 in the flare section (cleared at `$18b70`).

**blit_bob_night `$180ee`** (list1 only: flare + enemies) — same as above but the mask excludes background colour 15:
```
clear 11200 bytes at $3b742 (BLTSIZE $8c0a) ; copy bob as above (if W-1 >= 8 the copy width uses W-8: unused here)
dst = rowtab[y] + $62(a6) + ((x>>3)&$fe)     (NO $3b3f8)
blit A=dst plane0 (AMOD=mod) -> D=$3cd22 (DMOD 0), BLTCON0=$09f0, BLTCON1=0, size h<<6|W   # temp = p0
3x: BLTCON0=$0ba0 (D=A&C): A=dst plane1/2/3, C=D=$3cd22                                    # temp = p0&p1&p2&p3
BLTCON0 = s<<12|$d30 (D = A & ~B), BLTCON1=0, A=$3b742 (mask, shifted by s), B=$3cd22, D=$3b742, all mods 0
4x cookie cut: BLTCON0=$0fca (no A shift), BLTCON1=s<<12, A=$3b742, B=planes, C=D=dst plane p, C/DMOD=mod
```
Net effect per pixel: `if mask && screen_now(px) != 15: screen(px) = bobcolour` where `screen_now` is the back buffer at
the moment of this blit (so objects drawn earlier in the same list count). Verified by `verify_render.py`.
Colour 15 is black ($000) in all night palettes: it is the foreground scenery (trees/sandbag silhouettes) that hides the
enemies and the rising flare.

**flare_cheat_entry `$18afe`**: `$2c(a6)=9; f82c($24)`; falls into flare_enter.

**flare_enter `$18b0e`**
```
fade_out_and_clear                          # $18a98
recolor_crosshair_c4                        # $189c0
for 8 slots: byte[$19f4e + 4k] = 0          # spawn slots free
for a0 = $19e2e.. 5 records (step $12): clr.b (a0); clr.b $90(a0);
      clr.w $e(a3); clr.w $10(a3); clr.b 1(a3); clr.b $91(a3)   # BUG: a3 (stale, = tunnel crosshair $19d32) not a0
f878($19f92)                                # palette night0 (= long[$19f76])
SP = $400                                   # tunnel engine is abandoned; exits are jumps
f868(6)                                     # music 6
decode_background                           # $18e92
$3b3f8 = 0 ; $3b226 = $24 ; $3b228 = $90
copy_background; f84c; copy_background; f84c     # both buffers hold the scene
$3b222 = 0 ; palette_step                   # sets night0 again, $3b222 = 4 (no side effects: $3b231 stays 0)
for msg in $25,$26,$27:  f82c(msg); do { 3x f848; f834 } while $48(a6) != 0
-> flare_main_loop
```
(`$3b224`, `$3b231` etc. are zero from the tunnel init clear of $3b220..$3b3fb at `$17006`.)

**flare_main_loop `$18bd8`** (one iteration)
```
if ($71(a6) & 2) && key($5f): goto flare_win                 # HELP cheat
f85c                                                          # wait until the previous flip's copper swap happened
copy_background                                               # clean scene -> back buffer (CPU, 23 KB)
if --$3b226 (word) == 0:
    $3b226 = ($3b228 + $3b22a) >> 2                          # unsigned word add, lsr
    e = first record among $19e2e,$19e40,$19e52,$19e64,$19e76 with active==0
    if none: $3b226 = 1
    else:
      s = ((rnd() >> 4) & 7) * 4 ; start = s
      while byte[$19f4e + s] != 0: s = (s+4) & $1f ; if s == start: {$3b226 = 1; goto objs}
      byte[$19f4e+s] = $ff ; e.x = word[$19f50+s] ; e.$10 = s
      e.y = $40 + ((rnd() >> 4) & 7) ; e.active = $ff ; e.frame = 0 ; e.handler = h_enemy_rise   # e.$e NOT reset
objs:
flare_update_draw_objects
if $3b236: goto exit_back_to_tunnels ($172f6)                # a member died
if $2e(a6) == 0: goto exit_morale_zero ($17262)
if $3b235: goto exit_platoon_destroyed ($17252)
if $3b231 == 0:
    if !key($40 SPACE): goto end
    fire_flare
if byte[$19e0a] (flare rising) == 0:
    if --$3b224 (byte) == 0:
        palette_step                     # returns d0 = new $3b222
        $3b224 = byte[$19f6e + (d0 >> 2)]
end: f834 ; f84c ; loop
```

**fire_flare `$18d22`** (from SPACE, or fire on the flare box)
```
if $3b231: return
$2c(a6) -= 1 ; flare.active=$ff ; flare.frame=0 ; flare.y=$6e   (x stays $d8, flare.$10 phase NOT reset)
f86c($0a) ; $3b231 = $ff ; $3b224 = 1
```
Note: no check that flares > 0 is needed because the section ends when the count reaches 0 at the end of a cycle.

**palette_step `$18e3a`**
```
f878(long[$19f76 + $3b222]) ; d0 = $3b222 + 4
if d0 == $1c: d0 = 0 ; $3b231 = 0 ; if $2c(a6) == 0: goto flare_win
$3b222 = d0 ; return d0
```

**flare_win `$18e6c`**: `f82c($28 "WELL DONE,"); f82c($29 "YOU MADE IT THROUGH THE NIGHT"); fade_out_and_clear;
jmp $f874` (kernel: music 3, "LOADING... THE JUNGLE & FOXHOLE SECTIONS", loads section $6e(a6)=2, `$6e(a6)++`, starts it).

**copy_background `$18d5e`**: 144 rows × 10 longs × 4 planes from $68000 (+p*$2000) to `$62(a6)` (+p*$2000).

**decode_background `$18e92`** (RLE, see §d): src $36242 → $68000.

**fade_out_and_clear `$18a98`**: copy current palette (`$5a(a6)` → $3b722, set). Repeat {3× f848; fade_step_down;
f834} while `$48(a6)` (message queue count) ≠ 0 or `$18a40` ≠ 0. fade_step_down (`$18a42`): each of 16 colours: B−1 if
B>0, G−$10 if G>0, R−$100 if R>0, `$18a40` = $ff if anything changed; set palette. Then clears $70000 and $78000,
4 planes × $1680 bytes (144 lines) each.

**recolor_crosshair_c4 `$189c0`**: for bob offsets long[$1e020] (crosshair), long[$1e048], long[$1e050] (muzzle flash
frames): with psz = wwords*2*h, for every word of the mask: bpl0 := 0, bpl1 := 0, bpl2 := mask, bpl3 := 0 (colour 4 =
$777 grey in all night palettes → always visible). This is an in-place modification of the bob bank (the tunnels' init
`$1897a` recolours the same bobs to colour 1 when the tunnel section restarts).

**h_crosshair `$19048`** (list2[0])
```
d0 = joy()                                                   # $410: b0 down b1 right b2 up b3 left b7 fire
if (d0 & $f) == 0: speed = 4 (word $1a0ae) ; step = (d1 unused)   # no movement; d1 = d0&$f = 0 (unused)
else: step = speed >> 1 ; if speed < $f: speed += 2        # step sequence 2,3,4,5,6,7,8,8...
$3b22f = 0
if fire:
   if $cf <= x <= $df and $6f <= y <= $78: goto fire_flare  # (tail branch: rts from there, no movement this iteration)
   if ammo ($2(a5)) != 0: $3b22f = $ff ; $3b228 = max(0, $3b228 - 2) ; shot_jitter_flare
if up:    y -= step ; if y > 9: goto RIGHT_TEST (BUG: skips down and left) else y = $a
if down:  y += step ; if y >= $79: y = $78
if left:  x -= step ; if x <= $1d: x = $1e
RIGHT_TEST: if right: x += step ; if x >= $10f: x = $10e
```
All compares are signed word compares. Fire is level-triggered: holding fire shoots every iteration (1 bullet each).
Verified: up+left moves only up; up+right, down+left, down+right move diagonally.

**shot_jitter_flare `$18fba`**: `ammo -= 1; f86c($83); x += rnd&7, clamp x < $10f else $10e; x -= rnd&7, clamp x > $1d
else $1e; y += rnd&7, clamp y < $79 else $78; y -= rnd&7, clamp y > 9 else $a` (4 RNG calls, in that order).

**h_flare_rise `$1914c`** (list1[0]): `y -= $14; if y < 0 {active = 0; return}; $10 = ($10+1)&1; if $10 == 0: frame++`.
From y=$6e it is drawn 5 times (y = 90,70,50,30,10) and disappears on the 6th iteration. Frames: (0,1,1,2,2) or
(1,1,2,2,3) depending on the $10 phase left by the previous flare (5 toggles per flight → alternates).

**h_enemy_rise `$19174`** (state A, "approaching": frames 0,1,2 grow larger)
```
enemy_hit_test ; $e = ($e+1)&7 ; if $e != 0 return ; frame++ ; if frame == 3: handler = h_enemy_aim
```
**h_enemy_aim `$191a2`** (state B, frame 3): `enemy_hit_test; $e = ($e+1)&$f; if $e != 0 return; handler = h_enemy_shoot;
f86c($84); enemy_muzzle_flash` → exactly 16 iterations (A always leaves $e = 0).

**h_enemy_shoot `$191cc`** (state C, frame 3)
```
enemy_hit_test ; $e += 1
i = $3b222 >> 2 ; t = |i - 3| + 1 ; thr = t*16 - 13           # i=0..6 -> thr 51,35,19,3,19,35,51
if $e > thr: goto enemy_hits_player                           # signed compare (cmp.w $e,d0; blt)
if ($e & 7) == 0: f86c($83) ; enemy_muzzle_flash
```
**enemy_muzzle_flash `$19212`**: companion (a3+$90): active=$ff, x = a3.x − $d, y = a3.y + $b (frame/$10 NOT reset).

**enemy_hits_player `$1922a`**: `byte[$19f4e + $10] = 0; active = 0; $3b226 = $24; $3b228 = $90; $3b22a = 0;
$3b231 = $ff; bra player_hit_flare` (the companion flash is not removed).

**h_enemy_dying `$1925a`**: `$e = ($e+1)&1; if $e != 0 return; frame++; if frame != 8 return; active = 0; $3b22a += 3;
free slot; score += 300 (f80c($1a0a4) → BCD 00000300 at $1a0a0)`. Shows frames 5,6,7 (2 iterations each; first
depends on phase).

**h_muzzle_flash `$192a0`**: `$10 = ($10+1)&1; if $10 != 0 return; frame = (frame+1)&1; if frame != 0 return; active = 0`
→ lives 2–4 iterations depending on leftover frame/$10.

**enemy_hit_test `$192c4`**
```
ax = cross.x + 9 ; ay = cross.y + 9          (crosshair = list2[0], state from the PREVIOUS iteration's handler)
if x > ax or x+$1e < ax or y > ay or y+$19 < ay: return      # inclusive box 31x26 (upper body)
if $3b22f == 0 or ammo == 0: return                          # ammo checked AFTER the shot decremented it
frame = 5 ; $e = 0 ; handler = h_enemy_dying ; f86c($80) ; $3b22e = $ff (write-only flag)
```
Consequences: list1 (enemies) runs before list2 (crosshair), so a shot fired in iteration N is tested against enemies in
iteration N+1 at the post-jitter/post-move crosshair position (the position drawn in iteration N). Your **last bullet
can never kill** (ammo is already 0). One shot kills every enemy whose box contains the point. Enemies are hittable
in total darkness and in every state A/B/C (dying enemies are not tested).

**player_hit_flare `$17dd0`** (flare variant of the tunnel hit routine `$17d1a`)
```
$3b22e = 0 ; f86c($80) ; f82c($20 "YOU'RE HIT") ; hits($4(a5)) += 1 ; f818
if hits == 4:
   red_fade ($17e60: 16 colours of $1a012 (tunnel palette copy!) step R+$100 ≤ $f00, G−$10, B−1, 3 vblanks per step,
             until all $f00; returns immediately because hits==4)
   f82c($1b "KILLED IN ACTION")
   if $22(a6) == 1: $3b235 = $ff (last man)          else: $22(a6)=1 ; a5 = $1e(a6) = a6+6 ; $3b236 = $ff
do { f834 ; f848 } while $48(a6) != 0                # game frozen while the messages show (~46 frames)
f818 ; morale_sub($c00) ; f834 ; f82c(0 "GET GOING !")
```
**morale_sub `$17f6e`**: `$2e(a6) -= d0` (word, unsigned); on borrow `$2e(a6) = 0`.

**tunnel_exit_handler `$18922`**, exits `$17252/$17262/$172f6`, text screens `$17272/$1727e`: see labels/listing.
`exit_back_to_tunnels` shows "YOU DIDN'T MAKE IT ! ONLY ONE OF YOUR PLATOON MEMBERS REMAINS AT THE ENTRANCE TO THE
TUNNELS. YOU HAVE ONE MORE CHANCE / TAKE CONTROL OF YOUR MAN" (music 3, wait fire, music 4) and restarts the tunnel
section at `$170c4`, which resets flares (`$2c`) and compass (`$26`) to 0 and un-collects all room items.

---------------------------------------------------------------------------------------------------------------------
## (c) RAM variables (flare-relevant)

| addr | size | meaning | init / writers / readers |
|---|---|---|---|
| $2c(a6)=$12e0a | w | flares | tunnels (+5 per box, max 8); cheat 9; fire_flare −1; palette_step tests 0; HUD bar via f834 ($54(a6)≠0 → flare bar = flares×8 px) |
| $2e(a6)=$12e0c | w | morale ($9000 full; HUD bar = hi byte/2 px) | −$c00 per hit; 0 → game over |
| $1e(a6) | l | a5 = current member record (a6+0 or a6+6) | |
| $22(a6) | w | current member index (0/1) | |
| a5+0 | w | grenades (not used here) | |
| a5+2 | w | ammo (bullets, $90 = 144) | shot −1; HUD bar = ammo/2 px |
| a5+4 | w | hits taken (0..4) | +1 per hit; 4 = killed |
| $48(a6) | w | pending message count | kernel |
| $62(a6) | l | back buffer ($70000/$78000) | f84c toggles bit 15 |
| $71(a6) bit1 | b | cheat enable (HELP) | |
| $3b222 | w | next palette index (0,4,..,$18) | init 0→4; palette_step |
| $3b224 | b | iterations until next palette step | fire_flare=1; table $19f6e; starts 0 (→ 255 if a hit starts a cycle before any flare) |
| $3b226 | w | spawn countdown (iterations) | init $24; reload ($3b228+$3b22a)>>2; 1 = retry |
| $3b228 | w | spawn base | init $90; −2 per shot (min 0); $90 on hit |
| $3b22a | w | kill bonus to spawn interval | +3 per kill; 0 on hit |
| $3b22e | b | enemy-killed flag (write-only here) | |
| $3b22f | b | "fired this iteration" | h_crosshair |
| $3b231 | b | light cycle running (blocks new flares and the SPACE test) | fire_flare, enemy_hits_player set; palette_step clears |
| $3b235 / $3b236 | b | all dead / member switched | player_hit_flare |
| $3b3f8 | l | x byte offset added by blit_bob_normal (0 here) | |
| $1a0ae | w | crosshair speed (4..16) | h_crosshair |
| $18a40 | w | fade-changed flag | fade_step_down |
| $19f4e+4k | b | spawn slot k used ($ff) | spawn / free on death or hit |
| $3b742.. | 11200 B | blitter work buffer (bob copy, mask) | |
| $3cd22.. | | colour-15 temp mask (inside the above) | |
| $3b722 | 32 B | fade palette copy | |
| $68000 | 4×$2000 | decoded clean background (144 rows used) | |
| $70000/$78000 | 4×$2000 each | screen buffers, 40 bytes/row, 144 rows; HUD at $79680.. (plane stride $2000) | |
| $12d70 | l | RNG seed | f850 + vblank perturbation |

---------------------------------------------------------------------------------------------------------------------
## (d) Data formats (all extracted by extract.py)

- **Background RLE `$36242`** (17098 bytes, ends $3a40c). Control byte b: b ≤ $7f → copy b+1 literal bytes; b = $80 →
  no-op; b ≥ $81 → repeat next byte ((−b)&$7f)+1 times. Output order: row0 plane0 (40 bytes), row0 plane1, row0 plane2,
  row0 plane3, row1 plane0, … 144 rows, written to $68000 + plane*$2000 + row*40. Decoding stops after exactly 144 rows
  (the routine pops its return address). → `assets/bg_pal0..3.png`, `bg_sequence.png`.
- **Palettes** (16 × $0RGB words): night0 `$19f92` (dark), night1 `$19fb2`, night2 `$19fd2`, night3 `$19ff2` (brightest).
  Sequence table `$19f76` (7 longs): night0,1,2,3,2,1,0. Duration table `$19f6e` (bytes): 1,1,1,1,70,50,30,(10 unused),
  indexed by new $3b222>>2. Colours 4 ($777) and 15 ($000), 0 ($000), 2 ($774) are constant in all four.
  → `assets/palettes.json` (also tunnel palettes $1a012/$1a032 and HUD palette $1a06e).
- **Anim table `$1e020`**: 36 entries × 8 bytes (long offset from $1e220, long header copy) up to $1e13f.
  Bob at $1e220+off: long (wwords−1)<<16|(h−1), then mask, bpl0..bpl3 (each wwords*2*h bytes).
  Frames used here: idx0 crosshair (2w×18, recoloured to colour 4; hot spot +9,+9); idx1..4 flare (1w, 14/11/8/5
  rows, anim base $1e028); idx5/6 muzzle flash (2w×20, recoloured, base $1e048); idx12..19 enemy (2w×49, base $1e080):
  0,1,2 approach (growing), 3 aiming/shooting, 4 unused, 5,6,7 death. → `assets/bobs/frame_XX.png` (all 36, alpha =
  mask, lit palette), `bobs_flare_used.png`, `recolored_color4.png`, `tables.json`.
- **Spawn slots `$19f4e`**: 8 × {byte used, byte 0, word x}: x = $20,$40,$60,$80,$a0,$c0,$e0,$100.
- **Messages** (`$19374`: $2a pointers; each: byte column, byte row ($12), text, $ff). Flare ones: $20 YOU'RE HIT, $24
  LET'S GO TO THE FLARE SCREEN!, $25 YOU ARE IN A DUGOUT AT NIGHT, $26 THE ENEMY SUSPECT YOUR POSITION, $27 AND WILL
  ATTACK, $28 WELL DONE,, $29 YOU MADE IT THROUGH THE NIGHT, $1b KILLED IN ACTION, $00 GET GOING !. → `messages.json`.
- **Score constants**: BCD longs $1a0a0 = 00000300 (kill), $1a0a8 = 00030000 (exit bonus, a0=$1a0ac). f80c adds the 4
  bytes *before* a0 to the score at $4e(a6) with ABCD.

---------------------------------------------------------------------------------------------------------------------
## (e) Per-frame flow and timing

- Main loop is not vblank locked: it waits only for the previous flip (`f85c`, flag $12d74 cleared when the level-6
  CIA-B TOD raster interrupt swaps COP1LC at line ≈204). The CPU background copy (~160k cycles) makes one iteration take
  **2 frames** normally in tools/amiga/emu (measured distribution over 215 iterations: 174×2, 22×1, 18×3 frames); ~2.5
  on a real A500 (vAmiga, port/verify/timing.md). All durations above are in iterations.
- Level-3 vblank (kernel `$10eac`): music driver `$280e`, RNG seed `$12d70 += d1(interrupted) + 1`, keyboard checks,
  sets `$56(a6)` for `f848`. Message/HUD animation happens in `f834`, called once per iteration.
- Blocking waits inside the section: intro messages; `player_hit_flare` waits for the message queue (~46 frames freeze
  per hit); red fade on the 4th hit; fades at start/end.
- Measured timeline (flare_play, SPACE pressed): flare launched on the next iteration (`fire_flare` BP); first palette step 12 frames later (6 iterations);
  night1/2/3 on 3 consecutive iterations; night3 for 70 iterations (140 frames), night2 50, night1 30, then night0 and
  the cycle ends (≈159 iterations ≈ 6.4 s without hits).

## (f) Rendering

- Display (kernel copper lists `$115d0` / `$116a8`, swapped): 4-bitplane lowres, BPLCON0 $4200, DIWSTRT $3c71,
  DDFSTRT $30/DDFSTOP $c8, modulos 0. Playfield bitplanes = buffer ($70000 or $78000, planes +$2000), palette colours 0–15
  at `$115fa` (written by f878). WAIT line $cc: HUD bitplanes $79680/$7b680/$7d680/$7f680 and HUD colours (`$11666`).
  List B = playfield pointers + COPJMP2 into the shared tail at $115f0. Playfield = 320×144, top-left at screenshot
  pixel (17,36) (verified by pixel-exact compare).
- Double buffering: draw into `$62(a6)`, `f84c` flips (xor $8000, request copper swap). Each iteration starts from the
  clean background copy (no dirty rectangles).
- Draw order: list1 entries 7..0 (enemies 6..2, then flare) with the night blit, then list2 entries 7..0 (muzzle flashes,
  crosshair) with the normal blit. No clipping (x up to $10e+32 stays inside the 320-px row; y ≤ $78+18 < 144).
- "Night": done purely with palettes; enemies are drawn every iteration with their real colours, which are near-black
  in night0. Blits used: see §b (clear, copy, AND-collect colour 15, mask &= ~temp, 4× cookie cut).

## (g) Input

- Joystick port 2 via `$410`: bit0 down, bit1 right, bit2 up, bit3 left, bit7 fire. Crosshair speed accelerates while
  any direction is held (step 2,3,…,8 px/iteration), resets to 4 when released. Up+left moves only up (bug).
- Fire (level-triggered): shoot (if ammo) every iteration held; on the flare box ($cf..$df, $6f..$78 crosshair
  top-left, i.e. the box graphic at the bottom middle) → fire a flare instead (no bullet).
- SPACE (raw $40): fire a flare (only tested while no light cycle runs).
- HELP (raw $5f) with `$71(a6)` bit1: cheat (tunnels: go to flare screen with 9 flares; flare screen: instant win).

## (h) Gameplay rules

- Goal: survive until the light cycle that follows your **last flare** ends → WELL DONE / YOU MADE IT THROUGH THE NIGHT →
  load section 2. With the normal 8 flares you must go through 8 cycles; there is no time limit otherwise — while no
  cycle runs nothing advances, so you must fire flares to progress.
- Flares: one at a time; a flare cannot be fired while `$3b231` is set (cycle running, including a hit-triggered cycle).
- Enemies: max 5 alive (records 2..6), spawn at one of 8 fixed x columns (random start + linear probe), y = 64..71;
  approach (3 frames × 8 iterations), aim 16 iterations, then shoot: muzzle flash every 8 iterations and hit you after
  thr+1 iterations, thr from the *current light phase* (i = $3b222>>2 = index of the NEXT palette): 35 before the first
  flare (i=1, night0 shown), 19 during the 1-iteration night1 rise (i=2), 3 during the 1-iteration night2 rise (i=3),
  19 while brightest (i=4), 35 in the night2 fade (i=5), 51 in the night1 fade (i=6) and in the dark after a flare (i=0).
  Verified: dark before first flare -> enemy entered state C at f1712 and hit at f1784 (36 iterations).
- Spawn interval (iterations) = (base + killbonus)/4 with base = $90 − 2×shots (≥0), killbonus = 3×kills; both reset on
  every hit. Quirk (verified): if the interval evaluates to 0 the counter wraps to 65535 → no further spawns until the
  on-screen enemy hits you.
- Getting hit: −morale $c00, "YOU'RE HIT" (+freeze), resets spawn difficulty, **starts a light cycle** (sets $3b231; if no
  flare was fired yet $3b224 counts down from 0 → 255 iterations before the palette moves, blocking flares that long);
  if that cycle ends with 0 flares you also win (verified with flares poked to 0 and hits/morale refreshed: hit at
  f1784 started the cycle, first palette step f2652, win f3048). 4 hits = man killed: first man → back to the tunnels (flares and items
  reset); second man → "YOUR PLATOON HAS BEEN DESTROYED" game over; morale 0 → "WITHDRAWN FROM ACTION" game over.
- Kill: +300 points, death animation, +3 kill bonus. Ammo 144 bullets per man shared with the tunnels; no pickups here.
- RNG (`$f850`): 8× {if seed<0: seed ^= $76b553; seed = rol(seed,1)}, returns low byte; used for spawn column, spawn
  y, and 4× per shot for crosshair jitter. Seed is also perturbed each vblank by the interrupted d1 register (+1), so
  exact sequences are not reproducible from logic alone.

## (i) Sound / music calls

| call site | call | when |
|---|---|---|
| $18b64 | f868(6) | music 6 at flare-screen start |
| $18d46 | f86c($0a) | flare launched |
| $18fc2 | f86c($83) | player shot (every held-fire iteration) |
| $191be | f86c($84) | enemy's first shot (enter state C) |
| $19206 | f86c($83) | enemy shot every 8 iterations in state C |
| $1932a | f86c($80) | enemy killed |
| $17dd6 | f86c($80) | player hit |
| $17272 | f868(3), then f868(4) after fire | exit text screens |
| $f874 | f868(3) | loading section 2 |
(`f86c` ids ≥ $80 are played by the kernel on two channels — see audio/kernel modules.)

## (j) Open questions / uncertainties

- Iteration length on real hardware: RESOLVED with vAmiga: ~2.5 frames (2:57 % 3:35 % 4:7 %) against ~2.0 in the
  Musashi-based emulator, which ignores DMA contention and blitter time (port/verify/timing.md).
- The exact message timing/HUD code (`f82c/f834/f818`) and the level-6 raster interrupt belong to the kernel module.
- `$3b22e` is written but never read inside section 1 (maybe read by nothing).
- The init bug at `$18b3a` writes zeros into the tunnel crosshair record via stale a3 (harmless).
- Width-≥8 adjustment in the night blit copy (`$1813c`) never triggers with the flare bobs; its purpose is unknown.
- Enemy frame 4 (idx16) is never displayed in this section.
