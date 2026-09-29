# Platoon (Amiga) — KERNEL module spec

Scope: resident code `$400-$2537` (jump table, init, exception handlers + debug monitor, keyboard/level-2,
disk loader), the `$2538-$f7ff` area (only a relocator stub + the music driver/samples, which belong to the
audio module), the boot loader at `$76000` (loading-picture decoder), and the kernel `$f800-$16a6b`
(jump table, game-flow state machine, title/credits/hiscores/attract, section loader, HUD, text system,
copper/double buffering, vblank + raster interrupt, RNG, keyboard features, pause, music/fx toggles, cheats,
hiscore entry/save, kernel graphics/fonts/palettes).

Files in this directory:
- `NOTES.md` (this spec), `labels.txt` (rdis labels), `kernel.s` (annotated listing, 6.2k lines),
- `extract.py` (pulls all kernel assets from `re/platoon_darc.adf` → `assets/`; verified pixel-exact vs emulator),
- `assets/` (PNG/JSON), `work/` (scratch: scripts, screenshots, coverage, patched ADF `darc_hs.adf`).

All addresses are runtime addresses. `a6` = `$12dde` everywhere in kernel and section code; `N(a6)` notation is
used below. "HUD region" = the part of the display below the copper split; "game window" = above it.
Unless stated, every claim was verified in the emulator (screenshots/pokes/breakpoints); items marked
**(unverified)** were derived from code only.

---------------------------------------------------------------------------------------------------------
## (a) How to reach the content

