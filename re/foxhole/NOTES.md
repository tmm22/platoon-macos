# Platoon (Amiga) — module `foxhole`: the bunker room ("foxhole"), Sgt Barnes, grenades, and the END of the game

Author: re/foxhole agent. Scope: load section 2 ("THE JUNGLE & FOXHOLE SECTIONS", tracks $6f..$9e → $17000),
everything that is specific to the final **bunker room** (room type $10 — the game's "foxhole"): Barnes, the
grenade throw/arc/landing/hit rules, Barnes' aimed shots, the win check (enter the bunker door), and **all end
sequences of the game** (won / napalm / platoon destroyed / second man) up to the jump into the kernel's
GAME OVER → hiscore → title flow. The shared section-2 engine (room maze, soldiers, mines, wire, player
movement, object system, bob renderer) is owned by `re/finaljungle` — it is summarised here only as far as the
bunker room depends on it (names follow finaljungle's labels).

**What the "foxhole" really is.** There is no night-time foxhole attack in the Amiga version. The last part of the
game is: 2-minute jungle maze (find the bunker) → the bunker room: Sgt Barnes lies in the bushes at the far end of
the path shooting at you; you must hit him 5× with grenades, then walk to the bunker door → "YOU MADE IT!" →
GAME OVER/hiscore. Messages 12/13 ("JUNGLE CONFRONTATION", "KILL BARNES WITH THE GRENADES.") exist but are never
queued (no code references; verified by breakpointing `k_queue_text` through a complete bunker fight).

Files: `NOTES.md` (this), `labels.txt` (finaljungle snapshot + foxhole overrides; FOXHOLE-tagged),
`comments.txt` (inline comments), `gen_listing.py` → `foxhole.s` (rdis listing of $17000-$19020),
`foxhole_cov.hist` (coverage of the bunker fight, endings and the route), `extract.py` → `assets/`,
`probe.py` (run a script from a state and print object slots every N frames). Work files in `work/`.

Conventions: hex unless obviously decimal. "tick" = one main-loop iteration (normally = 1 video frame, 50 Hz,
§e). `a6 = $12dde` (kernel globals), `a5` = current man record (`$1e(a6)`), `a3` = current object slot in
handlers. `rand()` = kernel `$f850` (d0 = 0..255). `sfx(n)` = `jmp $f86c`; `msg(n)` = `k_queue_text $f82c`
(table `$4a(a6)` = `$189e0`). Signed compares: `blt/bgt/ble/bge`; unsigned: `bcs/bcc` (marked `u<`, `u>=`).

---------------------------------------------------------------------------------------------------------------
## (a) Scope and how to reach it in the emulator

Section 2 is loaded 1:1: **RAM A == ADF offset A − $17000 + $98a00** (= A + $81a00) for $17000..$58fff.
Bunker rooms = the three map cells of type $10: rooms **14, 24, 34** (column 4, rows 1-3 of the 10×12 map). They
are identical (same picture 10, same Barnes); a bunker room has **no exits** (exit mask 0), so once inside you stay.

### States (in `re/states/`)
| state | content | how made |
|---|---|---|
| `foxhole_start.state` | first main-loop iteration (pc=$17118) in bunker room **14**, fresh section start: man 0, 9 grenades, morale $9000, timer 2:00. **Code patched**: the start-room immediate at `$18174` = `$000e` (instead of `$0069`), so a "second chance" restart in this state also goes to room 14 | boot script below |
| `foxhole_barnes_dead.state` | same fight 142 frames later: Barnes killed by 5 grenades (4 left), player at (x $a0, y 22). Walk up to win. Shows the phantom-grenade quirk (§h.6) | `work/win.txt` from foxhole_start |
| `foxhole_route_arrive.state` | **unpatched** game, reached by walking the maze from the section start (route below) into room **34**; timer 1:30 left, morale $9000 | `work/route_boot.txt` |

Boot script → `foxhole_start.state` (frames absolute from power-on, events sorted; `work/mkstart.txt`):
```
300 fire 1
305 fire 0
350 poke 12e4c 2 2          ; section index 2
600 fire 1
605 fire 0                  ; skip "ENTERING THE COMBAT ZONE"
880 poke 18174 e 2          ; while "!THE JUNGLE! ... PRESS FIRE WHEN READY" waits: start room $69 -> $0e (room 14)
900 fire 1
905 fire 0
906 breaksave 17118 ../../states/foxhole_start.state      ; hits at frame 924
```
Any room can be started the same way (poke the word at $18174 = room index 0..119; the start heading is always
`$18f44` = $010afff6).

Natural route from the start room $69 (verified, `work/route_boot.txt`, from section2_play.state `work/route.txt`):
exits **L R L R L R L R R L R L R L** (rooms 104 94 93 83 82 72 71 61 62 52 53 43 44 → **34**). An exit is taken
by standing at depth y ≥ $5a and pushing past the left/right path edge. The scripts teleport the player to
(x $a0, y $5f) before each exit and disable `player_hit` (`poke 17d68 4e75`, restored to `$4239` on arrival).

Useful pokes (from foxhole_start): `1 poke 57f5a 7fff 2` = Barnes does not shoot for 32767 ticks;
`poke 12e0c 0 2` = morale 0; `poke 12e4a 3 2` = timer 00:03 (napalm); `poke 12de2 3 2` = man 0 has 3 wounds;
`poke 12e4f 2 1` + `key 0x62 1` = MEGA-CHEAT CAPS-LOCK instant win. (Emulator `key` takes `%i`: write hex as `0x..`.)

Minimal win script from foxhole_start (`work/win.txt`, verified): hold UP frames 1-10 (y 0→22), FIRE at 12, 40,
68, 96, 124 (5 hits; Barnes' timer poked off), UP from 160 to 220 → `game_won` at frame 197, text at ~205,
FIRE at 420 → GAME OVER → "ENTER YOUR NAME".

---------------------------------------------------------------------------------------------------------------
## (b) Code map (foxhole-relevant routines; addresses = section 2 RAM)

Ranges owned by this module: `$17118-$17226` (main loop incl. time-up), `$175e8-$1773c` (fade/text screens),
`$179fa-$17a92` (bunker part of the player handler), `$17be2-$17c1d` (goal/win), `$17cfc-$17d66`
(enemy bullet vs player), `$17d68-$17f31` (hit/death/endings), `$17f68-$18079` (Barnes' fire),
`$18282-$18419` (Barnes setup, Barnes, grenades, arc table), `$186dc-$18717` (explosion),
data `$18ae7-$18dee` (messages 12-16, ending strings), `$189dc` hints.

### b.1 `main_loop` $17118-$17186 (shared; shown because the bunker fight and all endings hang off it)
```
main_loop:
  k_hud_update()                                  ; $f834 (score, text tick, bars, TIME)
  if ($71(a6) & 2) and keytest($62 CAPS LOCK): goto game_won        ; MEGA CHEAT only  [verified]
  idle_shot_tick()      ; $17342  returns at once in the bunker room ($57f44 == 0)
  soldier_spawn_tick()  ; $17498  returns at once in the bunker room
  hint_tick()           ; $17228
  k_wait_swap()         ; $f85c: spin until the level-6 split IRQ latched the previous swap
  if $2e(a6) == 0: goto morale_zero              ; tst.w (morale word)
  bg_restore()          ; $17558
  objects_update_draw() ; $1773e (all handlers, depth sort, draw)
  k_swap()              ; $f84c
  d0 = $6c(a6).w (BCD mm:ss); if d0 == v_last_time($17226): goto main_loop
  v_last_time = d0
  if $6c(a6).b (minutes byte, big-endian high byte) == 0: v_hints[1] ($189dd) = 5   ; "NOT LONG BEFORE THE NAPALM"
  if $6c(a6).w != 0: goto main_loop
time_up ($1718a):  (see b.13)
```

### b.2 `hint_tick` $17228
```
$57f56.w -= 1; if result >= 0 (bpl): return
$57f56 = (rand() & $7f) + $64                     ; 100..227 ticks
msg( v_hints[rand() & 3] )                        ; v_hints = $189dc: [0]=$0b "A COMPASS WOULD HELP !" (0 "GET GOING!"
                                                  ;  if $26(a6) compass carried), [1]=1 "KEEP MOVING!" (5 in the last
                                                  ;  minute), [2]=6 "GO GET 'EM", [3]=7 "STAY ALERT"
```
`$57f56` is zeroed on every room entry → a hint is queued on the first tick in every room (seen: msg 6 at the
first bunker tick). Two rand() calls per hint.

### b.3 Room entry into a bunker room: `room_enter` $170a8 → `trans_right/left` → `room_setup` $181d2 → `room_setup_bunker` $18282
(room_enter/room_setup are shared; summary)
```
room_enter(a0 = transition):  sp=$400; clear longs $57e20..$58f9f; copy 45 longs $18df0 -> $57e22 (slots 0..9);
    bytes $57f90..$5808f = $ff; $54(a6)=0; d0=1; jsr (a0)
  trans_right $18192: $2a(a6)=($2a+1)&3; d0 = room + dirs.b0 ; d1 = dirs rol 8     (dirs = long $18f40)
  trans_left  $181b4: $2a(a6)=($2a-1)&3; d0 = room + dirs.b2 ; d1 = dirs ror 8
  room_setup: $18f40 = d1; room $18f1c = d0; clr.w $68.l (BUG: absolute $68 = high word of the level-2 vector,
      already 0 -> harmless; timer keeps running); type = map[$18ea4 + room]; $57f45 = type;
      $57f44 = exits[$18f2e + type]; pic = $18f1d[type]; $57f42 = rand()&7 (6->3, 7->4); $19012 = $32;
      if $57f44 == 0: room_setup_bunker
room_setup_bunker ($18282):
      slot4 ($57e6a): byte0 = $32 (active flag AND hit points), long $e = 0 (e, frame, b11 = 0),
                      x = $96, y = $69, handler = obj_barnes $182b0, gfx = $47628; anim byte stays 0 (init table)
      room_load_picture(10)  ; $17604: start palette fade-out hook, RLE -> $68000, wait fade end,
                             ; clear_play_and_pal (rows 0..143 of both buffers, top pal $18fc2, HUD pal $176be),
                             ; room_spawn_objects: list $189d6 = $ffff -> none
room_enter_done ($170f4): $57f5c=$64; $57f58=$14; $57f5a=$14 (Barnes' first shot after 21 ticks);
      $57f64=$80; st.b $68(a6) (timer on) -> main_loop
```
Slot state after entry: slot 0 player {act $ff, x $a0, y 0, gfx $47400, handler $179fa}, slots 1-3 player
bullets (inactive, unused here), slot 4 Barnes, slots 5-6 soldier templates (inactive, never spawned here),
slots 7-9 enemy bullets (inactive, gfx $476b0, handler `obj_ebullet` $17cfc), slots 10-15 zero (grenades use
10-12 and get gfx/handler at throw).

### b.4 `obj_player` $179fa — bunker-specific part (a3 = $57e22, a5 = man)
```
$57f46.l = (x,y) of the player; $19014 = $19012          ; saved for blocking objects (not used here)
if $57f44 == 0:                                           ; bunker room
    bunker_goal_check()                                   ; may not return (win)
    d0.b = $39                                            ; move.b! d0.w high byte = whatever d0 held (§h.6)
    if keytest(d0) ('.' key, raw $39):
        if $57f53 == 0: $57f53 = $ff; throw_grenade()     ; edge-triggered
    else: $57f53 = 0
joy = res_joystick()
if !(joy & $80): $57f52 = 0                               ; fire released
elif $57f44 == 0:                                         ; bunker: fire = grenade, edge-triggered
    if $57f52 == 0: $57f52 = $ff; throw_grenade()
else: (rifle; other rooms)
pl_move ($17a92): shared movement (finaljungle): y (depth) ±2 per tick (UP = +2 away from camera, max $5f;
    DOWN = −2, min 0), path width $19012 ∓1 accordingly ($32 at y=0 → 3 at y=$5f), x ±4 per tick (LEFT/RIGHT);
    x clamped to [$64−w, $be+w] (w = $19012; exits only if y >= $5a AND the room has them — never in the bunker);
    frames: standing 4, walking right 0, left 9, vertical $11; +$15 when y > $1e, +$15 again when y > $3c
    (only if frame < $26); anim byte += ±1 when moving.
```
Throwing does not change the player animation.

### b.5 `bunker_goal_check` $17be2 / `game_won` $17c0a
```
bunker_goal_check:
  if $57e6a.b != 0: return          ; Barnes alive
  if x <= $9e (signed) or x > $ae or y < $5f: return          ; door window x in [$9f,$ae], y >= $5f
game_won:                           ; also from main_loop CAPS LOCK (MEGA CHEAT)
  clear_play_and_pal()              ; $17676: clr rows 0..143 of 4 planes of $70000 and $78000
                                    ;   (d0=$59f: $5a0 longs/plane), top pal $18fc2, HUD pal $176be
  text_screen_music3(a0 = $18b5f)   ; b.14
  jmp k_game_over ($f864)           ; kernel: fade, "GAME OVER.", hiscore check/name entry, title
```
No bonus, no special "completed" state: the kernel treats a win exactly like a death (score unchanged).
Reachable positions: x ∈ {160,164,168,172} (start x $a0 ± 4k), y = $5f (clamped max).

### b.6 `obj_barnes` $182b0 (slot 4, a3 = $57e6a)
```
barnes_fire()                               ; $17f68
frame = 0; if player.x ($57e24) >= $82: frame = 1; if player.x >= $a0: frame = 2       ; signed; faces the player
```
Barnes never moves; he has no collision with the player; he is not affected by anything but grenades.

### b.7 `barnes_fire` $17f68 / `barnes_fire_spawn` $18002
```
barnes_fire:
  if $57f54 != 0: return                    ; player in hit/death animation
  if $57f5a.w >= 0 (signed): $57f5a -= 1; return
  a0 = first slot of 7,8,9 with byte0 == 0 (else return; counter stays negative -> retried every tick)
barnes_fire_spawn:
  d1 = (barnes.y - player.y) as word, lsr.w #3 (UNSIGNED shift)
  d0 = player.x - barnes.x (word), d0 upper word = 0
  if d0 >= 0:  dx = (d1.b == 0) ? 15 : ((d0 divu d1.w) & 15)          ; tst.b tests only the low byte
  else:        dx = (d1.b == 0) ? -15 : -((-d0 divu d1.w) & 15)
  bullet.e ($e.w) = dx; bullet.(x,y) = (barnes.x + $e, barnes.y); bullet.byte0 = $ff
  $57f5a = (rand() & 15) + $0a              ; next shot after 12..27 ticks (counts down through -1)
  sfx($82)
```
With Barnes at y=$69 and player y ∈ [0,$5f], d1 ∈ [1,13] so the zero/overflow branches never trigger in practice.
First shot: 22 ticks after room entry ($57f5a = $14 → ... → −1 → fire). [verified: first bullet at tick 22]

### b.8 `obj_ebullet` $17cfc (slots 7-9) + `bullet_hits_player` $17d1e
```
obj_ebullet:
  bullet_hits_player()                      ; may not return (hit)
  x += e; if x u>= $140: free
  y -= 4; if y < 0: free
bullet_hits_player (a3 = bullet):
  if $57f54: return
  hit if player.x <= b.x <= player.x+$18  and  player.y+8 <= b.y <= player.y+$1c     (signed, uses the bullet
      position BEFORE this tick's move)
  on hit: pop return (skip the move); b.byte0 = 0; goto player_hit
```

### b.9 `throw_grenade` $182de
```
a0 = first of slots 10,11,12 ($57ed6 + $12k) with byte0 == 0; none -> return
if man.grenades ($0(a5)) == 0: return
man.grenades -= 1                            ; HUD grenade bar shows $0(a5) (kernel jt13)
a0.w0 = $ff00 (active $ff, anim 0); (x,y) = (player.x + $0a, player.y + $1e)
handler = obj_grenade $1833a; gfx = $476a8; frame($10) = 0; e($e.w) = 0
sfx($0a)                                     ; synth sfx 10
```
Max 3 grenades in the air; one throw per fire press (or '.' press).

### b.10 `obj_grenade` $1833a
```
y += 4 + arc[e]          ; arc = $18400: 6,5,4,3,2,1,0,-1,-2,-3,-4,-5,-6 (words)
if y u>= $8c: free (no sound, no explosion)              ; happens if thrown from player.y >= 55 (peak = start+55)
e += 1; if e != 13: return
; landing (13th tick; y = start + 52 = player.y + $52):
d0 = $85; d1 = 0
if y >= $60 (signed) and y u< $6e and x > $9b and x <= $aa (signed) and $57e6a.b != 0:
    d1 = $0e + (rand() & 1)                ; "DIRECT HIT !" / "YOU GOT HIM!"
    d0 = $81
    $57e6a.b -= 10
    if $57e6a.b == 0:                       ; 5th hit: Barnes is gone (not drawn, handler no longer called)
        msg($10) "GET TO THE BUNKER - NOW!"; $57f55 = 0; sfx($81); $57f55 = $ff (write-only var)
        goto obj_to_explosion
gr_explode_msg: sfx(d0); if d1: msg(d1)
obj_to_explosion
```
Per-tick dy = 10,9,8,7,6,5,4,3,2,1,0,−1,−2; cumulative 10,19,27,34,40,45,49,52,54,55,55,54,52 (peak +55).
**Throw window** (derived and verified): player.y ∈ [14,27] (i.e. even y 14..26) and player.x ∈ [$92,$a0]
(reachable x 148,152,156,160). Grenade x never changes; its screen line is `$8f − y − 4`, so it rises up the
screen and drops back 3 lines at the end.

### b.11 `obj_to_explosion` $186dc / `obj_explosion` $18706 (shared with mines)
```
obj_to_explosion: frame = 0; handler = $18706; gfx = $476e0; anim = 0; x -= $0e; y += 4
obj_explosion:    frame += 1; if frame == 4: free        ; frames 0,1,2,3 drawn one tick each
```

### b.12 `player_hit` $17d68, `obj_player_dying` $17e30, `obj_player_dead_wait` $17e5e
```
player_hit:  (player accessed absolutely: $57e22 slot)
  anim($57e23) = 0; handler($57e2c) = $17e30
  f = old frame ($57e32, signed byte): new = 5; if f > 4: $0d; if f > $14: $1a; if f > $19: $22;
                                        if f > $29: $2f; if f > $2e: $37
  frame = new; e.hi ($57e30) = new + 3 (end frame); e.lo ($57e31) = 0
  $57f54 = $ff (dying); $57f5c = $64; man.wounds ($4(a5)) += 1
  msg( wounds u< 4 ? $0a "YOU'RE HIT" : $09 "KILLED IN ACTION" ); k_hud_wounds()
  morale $2e(a6) -= $800, clamp at 0 (bcc)
  sfx($57f64) ($80 normally, $81 after a mine); $57f64 = $80
obj_player_dying: e.lo = (e.lo+1)&3; if != 0 return; frame += 1; if frame == e.hi: handler = $17e5e
obj_player_dead_wait: e.lo = (e.lo+1)&7; if != 0 return
  $19012 = $32; handler = $179fa; $57f54 = 0
  if wounds u>= 4:
     if $22(a6) != 0: goto all_dead ($17f18)
     second chance: $22(a6) = 1; a5 = a6+6; $1e(a6) = a5; k_hud_wounds(); fade_out_wait();
       clear_play_and_pal(); text_screen_music3($18d2c); game_screen_init ($1771e: music 5, clear, pal $18fc2);
       bra $17068 (fj_restart: timer 2:00, hints, start room $69 — the bunker progress is lost)
  else (respawn in the same room):
     bunker room: free slots 7,8,9 only (Barnes' bullets; Barnes keeps his hit points; grenades in flight stay)
     other rooms: free slots 1..9
     player (x,y) = ($a0, 0)
```
Hit sequence length: 3 frames × 4 ticks + 8 ticks (+ the first tick) ≈ 18-20 ticks [measured 18 frames].
Section 2 has **two lives**: man 0 then man 1 (section 2 re-initialises all 5 men at its start, `$1703c`:
grenades 9, ammo $90, wounds 0 — note: contrary to the kernel notes, S2 *does* reset the men).

### b.13 End sequences (all → `k_game_over` $f864; none awards points)
| trigger | code | screen text (string) | music |
|---|---|---|---|
| Barnes dead + door reached, or CAPS LOCK with MEGA CHEAT | `game_won` $17c0a | $18b5f "YOU MADE IT! / A HUEY IS ON IT'S WAY, / TO TAKE YOU BACK TO THE FIREBASE !" | 3 |
| timer 00:00 (anywhere, also in the bunker) | `time_up` $1718a | $18bb8 "YOU DIDN'T MAKE IT! / YOUR PLATOON HAS BEEN DESTROYED, / BY A NAPALM STRIKE !" | 3 |
| morale 0 | `morale_zero` $17f04 | intended $18c14 "…WITHDRAWN FROM ACTION / PRESS FIRE", actually $18ce7 "YOUR PLATOON HAS BEEN DESTROYED! / PRESS FIRE TO CONTINUE." (a0 overwritten at $17f22) [verified] | 3 |
| man 1 killed (4 wounds) | `all_dead` $17f18 | $18ce7 (as above) | 3 |
| man 0 killed | second chance ($17e96) | $18d2c "YOU DIDN'T MAKE IT ! / ONE OF YOUR PLATOON MEMBERS / FOLLOWED YOU TO THE EDGE OF / THE JUNGLE / YOU HAVE ONE MORE CHANCE / TAKE CONTROL OF YOUR MAN / PRESS FIRE TO CONTINUE" → restart | 3, then 5 |

```
time_up:
  sfx($81); $57f64 = $80                         ; sfx_and_reset
  pal_copy_current(): copy 16 words ($5a(a6)) -> $57f70; k_set_top_pal($57f70)
  repeat:                                        ; flash to white
      changed = 0
      for each of 16 colours c at $57f70: for each nibble (R,G,B): if nibble != $f: nibble += 1; changed = 1
      k_set_top_pal($57f70); 4 x k_wait_vbl()
  until !changed                                 ; <= 16 steps (last step changes nothing) ~ 64 vbl
  fade_out_wait(); k_clear_screens(); text_screen_music3($18bb8); jmp k_game_over
morale_zero: fade_out_wait(); k_clear_screens(); a0=$18c14 (dead); a0=$18ce7; text_screen_music3; jmp k_game_over
all_dead:    fade_out_wait(); k_clear_screens(); a0=$18ce7; text_screen_music3; jmp k_game_over
```

### b.14 Screen helpers
```
text_screen_music3 ($176de, a0 = string): k_music(3)                       ; falls into text_screen
text_screen ($176ea): push a0; k_clear_screens (all of $70000-$7ffff); k_set_top_pal($18fe2); pop a0
      res_print(a0)          ; draws into both buffers ($70000 and $78000)
      k_wait_frames(d0=$31)  ; 50 vblanks
      repeat until res_joystick() & $80    ; busy poll, no vblank wait, no release wait
game_screen_init ($1771e): k_music(5); k_clear_screens; k_set_top_pal($18fc2)
fade_out_start ($1728a): pal_copy_current(); $172aa = $ff; save vector ($6c) to $172ac; ($6c) = l3hook_fade $172c2
l3hook_fade (every vblank, before the kernel level-3 handler): if $172aa == 0: restore ($6c) and chain;
      else: every nonzero nibble of the 16 colours at $57f70 −1; $172aa.w = (any changed ? $00ff : 0);
      k_set_top_pal($57f70); chain to the saved vector (push + rts)
fade_out_wait ($175e8): fade_out_start(); repeat { k_wait_vbl(); k_hud_update() } while $172aa
```
Only the 16 top (game-window) colours fade; the HUD keeps its palette. The text screens are displayed with the
normal split: lines 0..143 use the top palette ($18fe2), lines 144+ the HUD palette ($176be) — e.g. "PRESS FIRE
TO CONTINUE" of the second-chance screen (row 20) shows in HUD colours 6/7. Render verified pixel-exact.

---------------------------------------------------------------------------------------------------------------
## (c) RAM variables used by the bunker room (section-2 area; all zeroed on room entry unless noted)
| addr | size | meaning | init | written / read by |
|---|---|---|---|---|
| $57e22 +$12·k | 16×18 | object slots 0..15: +0 b active (Barnes: hit points), +1 b anim (draw: &=7), +2 w x, +4 w y (depth/height), +6 l bob-set ptr, +$a l handler, +$e w e (grenade step / bullet dx / hit end+cnt), +$10 b frame, +$11 b spare | slot init table $18df0 (slots 0-9) | everything |
| $57e24/$57e26 | w | player x / y (slot 0 +2/+4) | $a0 / 0 | player, Barnes, goal |
| $57e6a | b | slot 4 byte 0 = **Barnes' hit points** ($32, −10 per hit) and active flag | $32 | grenade, goal check |
| $57ea0.. | 3 slots | slots 7-9: Barnes' bullets | inactive | barnes_fire, obj_ebullet |
| $57ed6.. | 3 slots | slots 10-12: grenades → explosions | 0 | throw_grenade, obj_grenade |
| $57f42 | b | soldiers left (rand 0..5) — unused in the bunker | rand | room_setup |
| $57f44 | b | exit mask of the room; **0 = bunker room** | exits[type] | many |
| $57f45 | b | room type ($10) | | room_setup |
| $57f46 | l | player (x,y) saved at the start of its handler | | blocking objects |
| $57f52 | b | fire-button latch | 0 | player |
| $57f53 | b | '.'-key latch | 0 | player |
| $57f54 | b | player hit/dying flag ($ff) | 0 | player_hit, dead_wait; read by Barnes' fire, bullet hit test, spawners |
| $57f55 | b | cleared/set around the kill sfx — never read | 0 | obj_grenade |
| $57f56 | w | hint countdown (signed) | 0 → first hint at once | hint_tick |
| $57f5a | w | Barnes'/soldier fire cooldown (signed) | $14 | barnes_fire |
| $57f5c | w | idle-shot countdown (unused in bunker; set by player_hit) | $64 | |
| $57f64 | w | sfx played on the next player hit ($80; $81 after a mine) | $80 | player_hit |
| $57f70 | 16 w | palette work copy for fades / napalm flash | | fades |
| $57f90-$5808f | 256 b | depth-sort buckets ($ff = empty) | $ff | objects_update_draw |
| $57b00 | 200 l | row table y·40 (built at section start); longs below it ($57a58-$57aff) are 0 | | draw_bob |
| $58190 | ~3600 b | bob blit buffer | | draw_bob |
| $18f1c | b | current room | $69 (immediate at $18174) | room_setup |
| $18f40 | l | 4 signed room offsets [R,B,L,F] for the current heading | $010afff6 | trans_* |
| $19012 / $19014 | w | path half-width / saved copy | $32 | player |
| $189dc | 4 b | hint message numbers | from $189d8 | hint_tick, main_loop |
| $17226 | w | last seen timer value | | main_loop |
| $172aa/$172ac | w/l | fade active / saved level-3 vector | | fades |
| a6+$00.. | 5×6 | men: +0 grenades (9), +2 ammo ($90), +4 wounds | reset at S2 start | |
| $1e(a6)/$22(a6) | l/w | current man record / man index (0,1) | a6 / 0 | second chance |
| $2e(a6) | w | morale (persists from S1; −$800 per hit) | | player_hit, main_loop |
| $6c(a6)/$6a(a6)/$68(a6) | w/w/b | timer BCD mm:ss / frame sub-counter / running flag (kernel counts) | $0200/$32/$ff | main_loop |
| $26(a6) | w | compass carried (from S1) — hint 0 selection | | fj_restart |
| $2a(a6) | w | compass heading 0..3 | 0 | trans_* |
| $71(a6) | b | cheat flags low byte (bit1 MEGA CHEAT) | | main_loop |

---------------------------------------------------------------------------------------------------------------
## (d) Data formats (all extracted by `extract.py`, compared with emulator screenshots)

1. **Room pictures** `$18f9a`: 10 longs = offsets from `$19400`; picture n at `$19400 + tab[n−1]`. Decoder
   `room_load_picture $17604` → `$68000 + p·$2000`, 4 planes × `$17c0` bytes (320×152, only rows 0..143 are
   blitted). Per plane: `esc = *src++`; loop { `b = *src++`; if b == esc: `v = *src++; n = *src++` (0 → 256),
   write v n times; else write b } — writing stops *immediately* when the plane is full (a run may be cut; the
   rest of the run's count is dropped, the next plane starts after the run's 3 bytes). Bunker room = picture 10
   (`$425cd-$46e5e`) → `assets/room_barnes.png`; **pixel-exact** vs the emulator (canvas offset (17,36), 0 diff).
   All 10 in `assets/rooms/`. **Picture 5 is corrupt on the Darc image**: ADF track 127 (RAM $2d000-$2e5ff) holds
   foreign RLE data; the game shows garbage in rooms of type 3/4 (verified in the emulator, room 52). The original
   dump `re/platoon_b.adf` has the right track 127: with it picture 5 decodes exactly up to `$301a2` (start of
   picture 6). `rooms/pic05.png` = fixed, `rooms/pic05_darc_corrupt.png` = as on Darc. **Port: take track 127
   from platoon_b.adf** (or patch those $1600 bytes).
2. **Palettes**: `$18fc2` game window (all rooms), `$18fe2` text screens, `$176be` HUD (entries 8,9 animated at run
   time by the kernel message colours). 12-bit $0RGB words.
3. **Map** `$18ea4`: 12 rows × 10 bytes room types (0 = no room). `$18f2e[type]` exit mask (bit0 left, bit1
   right; 0 = bunker), `$18f1d[type]` picture. Types $10 at rooms 14, 24, 34. `assets/map.png/json`.
4. **Bob directory** `$47400` (96 entries × 8 bytes: long offset from `$47700`, word words−1, word rows−1). Bob
   data at `$47700+offset`: a long copy of the header, then 5 planar blocks of rows × words (block 0 = mask,
   blocks 1-4 = bitplanes 0-3). An object's `+6` points at a directory entry E; drawn frame = E[(anim&7)/2 +
   frame]; vertical placement uses E[0]'s rows−1 for all frames. Foxhole bobs (`assets/bobs_foxhole.png`,
   `assets/bobs/`): Barnes E=`$47628` (#69-71, 32×15, frames 0 left / 1 centre / 2 right), grenade `$476a8`
   (#85, 16×5), explosion `$476e0` (#92-95: 32×15, 32×19, 32×21, 32×21), Barnes' bullet `$476b0` (#86, 16×2),
   player bullet `$476a0` (#84). Full table `assets/bobs_all.png`. Barnes composited on picture 10 at
   (x $96, line $8f−$69−$e = 24) matches the emulator pixel-exactly.
5. **Messages** `$189e0` (17 pointers; string = col,row,text,$ff; all at row $12 = the message line under the game
   window): 9 "KILLED IN ACTION", 10 "YOU'RE HIT", 12 "JUNGLE CONFRONTATION" (unused), 13 "KILL BARNES WITH THE
   GRENADES." (unused), 14 "DIRECT HIT !", 15 "YOU GOT HIM!", 16 "GET TO THE BUNKER - NOW!"; `$18b5a` another
   unreferenced string. `assets/texts.json`.
6. **Print strings** (res_print format: `[col,row]`, 0 = new position, 1..4 = colour slot (code−1) := next&15, $ff
   end): `$18b5f` won, `$18bb8` napalm, `$18c14` withdrawn (unreachable), `$18c6d` intro, `$18ce7` destroyed,
   `$18d2c` second chance. Rendered with the kernel font `$12e54` (2 bpp glyphs, slot0=0 slot3=0 by default):
   `assets/end_*.png`, **pixel-exact** vs emulator for won/napalm/destroyed/second-chance (full 320×200 incl. the
   HUD-palette part). `assets/compare_*.png` show ours | emulator.
7. **Grenade arc** `$18400`: 13 signed words 6..−6. Barnes/hit constants: `assets/foxhole.json`.

---------------------------------------------------------------------------------------------------------------
## (e) Per-frame flow and timing
- One main-loop iteration per video frame (50 Hz) in the bunker room (189 iterations in 190 frames measured with
  `--bp 17118`). Pacing: `k_swap` requests the copper-list swap, the level-6 raster IRQ at the split line ($cc)
  latches it, and the next iteration's `k_wait_swap` spins until then — so at most one tick per frame; a tick
  that overruns a frame simply takes two.
- Within a tick: HUD update → cheat → (spawners: no-ops) → hints → wait swap → morale check → background copy →
  object handlers slot 15..0 (Barnes' bullets before Barnes, grenades before Barnes, **player last**) with depth
  insertion → draw far-to-near → swap → timer check.
- Interrupts: vblank (kernel $10eac: music tick, timer $6c countdown every 50 vblanks while $68(a6) set,
  keyboard) — during fades the section's hook `$172c2` runs first; level 6 swaps copper lists at the split.
- End screens run outside the main loop (busy waits: `k_wait_frames`, joystick poll).

## (f) Rendering (bunker room)
- Display (kernel): 4 bitplanes, 40 bytes/row, planes $2000 apart, buffers $70000/$78000 (`$62(a6)` = back
  buffer), DDFSTRT fetches 16 px early and DIWSTRT h=$81 (sections write `$3c81`), so **bitplane x 0..15 are
  hidden; visible playfield = x 16..319 × lines 0..143**; HUD from line 144 (split after line $8f) with its own
  palette and fixed bitplanes. Emulator canvas: bitplane (0,0) = PNG (17,36).
- `bg_restore $17558`: 4 blits A→D (BLTCON0 $09f0, BLTCON1 0, AMOD 0, DMOD 0, BLTSIZE $2414 = 144 rows × 20 words)
  from $68000+p·$2000 to back buffer+p·$2000 (waits for the blitter before each).
- `objects_update_draw $1773e`: for slot 15..0: if active call handler; if still active insert into bucket
  `key & $ff` (key = y, or y−$14 for slots 1-3 and 7-9; linear probe upwards to the first $ff byte, no wrap: a
  probe past $ff writes beyond the buffer and is never drawn); then draw buckets $ff..$00 (far first), clearing
  each. Draw: screen line = `$8f − y − E[0].rows−1`, anim &= 7 (stored), entry = (anim>>1) + frame.
- `draw_bob $17850` (cookie cut, no clipping): blit 1 clears the buffer $58190 (BLTCON0 $0100, D only, BLTSIZE
  $4b06 = 300 rows × 6 words); blit 2 copies the bob's 5 blocks (rows·5 × words, A→D, DMOD 2 → one extra zero
  word per row); blits 3-6 per plane: BLTCON0 = (x&15)<<12 | $0fce, BLTCON1 = (x&15)<<12, A = $58190 (mask,
  re-pointed each plane), B = buffer + (plane+1)·block (continues), C = D = rowtab[line] + back buffer +
  ((x>>3)&$fffe) (+$2000 per plane), C/D modulo = 40 − 2(words+1), BLTSIZE = rows × (words+1); minterm
  D = B | (C & ~A). FWM/LWM stay $ffff. **Negative screen lines** read the zero longs below `$57b00`, i.e. the bob
  is drawn with its top at line 0 (happens for explosions of grenades that land at y > 125, i.e. thrown from
  player.y 44..54: verified with y=52 — the explosion appears at the top of the window).

## (g) Input (bunker room)
- FIRE (joystick bit7): throw a grenade, one per press (latch `$57f52`). The rifle is not available in the bunker.
- '.' key (raw $39): also throws a grenade, one per press (latch `$57f53`) — subject to the phantom quirk (§h.6).
- Joystick UP/DOWN: depth ±2/tick, LEFT/RIGHT: x ∓4/±4 per tick (diagonals combine).
- CAPS LOCK (raw $62): instant win, only with MEGA CHEAT (`$70(a6)` bit1). [verified]
- Kernel keys (TAB pause, F10 music/fx, DEL restart) as usual.

## (h) Gameplay mechanics
1. **Barnes**: static at (x $96, y $69) with 50 hit points ($32); 5 grenade hits kill him (−10 each). He faces
   the player (3 frames). He fires aimed bullets (b.7) from slots 7-9 every 12..27 ticks while the player is not in
   the hit animation. Each bullet: x += dx, y −= 4 per tick; hits the player box (b.8).
2. **Grenades**: 9 per man, max 3 in flight, fixed 13-tick arc, land at player.y + $52; hit window y ∈ [$60,$6e),
   x ∈ ($9b,$aa] → throw from depth 14..27 and x 146..160. Misses explode with sfx $85; throws from y ≥ 55 vanish
   silently (never land). Hits: sfx $81 + "DIRECT HIT !"/"YOU GOT HIM!"; kill: "GET TO THE BUNKER - NOW!". No score.
3. **Win**: after the kill walk to the door: x 159..174 (160/164/168/172), y = $5f → "YOU MADE IT!".
4. **Damage**: each hit −$800 morale (half a heart) and +1 wound; 4 wounds = man dead → man 1 continues from the
   jungle start (new 2:00) — second death = game over. Respawn after a hit in the bunker: position ($a0,0),
   Barnes keeps his damage, his bullets are removed.
5. **Time**: the 2:00 airstrike timer keeps running in the bunker; 00:00 → napalm ending. Last minute: hint
   "NOT LONG BEFORE THE NAPALM" joins the hint pool. Room transitions do not stop the timer (bug at $181de).
6. **Phantom '.' key after Barnes' death (authentic quirk, verified)**: `obj_player` does `move.b #$39,d0` and
   calls `res_keytest`, which indexes the key matrix with the whole **d0.w** (`btst d1,(a0,d0.w)` after
   modifying only d0.b). d0.w at that moment is whatever the object loop left: normally the sort-bucket index of
   the last inserted slot (< $100 → correct test). While Barnes lives, slot 4 is always inserted just before
   slot 0 → correct. After his death, on every tick where **no slot 1..15 is inserted before the player** (no
   grenade/explosion/bullet alive), d0.w = $2414 left by `bg_restore` → index $2407 → byte `$489f` (constant
   $d3 in the resident image) bit 1 = 1 → '.' reads as pressed → a grenade is thrown (if any left); the next
   tick the grenade exists, the real key is tested (released) and the latch clears; when the explosion ends
   the phantom fires again. Result: **all remaining grenades are auto-thrown one after another, one every 17
   ticks** (13 flight + 4 explosion), sfx $0a/$85 each [verified: frames 142,159,176,193 in `work/win.txt`].
   Other d0 sources (a handler that frees its own slot leaves its own d0: grenade vanish → arc value, possibly
   $ffxx → index −$f9 → `$239f` = 0 → not pressed) do not trigger it. **Port**: keep a shadow "d0" through the
   object loop or special-case: if Barnes is dead and no object in slots 1..15 was inserted this tick, treat
   '.' as pressed.
7. **Random numbers**: hint_tick (2 per hint), room setup (1), Barnes' cooldown (1 per shot), grenade hit (1 per
   hit). Kernel RNG `$f850`.

## (i) Sound / music calls
| call site | what | when |
|---|---|---|
| $18334 | sfx $0a (synth) | grenade thrown |
| $183e8 | sfx $85 (sample, boom) | grenade lands, miss |
| $183e8 | sfx $81 (sample) | grenade hit (not lethal) |
| $183d8 | sfx $81 | Barnes killed |
| $18076 | sfx $82 (sample, shot) | Barnes fires |
| $17e2c→$180fc | sfx `$57f64` = $80 (sample) | player hit |
| $1718e | sfx $81 | timer 00:00 (napalm) |
| $176e4 | music 3 | every end/second-chance text screen |
| $17724 | music 5 | back to the jungle after the second-chance screen (and at section start) |
| kernel $f864 | fade, GAME OVER, music 1 if hiscore | after every ending |

## (j) Open questions / uncertainties
- Why tracks 127 differ between Darc and the original dump: the Darc track looks like RLE data from another
  picture (escape $c6); our fix uses platoon_b's track 127 (only proven to make picture 5 decode to the exact
  length and look right — the whole track was not byte-verified against a third source).
- Messages 12/13 and string $18c14 are dead data (probably meant for an intro to the bunker room and for the
  morale-0 ending).
- `$57f55` is written around the kill sfx but never read by section code (possibly a leftover of an sfx-priority
  scheme).
- Whether the phantom-'.' bytes (`$489f` = $d3) could differ on other releases (it lies in resident data; constant
  in all three RAM dumps and on the disk).
- Exact number of vblanks of the white napalm flash depends on the palette at time-out (≤ 16 steps × 4 vbl).