| content | recipe |
|---|---|
| boot / loading picture | `./tools/amiga/emu --adf re/platoon_darc.adf --frames 60 --shot-every 25` (picture visible f25-f50) |
| title loop (logo, credits, hiscores, attract) | plain boot, no input; credits ≈f250, hiscores ≈f800, attract ≈f1100-1350, repeats (period ≈ 1000 frames) — state `re/states/kernel_title.state` (f250) |
| cheats | type at title: script `work/cheat.txt` (keys H A M B U R G E R then KP- H I L L, 10 frames apart). State `re/states/kernel_cheat_title.state` has `$70(a6)=3` |
| LOADING screen, "ENTERING THE COMBAT ZONE...." | `300 fire 1`,`305 fire 0` from boot → LOADING f310-f590, ENTERING f600-f750, play f800 |
| section select | `350 poke 12e4c N 2` (N=0,1,2) before loading finishes (see shared NOTES) |
| in-game HUD, pause, F10, DEL | `--load-state re/states/section0_play.state`; keys: `key 0x42 1/0` TAB pause, `key 0x59` F10, `key 0x46` DEL |
| game over / name entry | `re/states/kernel_nameentry.state` (made from the **patched** ADF `re/kernel/work/darc_hs.adf` = Darc + original track 77; score 00012345). Recipe: load `re/states/kernel_hs_play.state`, `5 poke 12e2c 00012345 4`, `6 poke 12e0c 0001 2` (morale→0 makes section 0 call game over) |
| hiscore table visible | boot `re/kernel/work/darc_hs.adf` (Darc image's track 77 is **blank**, see §(d).7) |

Script used for the in-game states (from the shared notes): `300 fire 1 / 305 fire 0 / 600 fire 1 / 605 fire 0 / 900 fire 1 / 905 fire 0`.

---------------------------------------------------------------------------------------------------------
## (e) Boot sequence and per-frame flow (read this first)

### Boot chain
1. Bootblock (crack) loads ADF `$70c00`, `$2c00` bytes → `$76000`, jumps `$7613a` (emu HLEs this).
2. `boot_entry $7613a`: vector `$20`:=`$76148`, SR=`$2700`, SP=`$400`, `boot_display_init $76614`
   (INTENA/DMACON off, BPLCON0 `$4200`, BPLCON1/BPL1MOD/BPL2MOD 0, DDFSTRT `$38`, DDFSTOP `$d0`, DIWSTRT `$3c81`,
   DIWSTOP `$04c1`, COP1LC `$766ae` (BPL1..4PT = `$78000,$7a000,$7c000,$7e000`, end), clear `$78000-$7ffff`,
   SPRxCTL=0, COLOR00-31=0, `boot_kbd_off` (CIA-A ICR `$7f`, CRA bit6=0, INTREQ clr, ADKCON `$7f00`/`$9100`,
   DMACON `$8380`), SR=`$2000`). Drive select dance ($7629c with `$766f2`=1 then 0).
3. Load tracks 18..20 (`d0=$12,d1=3`) to `$70000` → `boot_decode_picture $761dc` → write palette `$766d2`
   (32 words) to COLOR00-31 → picture shown.
4. Load tracks 1..17 (`d0=1,d1=$11`) to `$400`; `jmp $400`. (On load error the code would `jmp $f80000`;
   the loader never fails.)
5. `$400` initially = `bra $253c` (**reloc_stub**): INTENA=`$7fff`; copy `$84d` longs from `$404` to `$400`
   (resident moves down 4 bytes: `$404-$2537` → `$400-$2533`); `jmp $400` → now `bra $566`.
6. `res_init $566` (resident): INTENA off, vector `$20`=`$582`, SR `$2700`, SP `$400`, build row table `$2434`
   (25 longs `n*$140`), install exception vectors (see §resident), drive select, clear `$10a4`, `a6=($24fc)`,
   `kbd_init $13b0` (L2 vector `$68`=`$169c`, CIA-A ICR `$7f` then `$88` (SP enable), CRA bit6=0, INTREQ `$7fff`,
   INTENA `$c008`, ADKCON `$7f00`,`$9100`, DMACON `$8380`), then `mon_jump_goaddr $10b8`: `jmp ($10d6)` = **`$f800`**.
7. Kernel `jt00 k_init $f890` (below). The kernel never returns to the resident.

### Interrupts in use (INTENA = `$c008 | $a020` → INTEN, PORTS(L2), VERTB(L3), EXTER(L6))
- **Level 2** `$169c` keyboard (resident). **Level 3** `$10eac` vblank (kernel). **Level 6** `$10faa` CIA-B TOD alarm
  = raster interrupt at the split line (kernel). Nothing else (no audio/blitter/copper interrupts; the level-4/5
  vectors point at the monitor's "Uninitialised interrupt").

### Vblank handler `level3_vblank $10eac` (every frame, line 0) — complete
```
save d0-d7/a0-a6; a6 = $12dde
CIA-B CRB bit7 := 0 (TOD write mode); TODHI := 0; TODMID := 0; TODLO := 0   ; restart CIA-B TOD (counts HSYNCs) at 0
CIA-B CRB bit7 := 1                                                          ; later TOD writes set the ALARM
clr.w $000074        ; (absolute; high word of level-5 vector, already 0 -> no effect; keep as no-op)
rng($12d70) += d1_of_interrupted_code ; rng += 1                             ; 32-bit adds, see RNG
if word pause($10eaa) != 0 -> pause_sm (below) and skip timer
else if key $42 (TAB) held: pause := $0001 -> pause_sm (skip timer)
else timer:
    if $6a(a6) >= 0 { $6a -= 1; if $6a >= 0 goto common }     ; X flag = borrow when it went 0 -> -1
    if $68(a6) == 0 goto common                               ; timer disabled
    $6a := $31                                                ; 50 vblanks per tick
    sbcd: $6d(a6) (seconds BCD) -= 0 + X                      ; X = 1 on the normal path; on the path where $6a
                                                              ;   was already negative X is whatever the last
                                                              ;   op left (normally 0 -> first tick subtracts 0)
    if no borrow goto common
    $6d := $59; sbcd: $6c(a6) (minutes BCD) -= 0 + X(=1)
    if no borrow goto common
    $6c := $59                                                ; 00:00 - 1s wraps to 59:59 (sections test 00:00 themselves)
common:
    st.b $56(a6)                  ; frame flag for jt18
    jsr $280e (music tick, a6 saved)
    logo_colour_cycle $10cfe      ; always runs (only visible when top palette ptr $5a == $1137e)
    if key $59 (F10) held:
        if $12ccc == 0: $12ccc := $ff; $66(a6) := ($66+1) & 3; jt26($12cce) (restart/stop current tune); jt27(0)
    else $12ccc := 0
INTREQ := $0020; restore; rte
```
pause_sm (`$10dc2`, word `$10eaa`, entered with flags of that word):
```
$0001 (TAB still held from the press that paused): when TAB released -> $ffff
$ffff (paused, waiting):  when TAB pressed -> $ff00
$ff00 (unpausing):        when TAB released -> $0000 (running)
```
While paused: timer frozen; music keeps playing; `jt13` busy-loops (see HUD) so sections freeze; the level-6
handler writes `$10ea8` (incrementing each frame) into COLOR00 → HUD background colour cycles (verified).

### Raster/level-6 handler `level6_raster $10faa` (fires at the split line, e.g. line `$cc` in game)
```
save d0/a0/a1/a6; a6=$12dde; read CIA-B ICR (ack; source not checked)
if swap_pending($12d74): COP1LC := next_cop($12d76); swap_pending := 0      ; takes effect at next vblank
if pause($10eaa): COLOR00 := $10ea8; $10ea8 += 1
$115f2 (copper value of game-window BPLCON1) := $72(a6)                      ; scroll for NEXT frame
INTREQ := $2000; restore; rte
```
The alarm is programmed by `jt32` to `split+$3c+1` (= same line as the copper WAIT). Measured: level 6 entered
at vpos 204 (`$cc`) in game, level 3 at vpos 0.

### Game logic frame rate
There is no kernel main loop during play: section code runs its own loop and calls `jt18` (wait next vblank),
`jt19` (swap), `jt23` (wait swap latched), `jt13` (HUD). `jt18` waits for the *next* vblank (clears `$56`, spins
until the vblank handler sets it). Title-screen loops: credits/hiscore scrolling 1 step per vblank; text fades
tick every 2 vblanks (`$fb72`, `$fcfc`, `$1026e`); game-over fade 1 step per vblank.

### Game flow state machine (kernel side)
```
k_init($f890) ─► title loop forever: credits($f96c) → hiscores($f9b0) → attract($f9fc) → ...
   │                every title frame calls k_title_poll($fc9a):
   │                   fire pressed → wait release; $2e(a6):=$9000 (morale 144.0); $4e(a6):=0 (score);
   │                                  $6e(a6):=0 (section) → jt29
   │                   else → cheat key check
   ▼
jt29 k_next_section($11076): "LOADING..." + section name + logo, load section $6e to $17000,
   │                         $6e += 1, → k_section_start
   ▼
k_section_start($fcc8): "ENTERING THE COMBAT ZONE...." (fire skips), game display (split $8f),
   │                    $1e(a6):=a6 (man 0), $22(a6):=0, jmp $17000 (section code, never returns)
   ▼
section code: gameplay; sub-section changes are internal to the section (e.g. Jungle→Village);
   │   death / "KILLED IN ACTION" / "CHOOSE YOUR MAN" / "YOUR PLATOON HAS BEEN WIPED OUT" are SECTION code
   │   (strings: S0 $1a8b4.., S1 $19712.., S2 $18ab0..) using kernel texts/HUD calls;
   ├─ section completed:  jmp jt29 ($f874)  (S0 at $17e4c, S1 at $18e84) → next load section
   └─ platoon dead / morale 0 / final victory (S2): jmp jt25 ($f864)
jt25 k_game_over($fee8): "GAME OVER." → if score qualifies: hiscore name entry → "SAVING HISCORES." (stub)
   └─ jmp k_init ($f890) (warm: hiscores not reloaded, music/fx flags and cheats kept)
DEL key anywhere (level-2) → jmp $f800 (warm restart → title).  Disk load failure → st.b $6e(a6); jmp $f800.
```
Section index `$6e(a6)` (word `$12e4c`): 0 = tracks `$15`+`$38` "THE JUNGLE & VILLAGE SECTIONS.",
1 = `$54`+`$1b` "THE TUNNEL & FLARE SECTIONS.", 2 = `$6f`+`$30` "THE JUNGLE & FOXHOLE SECTIONS."; all to `$17000`.
Only indices 0..2 exist (S2 never calls jt29; index 3 would read garbage from `$11172`).

**State persisting across load sections** (a6 block is never cleared by the kernel except as listed):
score `$4e`, morale `$2e`, the 5 man records `$00-$1d` (grenades/ammo/wounds), music/fx flags `$66`, cheat flags
`$70`, section index `$6e`. Reset by kernel at section start: `$1e` (current man → man 0), `$22` (man index 0),
`$68` (timer off), text queue. Reset only at new game: `$2e`, `$4e`, `$6e`. Section 0 re-initialises the man
records at its start (`$170a8`: each man grenades 9, ammo `$90`, wounds 0); S1/S2 do not (men persist).
S2 sets the timer (`$6c:=$0200` (2:00), `$6a:=$32`, `st $68`). HUD icon vars `$24,$26,$28,$2c,$54` are set by the
sections themselves at start.

---------------------------------------------------------------------------------------------------------
## (b) Code map — kernel `$f800-$11165`

### Jump table `$f800` (33 × `bra.w`) + exported pointers — THE SECTION API
All entries assume `a6 = $12dde`. "clob" = registers changed (besides CCR).

| # | addr | target | name | in | out / effect | clob |
|---|---|---|---|---|---|---|
| 0 | f800 | f890 | init | – | cold/warm restart (never returns) | all |
| 1 | f804 | 104c6 | hud_compass | `$26`,`$2a` | draws compass icon at `$797d0` if `$26`≠0 (frame `$2a&3`), blank when `$26` becomes 0; only on change | d0 a0 a1 |
| 2 | f808 | 1058a | hud_icons | `$2c`,`$24`,`$28` | jt01 + icons `$2c`→`$797d4` (gun `$13ad4`), `$24`→`$797d8` (map `$13774`), `$28`→`$797dc` (TNT `$13894`); nonzero=draw, 0=blank; only on change | d0 a0 a1 |
| 3 | f80c | 10638 | add_score | a0 = address *after* a 4-byte BCD value | `$4e..$51` += value (4× `abcd -(a0),-(a1)`, X cleared first, wraps at 99999999); clears `$52` → score reprinted by next jt05 | – (a0/a1 kept) |
| 4 | f810 | 106a0 | print_hiscore1 | – | prints `$11808` (best score) as 8 hex digits at col 16 row 22 | d0 a0 |
| 5 | f814 | 106b8 | print_score | – | `tas $52`; if it was clear print score `$4e` at col 16 row 24 (colour slot1=5) | d0 a0 |
| 6 | f818 | 10656 | hud_wounds | `$1e(a6)`→man+4 | draws wound icon (`$139b4`) in slots `$797c0+4k` for k<man+4 (max 4), blanks the rest | d0 d1 a0 a1 a2 |
| 7 | f81c | 106d0 | hex32 | d0.l | prints 8 hex digits at text cursor (BCD shows as decimal) | – |
| 8 | f820 | 106da | hex16 | d0.w | 4 digits | – |
| 9 | f824 | 106e4 | hex8 | d0.b | 2 digits | – |
| 10 | f828 | 106ee | hex4 | d0 low nibble | 1 digit (`$111f7` "0123456789ABCDEF") via `$404` | – |
| 11 | f82c | 1070c | queue_text | d0 = index into text table `($4a)` | queued message (max 4 pending, else ignored); starts at once if queue was empty | d0 d1 a0 a1 |
| 12 | f830 | 1084a | hud_init | – | invalidate HUD caches (`$1357`), print labels, score, hiscore, wounds, jt13, jt02 | d0-d4 a0-a2 a5 |
| 13 | f834 | 108a0 | hud_update | – | once per game frame: score, text tick, sound icons, compass, 3 bars, TIME; **loops while paused** | d0 d1 d2 d4 a0 a1 a2 a5 |
| 14 | f838 | 10968 | draw_bar | d0 = value (clamped to `$48`=72), a0 = 8×8 cell gfx, a1 = dest byte | 9 cells: value>>3 full, 1 partial (mask `$1131e[value&7]`), rest blank | d0 d1 d2 d4 a1 a2 |
| 15 | f83c | 109be | draw_cell | a0 cell (32 bytes), a1 dest, d2 = AND mask byte | one 8×8 4-plane cell (dest stride 40, planes `$2000`) | – |
| 16 | f840 | 104aa | clear_screens | – | clears `$70000-$7ffff` (both buffers) | d0 a0 a1 |
| 17 | f844 | 10acc | wait_frames | d0 | waits d0+1 vblanks | d0=-1 |
| 18 | f848 | 10ad6 | wait_vbl | – | waits for the next vblank | – |
| 19 | f84c | 10ae2 | swap | – | `$62 ^= $8000`; schedule the other copper list (`$115d0`↔`$116a8`) | – |
| 20 | f850 | 10bcc | random | – | d0.l = 0..255 | d0 |
| 21 | f854 | 11062 | fill_longs | a0 dest, d0 start, d1 count-1, d2 step | `(a0)+ = d0; d0 += d2` d1+1 times | a0 d0 d1 |
| 22 | f858 | 1106c | fill_words | same, word size | (unused) | a0 d0 d1 |
| 23 | f85c | 10b14 | wait_swap | – | spins until the level-6 handler latched the swap | – |
| 24 | f860 | 10b1e | display_init | – | full display/copper init (below) | d0 a0 |
| 25 | f864 | fee8 | game_over | – | never returns | all |
| 26 | f868 | 10c00 | music | d0 = tune | `$12cce`:=d0; if `$66`bit0: `jsr $2800` else `jsr $281c`; volume `$2d98`:=`$40` | – |
| 27 | f86c | 10c50 | fx | d0 = effect | if `$66`bit1: channel mapping (below) then `jsr $2838` | d0 |
| 28 | f870 | fade | fade_in | a0 target pal, a3 = &palette-ptr var (`$5a(a6)` or `$5e(a6)`), a4 = setter (jt30/jt31 or `$f878`/`$f87c`) | 16 steps × 2 vblanks from black up to target | d0-d6 a0 a1 |
| 29 | f874 | 11076 | next_section | `$6e` | load & start section `$6e` (never returns) | all |
| 30 | f878 | 11010 | set_top_pal | a0 = 16 words | `$5a`:=a0; copy into copper top palette | – |
| 31 | f87c | 11000 | set_hud_pal | a0 = 16 words | `$5e`:=a0; copy into copper HUD palette | – |
| 32 | f880 | fd4e | set_split | d0.b = last game-window line (`$8f` in game, `$2f` title) | HUD pointers, copper WAIT, TOD alarm | d0 |
| – | f884 | dc.l `$13254` | HUD cell graphics base (sections use +`$20` bullet, +`$40` grenade, +`$60` wound mark) |
| – | f888 | dc.l `$115f6` | address of the game-window DIWSTRT value in the copper list (sections write `$3c81`) |
| – | f88c | dc.l `$1165e` | address of the HUD BPLCON1 value (sections write `$0088`) |

Resident API also used by sections: `$404` putchar, `$408` print string, `$40c` key test, `$410` joystick
(see §resident). Call-site counts (absolute jsr/jmp in the S0/S1/S2 dumps): jt11 46, jt18 31, jt20 34, jt03 15, jt19 13, jt13 11, jt30 21, jt26 7, jt25 7 (jmp), jt29 2 (jmp), jt17 2; jt22 is never called. Use `re/kernel/work/callsites.py HEXADDR` to list them with context.

### Routine details (pseudocode faithful to the asm)

**k_init `$f890` (jt00)**
```
sr |= $700; a6 = $12dde; sp = $400
k_display_reset($10454)
($78) = $10faa; ($6c) = $10eac; CIA-B ICR = $84 (enable ALRM); INTENA = $a020; INTREQ = $2020; sr = $2000
($418) = $12e54                       ; font for $404
k_music_stop($10c3a)                  ; jsr $281c; $2d98 = 0
jt21(a0=$12d7a, d0=0, d1=$18, d2=$140) ; row table: 25 longs n*320
jt31($113be black); k_clear_both_lower($fbb2); k_show_logo($10416)
jt26(0)                               ; title tune (only if music on)
if $12e52 == 0:                       ; first boot only
    $12e52 = $ff; $66(a6) = 3 (music+fx on); $12d6f = $ff; st.b $6e(a6)
    jt31($113de); jt26(0)
    k_load_retry(d0=$4d track 77, d1=1, a0=$116cc, a1=$112da)   ; hiscore track -> $116cc..$12ccb
k_logo_cycle_reset($10484)
forever { k_credits; k_hiscores; k_attract }
```
**k_display_reset `$10454`**: `jt32($2f)`; `$1165e`:=0; `jt24`; `jt30($113be)`; `jt31($113be)`; `$4a`:=`$1141e`;
`$48`:=0; `k_cheat_reset`; falls into **k_logo_cycle_reset `$10484`**: `$10dbe`:=`$384` (900), `$10dc0`:=2,
`$1137e`:=0 (logo colour0), `$11380`:=0 (colour1), `$1138a`:=`$fff` (colour6).

**k_credits `$f96c`**: `jt31(black)`; `k_clear_both_lower`; `k_onoff_text`; `$408($114a1)` (credits page, both
buffers); then **k_title_show `$f98a`** (shared with hiscores): `k_clear_disp_lower($fb8a)` (clears lines
48..199 of the *displayed* buffer `$62^$8000`, `$5f0`+1 longs/plane); `jt31($113de)`; `k_scroll_in($fbec)`;
100 × {`k_title_poll`; `jt18`}; `k_scroll_out($fc3c)`; rts.

**k_scroll_in `$fbec`**: src `a0 = $62+$8c0` (line 56 of draw buffer), dst `a1 = ($62^$8000)+$1f18` (line 199 of
displayed), `d0 = 1`; 144×: {poll; vbl; `k_blit_copy4(a0,a1,DMOD=0,BLTSIZE=(d0<<6)|$14)`; d0++; a1 -= 40}.
Effect: the page rises from the bottom, 1 line per frame.
**k_scroll_out `$fc3c`**: displayed buffer, `a0 = +$8e8` (line 57), `a1 = +$8c0` (line 56); for d0 = `$8f`..0:
{poll; vbl; copy (d0+1) lines from line 57 to line 56}. Page scrolls up 1 line/frame and vanishes under line 56.

**k_hiscores `$f9b0`**: `jt31(black)`; clear both lower; `$408($116cc)` ("TEN BEST SCORES:" string); for k=0..9:
`$408($116e5 + ($117e0)[k])` then `jt07(($11808)[k])` (score after the name, at the cursor); `bra k_title_show`.

**k_attract `$f9fc`**: `$34`:=`$1133e` (cyan ramp); `jt31($1139e)` (HUD palette); `jt11(0)` "THE FIRST CASUALTY OF WAR ...";
`k_wait_text_title($fb72)`: repeat {poll; vbl; vbl; text_tick} until `$48`=0; `jt31(black)`; clear both lower;
`k_rle_decode(a1=$14ec4, a2=$68000)`; `k_blit_copy4(a0=$68000, a1=$7878a, DMOD=$14, BLTSIZE=$25ca)` (160×151 at
x=80, line 48 of `$78000`); `jt27($80)`; `jt28(a0=$113fe, a3=&$5e, a4=jt31)`; 201 × {vbl; poll}; `k_fade_out_hud`.

**k_title_poll `$fc9a`** (called once per frame by every title loop):
```
d0 = $410(); if !(d0 & $80) -> k_cheat_check (rts to caller)
repeat until !( $410() & $80 )        ; busy-wait release (no vblank)
$2e(a6).w = $9000; $4e(a6).l = 0; $6e(a6).w = 0; bra jt29       ; stack not unwound (section start resets sp)
```
**k_cheat_check `$10e14`** / **k_cheat_reset `$10e7c`** — see §(g) cheats.

**k_blit_copy4 `$fa82`** / `$faa6`: for 4 planes (a0,a1 advanced by `$2000` each): BLTAPT=a0, BLTDPT=a1, BLTAMOD=0,
BLTDMOD=d0, BLTCON0=`$09f0` (A→D copy), BLTCON1=0, BLTSIZE=d1, then wait `DMACONR` BBUSY (`btst #6,$dff002`).
(FWM/LWM left at `$ffff` from jt24.)

**k_fade_in `$fade` (jt28)** (a0 target, a3 palette var, a4 setter):
```
copy black ($113be) -> $12cf0 (16 words); a1 = target; (a3) = $12cf0
16 times: vbl; vbl; for each of 16 colours: each nibble of $12cf0[i] += 1 if != target nibble ; a0=$12cf0; jsr (a4)
(a3) = target; a0 = target; jmp (a4)
```
(increments only → assumes start from black; always uses buffer `$12cf0`.)
**k_fade_out_both `$fe38`**: copy `($5a)`→`$12cd0`, `($5e)`→`$12cf0`, point `$5a/$5e` at them; 16 × {vbl; vbl;
`k_pal_dec_step($12cd0, 32 colours)`; jt30(`$12cd0`); jt31(`$12cf0`)}. **k_fade_out_hud `$fdee`**: same for
`$5e` only (16 colours). `k_pal_dec_step $fea8`: each nonzero nibble −1.

**k_show_logo `$10416`**: `k_rle_decode(a1=$14074, a2=$70000)` (320×48); `k_blit_copy4($70000→$78000, DMOD 0,
BLTSIZE $0c14)`; `k_logo_cycle_reset`; `jt28(a0=$1137e, a3=&$5a, a4=jt30)`.

**k_rle_decode `$102d2`** (a1 = src, a2 = dest plane 0): `N = (a1).w` (self-modifying: patches the operand of
the `move.w $xxxx,d3` at `$102e2`); src += 2; for 4 planes: `esc = *src++`; `cnt = N`; repeat
{ b = *src++; if b != esc { *dst++ = b; cnt-- } else { v = *src++; n = *src++ (0 means 256); n × {*dst++ = v; cnt--} } }
until cnt == 0 (tested after each literal/run; runs never overshoot in the data); plane dest += `$2000`.

**k_logo_colour_cycle `$10cfe`** (every vblank; state `$10dc0` (bit0 = hold, bit1 = direction), counter `$10dbe`):
```
if state&1:  if --cnt: return; cnt = 2; state = (state+1)&3; goto apply
if --cnt: return
cnt = 4
if state&2: c0 += $111; c1 += $111; c6 -= $111; if c6 == 0 { cnt = 200; state = (state+1)&3 }
else:       c0 -= $111; c1 -= $111; c6 += $111; if c6 == $fff { cnt = 200; state = (state+1)&3 }
apply: if $5a(a6) == $1137e: jt30($1137e)
```
(c0=`$1137e`, c1=`$11380`, c6=`$1138a`.) After reset (cnt 900, state 2): 900 frames still, then 15 steps × 4
frames to white background (letters colour 1 vanish, soldiers' silhouettes appear black), hold 200 (+2), fade back,
hold 200… See `assets/logo_cycle.png`.

**k_section_start `$fcc8`**:
```
sp = $400; k_fade_out_both; $4a = $1141e; jt16; jt30($1139e); jt31($1139e); $34 = $1135e (red ramp)
jt11(2)  "ENTERING THE COMBAT ZONE...."
repeat { vbl; vbl; text_tick; if ($410() & $80) break } while $48 != 0
jt32($8f); $68 = 0; jt30(black); jt31(black); jt16; jt24
$1e(a6).l = a6; $22(a6).w = 0; jmp $17000
```
**k_next_section `$11076` (jt29)**:
```
jt26(3) (loading tune); $4a = $1141e; $48 = 0; k_fade_out_both; jt32($2f); $1165e = 0
jt30(black); jt31(black); jt16
$408($11172) "LOADING..." (col 15,row 10); $408(($1118a)[$6e]) section name (row 13)
k_show_logo; jt28(a0=$1139e, a3=&$5e, a4=jt31)
jsr ($11166)[$6e]:      ; $11102/$1112a/$11148
    k_load_retry(d0=track, d1=count, a0=$17000, a1=name string)
    ok -> rts ; fail -> st.b $6e(a6); jmp $f800
$6e += 1; bra k_section_start
```
**k_load_retry `$101d0`**: `$12d1e`=5; save d0/d1/a0/a1 at `$12d20`; loop {reload args; `jsr $420`; if d0==0 rts;
print `$112f1` (blank row 22) and `$11272` ("DISK ERROR #00, PRESS FIRE", cursor ends at col 19 row 22),
`jt09(-d0)`, `k_wait_fire_click`, blank row 22; if --`$12d1e`==0 break}; st.b `$6e(a6)`; print `$1129a`
"THERE HAS BEEN A FATAL DISK ERROR!"; wait fire click; return d0=`$fffa`. (Never triggers: crack loader returns 0.)
**k_save_hiscores `$1013c`**: same with `jsr $424` (stub, returns 0 immediately) and reprinting `a1` after errors.

**k_game_over `$fee8` (jt25)**:
```
k_fade_out_both; jt16; k_display_reset; k_show_logo... (order: $fe38, jt16, $10454, $10416)
jt11(4) "GAME OVER."
repeat { music_fade_step; vbl; music_fade_step; vbl; text_tick } while $48    ; $2d98 volume -1 per frame
k_music_stop; k_clear_both_lower
d6 = score; a1 = $11808; d1 = 9
loop: if d6 >= (a1)+ (unsigned) exit; dbra d1        ; ties rank ABOVE the existing score
if never: jmp k_init                                 ; no entry
jt26(1) (hiscore tune); k = 9 - d1
if k != 9: shift entries 8..k down by one (scores long, names 16 bytes; the loop does one extra harmless
           iteration that is overwritten)
scores[k] = d6; copy 16-byte name buffer $11836 -> name of entry k ($116eb + offs[k])
jt31($1139e); $34 = $1135e; name entry (below); then:
$408($11830); k_fade_out_hud; jt31(black); clear both lower; print table + 10 scores (as k_hiscores)
$408($112c3) "SAVING HISCORES."; jt28(a0=$113de, a3=&$5e, a4=jt31)
k_save_hiscores(d0=$4d, d1=1, a0=$116cc, a1=$112c3)   ; crack: no write
k_fade_out_both; jmp k_init
```
**Name entry (`$fffc` loop)**: a1 = entry name, a2 = `$11836`, d1 = 15.
```
loop: col = 22 - d1; $1184f = col; $408($11830); $1184b = col; jt07(score)
      d0 = k_wait_joy_input($1025a)     ; waits all-released then any input; each poll = vbl,vbl,text_tick,
                                        ; and re-queues text 3 "ENTER YOUR NAME:" whenever the queue is empty
      if d0 & $80 (fire):
          c = (a1)
          if c == $5d ('←' DEL): if d1 != 15 { (a1) = (a2) = '_'; a1--; a2--; d1++ }; goto loop
          if c == $5e ('↲' END): d1+1 times { (a1)+ = (a2)+ = ' ' }; done
          a1++; a2++; if --d1 >= 0 goto loop; done
      d0 &= $0a; if d0 == 0 or d0 == $0a goto loop     ; only RIGHT (bit1) / LEFT (bit3)
      (a1) += (RIGHT ? +1 : -1); (a1) = ((a1) & $1f) | $40; (a2) = (a1); goto loop
```
Character set cycles `$40..$5f`: `@`(blank glyph) A..Z `[`(&) `\`(heart) `]`(←) `^`(↲) `_`. Initial chars come
from `$11836` which is *not* reset → the next name entry starts pre-filled with the previous name (quirk).
Name line `$11830`: `[7,13] slot1=2 slot2=$a` 16 chars, `0 [col_erase,14] ' '`, `0 [col_cursor,14] '%'`
(up-arrow glyph), `0 [25,13] slot1=2 slot2=$a` → score printed at col 25 row 13. Verified (`work/ne_pair.png`).

**Text system** (`$4a(a6)` = table of string pointers; kernel table `$1141e`, sections install their own):
- `jt11 k_queue_text $1070c`: `n=$48; if n==4 return; $3c[n] = d0&$ff; $48++; if n==0 k_text_start(d0)`.
- `k_text_start $10732`: `a0 = ($4a)[d0]`; `$38`=0 (step), `$32`=2 (period), `$3a`=+1 (dir), `$30`=1 (countdown);
  `k_text_colour`; row = byte 1 of string; clear 8 lines × 40 bytes × 4 planes at `$70000+$12d7a[row]` and
  `$78000+…`; `$408($11229)` (slot0=0, slot1=8, slot2=9); `$408(a0)`.
- `k_text_tick $107b4` (per game frame via jt13, or every 2 vblanks in kernel loops):
```
if $48 == 0 return; if --$30 != 0 return; $30 = $32; $38 += $3a
if $38 == 7: $30 = ($48 == 1) ? 25 : 1; $32 = 1; $3a = -1; k_text_colour; return
if $38 == 0: shift queue $3c..$46 up one word; d0 = $3c; if --$48 != 0 k_text_start(d0); return
k_text_colour
```
  So: fade in 7 steps × 2 ticks, hold 25 ticks (only the last queued message; otherwise 1), fade out 7 × 1 tick.
- `k_text_colour $10824`: `c = ($34)[$38]` (long = colour8:colour9); `($5e)+$10 := c` (writes into the current
  HUD palette *data*); copper COLOR08 value `$11686 := c.hi`, COLOR09 `$1168a := c.lo`. Only HUD-region colours
  fade, so queued texts must be on rows in the HUD region. Ramps: `$1133e` cyan (0,`022/002`…`0ff/00f`),
  `$1135e` red (`000/000`,`200/002`,`400/202`,`600/204`,`800/404`,`a00/406`,`c00/606`,`f00/608`).
- Kernel texts `$1141e`: 0 `[5,14]` " THE FIRST CASUALTY OF WAR ...", 1 `[14,24]` "IS INNOCENCE" (unused; baked
  into the attract picture), 2 `[6,10]` "ENTERING THE COMBAT ZONE....", 3 `[12,9]` "ENTER YOUR NAME:",
  4 `[15,9]` "GAME OVER.".
- Quirk: while paused `jt13` spins calling text_tick without vblank waits → a showing message finishes instantly.

**HUD** (`$78000` buffer only, HUD line 0 = buffer line 144 = `$79680`; x in pixels of the 320-px buffer; the
HUD is displayed shifted right 8 px because sections set HUD BPLCON1 = `$88`):

| element | routine | dest | contents |
|---|---|---|---|
| message line | jt11 | row 18 (HUD lines 0-7) | section messages ("YOU'RE HIT", …) |
| wound icons ×4 (the red "hit star") | jt06 | `$797c0+4k`, HUD lines 8-31, x=0,32,64,96 | `$139b4` red splat, count = man+4 (4 = dead) |
| compass | jt01 | `$797d0` x=128 | `$132f4+$120*($2a&3)` when `$26`≠0 |
| gun icon | jt02 | `$797d4` x=160 | `$13ad4` when `$2c`≠0 (flares count, S1) |
| map icon | jt02 | `$797d8` x=192 | `$13774` when `$24`≠0 |
| TNT icon | jt02 | `$797dc` x=224 | `$13894` when `$28`≠0 |
| music icon | `$1052c` | `$797e0` x=256 | `$13bf4` on / `$13e34` off (`$66` bit0) |
| fx icon | `$1052c` | `$797e4` x=288 | `$13d14` on / `$13f54` off (`$66` bit1) |
| "TIME mm:ss" | jt12/jt13 | row 22 col 4 / digits col 9 | `$6c:$6d` BCD, only when `$68`≠0 and changed |
| best score | jt04 | row 22 col 16 | `$11808` |
| "AMMO:" | jt12 | row 22 col 28 | |
| "MORALE:    SCORE:" | jt12 | row 23 col 6 | |
| top bar (grenades / flares) | `$10906` | `$79cda` (line 184, x=208) | `$54`=0: `$13294`, value man+0 ×8 (9 grenades max); `$54`≠0: `$132d4`, value `$2c`×8 |
| ammo bar | `$1093c` | `$79e1a` (line 192, x=208) | `$13274`, value man+2 >>1 (`$90` = 144 rounds = 9 full cells; 1 px = 2 rounds) |
| morale hearts | `$10956` | `$79e05` (line 192, x=40) | `$13254`, value = byte `$2e` >>1 (`$90`=9 hearts) |
| score | jt05 | row 24 col 16 | `$4e` 8 BCD digits |

Bars are redrawn every jt13 call (no cache). Icon routines draw 3×3 cells (`k_draw_icon $105f8`: cells row-major,
32 bytes each; dest +1 byte per column, +`$13e` per row; Z flag at entry = blank (mask 0) else mask `$ff`).
HUD caches (`$12d62..$12d6f`) hold last drawn values; jt12 sets them to `$1357`/`$ff` to force redraw.
**jt13 `$108a0`**: `do { jt05; text_tick; $1052c; jt01; topbar; ammobar; moralebar } while pause($10eaa)`; then
if `$68`≠0 and `$6c`≠cache: print `$11267` (col 9 row 22, slot1=6), `jt09($6c)`, `$404(':')`, `jt09($6d)`.

**Display/copper — jt24 `k_display_init $10b1e`**:
```
$62 = $70000 (draw buffer); $12d76 = $78000 (sentinel != $115d0); $12d74 = 0
SPR0..7CTL = 0; BPLCON0 = $4200 (4 planes); BPLCON1 = 0; $115f6 = $3c71 (window DIWSTRT value)
$1165e = 0 (HUD BPLCON1); $115f2 = 0 (window BPLCON1); $72(a6) = 0; BPLCON2 = 0; BPL1MOD = BPL2MOD = 0
DDFSTRT = $30; DDFSTOP = $c8; DIWSTOP = $04b1; COPCON = 0
COP1LC = $116a8 (list B); COP2LC = $115f0; strobe COPJMP1; DMACON = $83c0 (DMAEN|BPLEN|COPEN|BLTEN; no sprites)
wait blitter; BLTAFWM = BLTALWM = $ffff
```
Copper lists (`assets/copper.json`):
```
A $115d0: BPL1PT..BPL4PT = $70000,$72000,$74000,$76000   (falls through into common)
B $116a8: BPL1PT..BPL4PT = $78000,$7a000,$7c000,$7e000 ; COPJMP2 (-> $115f0)
common $115f0: BPLCON1=[$115f2] ; DIWSTRT=[$115f6] ; COLOR00..15=[$115fa+4i] (top palette, jt30)
               WAIT ([$11638],$01)                        ; split line = d0+$3d
               BPL1PT..BPL4PT = $78000+(d0+1)*40 (+$2000 each)  ; HUD always from buffer $78000
               BPLCON1=[$1165e] ; DIWSTRT=$3c71 ; COLOR00..15=[$11666+4i] (HUD palette, jt31) ; END
```
Display: 4 planes, 40 bytes/line, planes `$2000` apart, 200 lines (`$3c..$103`), DIW h `$71..$1b0` with
DDFSTRT `$30` (fetch 16 px earlier than standard) → 320 px from h=`$71`; sections set window DIWSTRT `$3c81`
(left 16 px hidden for fine scroll via BPLCON1 = `$72(a6)`). Emulator canvas: title picture at canvas (17,36).
**jt32 `k_set_split $fd4e`** (d0.b = split): `a0=$1163e`; `p = $78000 + ((d0+1)&$ff)*40`; write p, p+$2000,
p+$4000, p+$6000 into the 4 HUD BPLxPT move pairs (hi/lo words); `$58(a6).b = d0+$3c`; `$11638.b = d0+$3d`;
CIA-B: CRB bit7=1, TODHI=0, TODMID=0, TODLO=`$58`+1 (ALARM), CRB bit7=0, TOD=0.
**Double buffering**: section draws into `$62`; `jt19` toggles `$62` and sets `$12d76` = list for the buffer just
drawn (`$115d0` ↔ `$116a8`), flag `$12d74`; level-6 (at the split line) loads COP1LC; new buffer visible from
the next vblank. `jt23` waits for that latch — after it, the new draw buffer is the one still being displayed,
but only below the split (HUD region, which always comes from `$78000`), so drawing the game window is tear-free.

**Palettes / fades**: `$5a(a6)` = current top palette pointer, `$5e(a6)` = current HUD palette pointer (the
text fade writes into `($5e)+$10`). Title uses split `$2f`: lines 0-47 (logo) = top palette `$1137e`,
lines 48-199 = "HUD" palette (`$113de` credits, `$113fe` attract, `$1139e` loading/text). All values in
`assets/palettes.json`.

**RNG `jt20 k_random $10bcc`**: `x = ($12d70).l` (seed in image `$31415926`); 8× { if (int32)x < 0: x ^= `$0076b553`;
x = rol32(x,1) }; store; return `d0.l = x >> 24` (byte at `$12d70`, 0..255). d1 preserved. Plus every vblank
`x += d1(interrupted) ; x += 1`. The d1 term makes the sequence depend on what the main loop was doing (typically
the `jt18` spin loop, whose d1 is the caller's d1). Port: replicate the LFSR exactly; for the vblank term add 1 +
the translated caller's d1 if available (else just 1) — exact reproduction is not possible anyway.

**Music/fx wrappers**: `jt26` see table; `k_music_stop $10c3a` = `jsr $281c; $2d98=0`. `k_music_fade_step $fed6`:
if `$2d98`≠0 then `$2d98`−1 (`$2d98` = master music volume 0..$40, used by the driver as `vol*$2d98>>6`).
`jt27 k_fx $10c50`:
```
if !($66 & 2) return; d0 &= $ff
if d0 < $80: if byte $4012 != 0: d0 |= $200;  fx(d0)          ; channel 0, or 2 if ch0 busy
elif d0 >= $82: fx(d0); fx(d0|$200)                           ; channels 0 and 2
else ($80/$81): fx(d0|$100); fx(d0|$300)                      ; channels 1 and 3
fx(x) = movem all; jsr $2838; movem   (bits 8-9 of d0 = channel)
```
Kernel fx calls: attract `jt27($80)`; cheat key accepted `jt27(2)`; F10 `jt27(0)`. Kernel tunes: 0 title
(boot/warm start), 1 hiscore entry, 3 loading screen; the F10 handler restarts `$12cce`.

**`k_onoff_text $10ca2`**: if `$66`≠`$12d6e`: copy; patch "ON "/"OFF" into `$115a6` (after "MUZAK: ") by bit0 and
`$115b0` (after "FX: ") by bit1 of `$66`.

---------------------------------------------------------------------------------------------------------
## (c) RAM variables

### a6 block `$12dde` (`$76` bytes, all zero in the disk image)
| off | abs | size | meaning | writers / readers |
|---|---|---|---|---|
| $00-$1d | 12dde | 5×6 | man records: +0 grenades (0-9), +2 ammo (0-$90), +4 wounds (0-4; 4 = dead) | sections; jt06/jt13 read via `$1e` |
| $1e | 12dfc | l | pointer to current man record (= a6 + 6×index) | `$fcc8`, sections |
| $22 | 12e00 | w | current man index 0-4 | `$fcc8`, sections |
| $24 | 12e02 | w | map icon flag | sections; jt02 |
| $26 | 12e04 | w | compass shown flag | sections; jt01 |
| $28 | 12e06 | w | TNT icon flag | sections; jt02 |
| $2a | 12e08 | w | compass direction (&3) | sections; jt01 |
| $2c | 12e0a | w | gun/flare count (S1, 0-8; top bar when `$54`) | sections; jt02, `$10906` |
| $2e | 12e0c | w | morale, 8.8 fixed (`$9000` at new game; bar = high byte>>1) | `$fc9a`, sections |
| $30 | 12e0e | w | text tick countdown | text system |
| $32 | 12e10 | w | text tick period | text |
| $34 | 12e12 | l | text colour ramp table (8 longs colour8:colour9) | kernel/sections |
| $38 | 12e16 | w | text fade step 0-7 | text |
| $3a | 12e18 | w | text fade direction ±1 | text |
| $3c-$47 | 12e1a | 6 w | text queue (indices) | jt11 |
| $48 | 12e26 | w | text queue count (0 = idle; sections poll it) | text, sections |
| $4a | 12e28 | l | text table pointer | kernel (`$1141e`), sections |
| $4e | 12e2c | l | score, 8 BCD digits | jt03, `$fc9a` |
| $52 | 12e30 | b | score printed flag (tas) | jt03 clears, jt05 sets |
| $54 | 12e32 | w | top bar mode (0 grenades, ≠0 flares) | sections |
| $56 | 12e34 | b | vblank flag | vblank sets, jt18 clears |
| $58 | 12e36 | b | split line + $3c | jt32 |
| $5a | 12e38 | l | current top palette pointer | jt30, fades |
| $5e | 12e3c | l | current HUD palette pointer | jt31, fades |
| $62 | 12e40 | l | draw buffer `$70000`/`$78000` | jt24, jt19 |
| $66 | 12e44 | b | sound flags: bit0 music, bit1 fx (3 at first boot; F10 cycles 3→0→1→2→3) | vblank, init |
| $68 | 12e46 | w | timer enable | sections, `$fcc8` clears |
| $6a | 12e48 | w | timer vblank countdown (reload `$31`) | vblank, sections |
| $6c | 12e4a | b | timer minutes BCD | vblank, sections |
| $6d | 12e4b | b | timer seconds BCD | vblank |
| $6e | 12e4c | w | next load-section index | `$fc9a`, jt29 |
| $70 | 12e4e | w | cheat flags: bit0 CHEAT!!!, bit1 MEGA CHEAT (never cleared) | cheat check; sections |
| $72 | 12e50 | w | game-window BPLCON1 value (copied at the split each frame) | sections |
| $74 | 12e52 | b | first-boot done flag | init |

### Other kernel variables
`$10dbe` w logo cycle counter; `$10dc0` b logo cycle state; `$10ea2` w cheat key-held flag; `$10ea4` l cheat
sequence pointer; `$10ea8` w pause colour; `$10eaa` w pause state (`$10eab` low byte); `$1069e` b wound-draw flag;
`$115b3`,`$115c2` cheat flags (also string terminators); `$115f2/$115f6/$11638/$1165e` copper values;
`$116cc-$12ccb` hiscore track image; `$12ccc` w F10 debounce; `$12cce` w current tune; `$12cd0`/`$12cf0`
16-word fade buffers (top/HUD); `$12d1e` w retry count; `$12d20` 4 longs saved d0/d1/a0/a1 for retries;
`$12d60` w junk (d3 stored by save); `$12d62` cache `$28`; `$12d64` cache `$24`; `$12d66` cache `$2c`; `$12d68`
cache `$26`; `$12d6a` cache `$2a&3`; `$12d6c` cache TIME; `$12d6e` cache `$66` for ON/OFF text; `$12d6f` cache
`$66` for icons; `$12d70` l RNG; `$12d74` b swap pending; `$12d76` l next copper list; `$12d7a` 25 l row offsets.

### Resident variables
`$418` l font pointer (`$12e54`); `$41c/$41e` w text cursor col/row; `$2404` 16 b text colour table
(`[plane*4+slot]` = bit of the slot's colour); `$2434` 25 l row offsets; `$2498` 16 b key matrix (bit code&7
of byte code>>3); `$24a8` w last joystick; `$23e4` keyboard ASCII buffer (count + 16); `$23e2` monitor active;
`$24aa..$2503` saved registers / PC `$24fc` / SR `$2500`; `$10d6` go address `$f800`; `$922` drive; `$d16` saved SP.

---------------------------------------------------------------------------------------------------------
## (d) Data formats (all extracted by `extract.py`, compared pixel-exact with emulator screenshots)

1. **Text font `$12e54`** (`assets/font_12e54.png/.json`): 64 glyphs for chars `$20-$5f`, 16 bytes each =
   8 rows × 1 big-endian word, 2 bits/pixel (bits 15-14 = leftmost). Pixel value v (0-3) is mapped to palette
   index `slot[v]` (set by print codes 1..4). Special glyphs: `$25 %` = up arrow (name-entry cursor), `$40 @` =
   blank, `$5b` = &, `$5c` = heart, `$5d` = ← (DEL), `$5e` = ↲ (END), `$5f` = _. Chars ≥ `$60` would read the HUD
   graphics. Verified by re-rendering "LOADING..." against a screenshot (0 diff).
2. **Print strings** (`$408`): `[col,row]`, then bytes: `0` → next two bytes are a new `[col,row]`; `1..4` → slot
   (code-1) := colour (next byte & 15); `$05-$7f` char; `$ff` end; `$80-$fe` → print (b&$7f) and end.
   All kernel strings decoded in `assets/strings.json` (ordered ops).
3. **HUD cells** (`assets/hud_cells.png`): 8×8, 32 bytes, per line 4 bytes plane0..3. `$13254` heart, `$13274`
   bullet, `$13294` grenade, `$132b4` small wound mark, `$132d4` flare. **Icons** (`assets/hud_icons.png`): 24×24 =
   3×3 cells row-major (288 bytes): `$132f4,$13414,$13534,$13654` compass N/E/S/W, `$13774` map, `$13894` TNT,
   `$139b4` wound splat, `$13ad4` gun, `$13bf4` music on, `$13d14` fx on, `$13e34` music off, `$13f54` fx off.
   Rendered with section 0's HUD palette (`$1a018`).
4. **Kernel RLE** (`k_rle_decode`): `$14074` logo 320×48 (`N=$780`/plane, ends `$14ec1`), `$14ec4` attract picture
   160×151 (`N=$bcc`, ends `$16a6c`). Format above. `assets/logo.png`, `logo_cycle.png`, `attract.png`
   (exact match at canvas (17,36) and (97,84)).
5. **Loading picture** (tracks 18-20 → `$70000`): 34-byte header (word `$8000` + 16 colours, **unused**), then
   ByteRun1 (b<`$80`: b+1 literals; b=`$80` nop; else 1+((-b)&$7f) repeats) producing 200 rows × 4 planes × 40
   bytes interleaved per row (row y plane p → `$78000+p*$2000+y*40`); the decoder `$761dc` stops after 200 rows
   (pops its return address). Palette = `$766d2` (16 words used). `assets/loading_picture.png` (exact at (33,36)).
6. **Palettes** `assets/palettes.json`: `$1137e` logo (runtime c0=0,c1=0,c6=`$fff` then cycled), `$1139e`
   loading/text, `$113be` black, `$113de` credits/hiscores, `$113fe` attract grey ramp, ramps `$1133e`/`$1135e`.
7. **Hiscore track** (track 77 → `$116cc`, `$1600` bytes; `assets/hiscore_original.json`):
   `$116cc` title string `[12,9] slot0=0 slot1=1 slot2=2 "TEN BEST SCORES:" $ff`; `$116e5` 10 entry strings
   of 25 bytes: `[7,11+k] 02 c 03 c' <16-char name> "  " $ff` (name at +6); `$117e0` 10 longs = offset of entry k
   from `$116e5` (0,$19,…); `$11808` 10 BCD score longs (descending); `$11830` name-entry line (see name entry).
   **The Darc image's track 77 is all zeros** → on the crack the hiscore page shows only garbage ("L" and
   "00000000"), the name entry line is invisible and entries are written to `$116eb`. The original contents
   (from `re/platoon_b.adf`, "MPU/CIA A/CIA B/IKBD/ANGUS/BLITTER/COPPER/DENISE/DMA/PAULA", 68000…2) were verified
   to work with the Darc code (`work/darc_hs.adf`). **Port: embed the original table** (and optionally persist).
8. **Copper lists** `assets/copper.json`. **Row table** `$12d7a`: n×320. **Bar masks** `$1131e`: 8 longs
   `$00,$80,$c0,…,$fe` repeated in each byte. **Section loader table** `$11166`, names `$1118a`.
9. **Monitor font `$2094`**: 96 chars 8×8 1bpp (`assets/monfont_2094.png`).
10. `$2538-$f7ff`: only `reloc_stub $253c` is kernel; `$2800-~$3ff8` music driver (API `$2800` play, `$280e` tick,
   `$281c` stop, `$2838` fx), `$4000-$f7ff` sample data — audio module.

---------------------------------------------------------------------------------------------------------
## (g) Input semantics

- **Joystick `$410` (res_joystick_impl `$1c30`)**: reads JOY1DAT (port 2) → `d0` bit0 DOWN, bit1 RIGHT, bit2 UP,
  bit3 LEFT (XOR-decoded), bit7 FIRE (CIA-A PRA bit7 low); stored at `$24a8`; **clobbers d2**.
- **Keyboard (level 2 `$169c`)**: INTREQ `$0008` cleared first; ICR read; if SP: code = ~ror(SDR); handshake
  CRA bit6 set/clear around the handler (very short pulse); key up → clear matrix bit; key down → set matrix bit and,
  if keymap char ≠ 0, append ASCII to `$23e4` (max 16; shifted map if matrix `$24a4` bits 0/1 = L/R SHIFT);
  char `$7f` (DEL key, raw `$46`) → save registers/SR/PC and `jmp ($10d6)` = `$f800` (**warm restart to title**,
  verified; not an RTE). ICR FLG → `$1188`=`$ff`.
- `$40c` (keytest) d0 = raw code → d0 = −1/0 with flags; `$42e` (getkey) lowest held raw code (Z if none).
- Kernel keys: **TAB `$42`** pause toggle (press+release to pause, press+release to resume); **F10 `$59`** cycles
  `$66` music/fx (3 both → 0 none → 1 music → 2 fx → 3); **DEL `$46`** restart. Fire starts the game from any
  title screen; fire skips "ENTERING THE COMBAT ZONE"; name entry: LEFT/RIGHT change letter, FIRE accept.
- **Cheats** (only checked by `k_title_poll` on title screens while fire is not pressed; `$42e` gives the lowest
  held key; a key must be released (no key held) before the next is accepted; wrong key → restart the sequence):
  1. `H A M B U R G E R` (raw `25 20 37 35 16 13 24 12 13`, `$11207`) → `$115b3`:=0 (credits page now also prints
     "CHEAT!!!" at [16,24]), `$70(a6)` |= 1.
  2. then `KEYPAD- H I L L` (raw `4a 25 17 28 28`, `$11211`) → `$115c2`:=0 ("MEGA CHEAT" at [15,24], further
     checks disabled), `$70(a6)` |= 2. Each accepted key plays `jt27(2)`. Verified: `$70`=3 and "MEGA CHEAT" shown.
  Effects (section code): S0 (`$171c6`, any bit): F1/F2/F3/F4 warp to start positions (`$1a6da` := `$50001`,
  `$2d0004`, `$410001`, `$410000`, restart at `$17070`), F5/F6 debug overlay on/off (`$60ca0`, `$19f5e` prints
  hex values). MEGA CHEAT (bit1): S1 HELP (`$5f`) at `$178be`/`$18bd8` → skip (`$18afe`/`$18e6c`); S2 CAPS LOCK
  (`$62`) at `$1711e` → `$17c0a`. (Details belong to the section modules; **unverified** beyond the code.)

---------------------------------------------------------------------------------------------------------
## (h) Gameplay rules implemented in the kernel

- New game: morale `$2e`=`$9000`, score 0, section 0. Morale shown as 9 hearts = high byte/2 (sections add/sub
  words, e.g. S0 `add.w #$200` = +2 morale units).
- Score: BCD add only (jt03), no bonus logic in kernel; hiscore #1 shown on HUD from the table.
- Timer: countdown mm:ss BCD, 50 vblanks/second while `$68`≠0; wraps 00:00→59:59 (sections check).
- Wounds: HUD shows man+4 splats; 4 = dead (sections' man-select logic skips men with 4).
- Hiscore: unsigned BCD compare, ties insert above; 16-char names.
- RNG as above. No other gameplay in the kernel.

## (i) Sound calls from the kernel
`jt26(0)` title at init; `jt26(3)` at jt29 (LOADING); `jt26(1)` hiscore entry; `k_music_stop` before rank
search and at init; volume fade `$2d98` during GAME OVER; `jt27($80)` when the attract picture appears;
`jt27(2)` per accepted cheat key; F10: `jt26($12cce)` + `jt27(0)`.

---------------------------------------------------------------------------------------------------------
## Resident `$400-$2537`

Jump table `$400`: `$400` init (`bra $566`), `$404` putchar, `$408` print, `$40c` keytest, `$410` joystick,
`$414` register dump, `$418` font ptr, `$41c/$41e` cursor, `$420` disk load, `$424` disk save (**crack stub**:
`move.l a7,$d16; clr.l d0; rts`; the original writer at `$aa4` is dead code), `$428` 0, `$42a` → rts, `$42e` getkey.

**putchar `$1e46`** (d0 char; saves d0-d7/a0-a3): col = `$41c`&63, row = `$41e`&31; if c ≥ `$20`: glyph =
`($418) + (c-$20)*16`; dest = `$70000 + $2434[row] + col` and dest^`$8000` (= `$78000+…`); for 8 rows: 8 pixels
v → plane p bit = `$2404[p*4+v]`; write the 4 plane bytes (move, not OR) to both buffers (+`$2000` per plane,
+40 per row); col++. `$0d`: col=0,row++. `$08`: col−1 (wrap to 39 / row−1 / row 24), print space, restore
cursor. Then (all cases) if col ≥ 40 {col=0; row++; if row ≥ 25 row=0}.
**print `$1a5c`** (a0; saves d0-d2/a0): format §(d).2; colour code handler `$1aa2`: slot=(code−1)&3,
n=next&15, `$2404[slot+4p]` := `$2394[n*4+p]` (bit p of n).
**keytest `$1ca6`**, **getkey `$1c6c`**, **joystick `$1c30`**: §(g).
**disk_load `$d1a`** (d0 track, d1 count, a0 dest; saves all; returns d0=0): d1−1<0 → exit. `disk_seek $dca`:
PRB=`$ff`, MTR on (bit7=0), SEL0 (bit3=0), wait /RDY, DIR=out, step (bit0 pulse + `$2800`-loop delay) until /TRK0,
SIDE bit2 := 1 then 0 if track odd; step in track>>1 times. Per track: `disk_read_raw $e6a` (ADKCON `$8500`,
DSKSYNC `$4489`, wait /RDY, DSKLEN `$4000`, DSKPT `$68000`, DMACON `$8210`, DSKLEN `$9f40` twice, wait INTREQR DSKBLK,
ack, DSKLEN `$4000`, ADKCON `$0400`); decode 11 sectors: find `$4489` (skip a second one), sector = high byte of
the odd/even-decoded info word, data = 128 longs `((odd<<1)&$aaaaaaaa)|(even&$55555555)` with even at +`$200`,
stored at a0 + sector*512 (no checksum, no timeout); a0 += `$1600`; d0++; `disk_step_next $ede` (toggle side,
step in when d0 even). End: `disk_motor_off $f0a`; CIA-A PRA bit1 := 0 (LED). Port: read ADF bytes directly.

**Exception handlers / debug monitor ("CBM Amiga Monitor V2.0", apparently ported from an Atari ST monitor:
G writes MFP `$fffa07/9`)**: vectors bus `$1af0`, address `$1b40`, illegal `$1b68`, div0 `$1b9a`, CHK `$1baa`,
TRAPV `$1bba`, privilege `$1bca`, line-F `$1bda`, autovectors 1-7 & uninitialised `$1bea`, spurious `$1bfa`,
traps 0-13/15 `$1c0a`, trap 14 `$1c1a` (sets `$10a4`). Each: set up the monitor screen (`$1322`: DMA off,
BPLCON0 `$1200` (1 plane), DDF `$38/$d0`, DIW `$3c81/$04c1`, COLOR00 `$fff`, COLOR01 0, COP1LC `$23d4`
(plane at `$78000`), kbd init, clear), print message ("Bus Error at ", …), save registers to `$24aa`, register
dump `$141c`, then command loop `$6e8` ("CMND:" prompt, `$1a1e` 1bpp print via `$1d0a` with font `$2094`).
Commands (`$742`/`$756`): M `$118a` memory dump, R `$c94` read track, W `$938` write track, D `$10de` serial
download, J `$10a6` jump, G `$1060` go (restore regs, RTE), V `$1318` redisplay, CR/−/1-4 `$12e0-$130e` move
dump address, X `$11d4` edit, TAB `$1204`, H `$7a4` hunt ("HUNT FOR L/W/B/T"), N `$828` hunt next, B `$7a2` rts,
S `$924` select drive. Several entry points are damaged in this build (e.g. `$131e`). ESC in monitor input →
`$6c6`. **Not needed for the port** (only reachable on CPU exceptions); a port should just abort/log.

---------------------------------------------------------------------------------------------------------
## (f) Rendering summary for the Swift virtual chipset
- Two 320×200×4-plane buffers at `$70000` and `$78000` (planes +`$2000`; 40 bytes/line); the kernel's blits are
  plain A→D copies (BLTCON0 `$09f0`, BLTCON1 0, masks `$ffff`, A modulo 0, D modulo 0 or 20); text/HUD are CPU
  writes. No sprites, no dual playfield, no HAM.
- Per frame: top area lines 0..split from the current buffer with top palette, BPLCON1 = `$72(a6)` latched at the
  previous frame's split, DIWSTRT from `$115f6`; HUD from `$78000` lines split+1..199 with HUD palette, HUD
  BPLCON1 `$1165e`, DIWSTRT `$3c71`. Pause changes COLOR00 at the split line (HUD background).
- Present at vblank using the copper list latched at the last split-line event.

## Regenerating the listing / assets
```
W=re/kernel/work; COV="--cov $W/boot/boot.hist --cov $W/title/title.hist --cov $W/go/go.hist --cov $W/ne/ne.hist --cov re/cov/section0.hist --cov re/cov/section1.hist --cov re/cov/section2.hist"
python3 tools/rdis.py $W/boot/play0.bin 400 2538 $COV --labels re/kernel/labels.txt > $W/part1.s
python3 tools/rdis.py $W/boot/play0.bin 2538 2800 $COV --labels re/kernel/labels.txt > $W/part2.s
python3 tools/rdis.py $W/boot/play0.bin f800 16a6c $COV --labels re/kernel/labels.txt > $W/part3.s
python3 tools/rdis.py $W/boot76.bin 76000 76700 --cov $W/boot/boot.hist --labels re/kernel/labels.txt > $W/part4.s
python3 re/kernel/work/mklisting.py        # -> re/kernel/kernel.s
python3 re/kernel/extract.py               # -> re/kernel/assets/
```
(`work/boot/play0.bin` = chip RAM at frame 1100 of a normal boot+start; `work/boot76.bin` = boot loader image.)
Measured swap rates (jt19 calls / 200 frames from the shared play states): S2 200 (50 fps), S0 24 and S1 25 (those
states sit in a hit/man-select phase) — the game-logic rate is section-defined.

## Emulator notes
- capstone mis-decodes `sbcd -(a1),-(a0)` ($8109) (kernel.s patched) and prints `btst #n,d16(pc)` EAs 2 bytes low.
- Emulator keyboard injection bypasses the handshake timing (the handler's CRA-bit6 pulse is only a few µs;
  real keyboards need ≥85 µs — harmless in practice on real HW? **unverified**).
- No emulator changes were needed.

## (j) Open questions
- Original (non-crack) `$424` save routine: the dead writer at `$aa4` suggests a real track-77 write; the
  crack disabled it. Port decision: persist hiscores in app storage.
- Which disk image content should the port use for track 77? (Darc is blank → use platoon_b's table.)
- Exact d1 contribution to the RNG in the original timing is unreproducible; section-level determinism
  therefore cannot match the original bit-for-bit.
- Text-table rows used by sections for queued messages must lie in the HUD region (only HUD colours 8/9 fade);
  confirmed for kernel texts, assumed for sections.
- The "IS INNOCENCE" kernel text (index 1) is never queued by the kernel (picture has it baked in); check if a
  section uses kernel table index 1 (none found).
