# Kernel verification (boot, title, HUD, flow, hiscores)

Tools (in `port/verify/kernel/`):
- `pair.sh NAME SCRIPT FRAMES SHOTEVERY [args]` runs `tools/amiga/emu` and `platoon-headless` with the same script
  (outputs `/tmp/verify-kernel/NAME/{emu,port}`), `@` in args is replaced by `emu`/`port`; the port runs with
  `PLATOON_ENH=originalCredits=0` (crack text, as the emulator) unless PLATOON_ENH is set.
- `cmpshots.py A B` pixel diff of same-named PNGs; `cmphash.py` per-frame `--hash` comparison; `cmpwav.py` 50 Hz RMS
  envelope correlation.
- Disk: `re/platoon_port.adf` for both.

Environment overrides added to the port (Game.swift, for the headless tool which has no options for them):
`PLATOON_ENH="originalCredits=0,..."`, `PLATOON_HISCORES=FILE` (config.hiscoreURL), `PLATOON_CARRY=FILE` (config.carry).

## Results

| # | scenario | method | result |
|---|---|---|---|
| 1 | boot + 2 full title cycles (credits, hiscores, attract, logo colour cycle), 2600 f | pair.sh title, shots every 20 f, `--hash 12dde 78` | 131/131 shots identical, a6 block identical every frame |
| 2 | boot every frame 0-400 | shots every frame | 399/401 identical: f41 (116 px, boot palette written 1 colour per ~line) and f90 (display re-init mid-frame: in the emu the copper executes list B right after the COPJMP1 strobe, before the CPU writes the black palette; the port's copper runs per line) |
| 3 | kernel data $10ef0-$12e54 over the title loop (--deterministic) | `--hash 10ef0 1f64` | identical except single frames at f79/82 (boot loader), f189 (hiscore track: emu DMA writes sector by sector), f191-193 (credits ON/OFF patch done at the start of the 2-frame clear instead of at its end - CPU-time model writes RAM before paying the time; not visible) |
| 4 | cheat HAMBURGER + KP- HILL (re/kernel/work/cheat.txt) | shots every 10 f to 2400, dumpr $12e4e | $70(a6)=3 both, 239/240 identical (f90 above), "MEGA CHEAT" on the next credits page identical |
| 5 | cheat with a wrong key (H A B -> reset) then HAMBURGER, then overlapping KP-/H press | hash $10ea0+$10 every frame, shots | cheat state identical every frame, "CHEAT!!!" on credits identical |
| 6 | F10 x5 on the title (3->0->1->2->3->0) | shots, hash, WAV | shots identical, RAM identical (except onoff-patch timing as #3), audio envelope corr 0.999 at lag 0; credits show MUZAK/FX OFF on the next page |
| 7 | ENHANCEMENT originalCredits (default on) | port shots at f400 with/without PLATOON_ENH=originalCredits=0 | on: `[7,11] GAME DESIGN (C)1988 OCEAN.` + `[10,13] CONVERSION BY CHOICE` (colours 5/6, the original bytes from platoon_b); off: crack text, identical to the emu |
| 8 | section 0 in play: TAB pause x2 (HUD COLOR00 cycling, timer frozen), F10 x4 in game (sound icons), pokes of score/morale/grenades/ammo/map/compass(+dir)/TNT/gun/flare-bar mode/timer 01:05 and clearing them | hud.txt 1800 f, shots every 5, `--hash 12dde 78`, tickdump $17186 | before fix: all pause frames differed (HUD background black in the port); after the TOD fix: all HUD/pause/icon frames identical; 81 ticks identical incl. frames; remaining diffs only the section-0 dissolve pattern (R1) |
| 9 | DEL from the title (f500) and from section 0 play (f1900), new game after each | del0.txt 3200 f | a6 identical all frames except 5 single frames; shots identical except section-0 dissolves |
| 10 | LOADING/ENTERING for sections 1 and 2 (`312 poke 12e4c N 2` before the name is printed), section play, DEL from sections 1 and 2 | del1/del2.txt 2600 f, tickdumps $171c6/$17118 | LOADING shows "THE TUNNEL & FLARE SECTIONS." / "THE JUNGLE & FOXHOLE SECTIONS.", shots identical (1 in-flight glyph frame each); a6 identical all frames (S1); S1 573 ticks identical; S2 484 ticks: RAM identical, 7 ticks one frame early (md_sfx cost, reported to audio) |
| 11 | game over S0 (morale poke, score 12345) + name entry with every key: LEFT/RIGHT cycling incl. wrap $5f->$40, DEL glyph at position 0 (no-op) and later (back one), END glyph, LEFT+RIGHT together / UP / DOWN ignored; table; SAVING; title; second game (score 10000) with the pre-filled name accepted by 16 x FIRE | hs.txt 4200 f (mk_hs.py), shots every 20 + one per input, `--hash 116cc 1600` | all name-entry shots identical (sequence: ← at pos0 no-op, A, @/A/B, DEL back, A, END -> "AA"; second entry pre-filled "AA"); table after entry and hiscore page on the title identical; hiscore track RAM identical except single frames (RAM written before the CPU time of a preceding long print elapses) |
| 12 | game over S1 (morale 0 -> "WITHDRAWN FROM ACTION" -> fire) score 0 -> no entry -> title | go1.txt 2400 f | shots identical; a6 identical except f1006 / f2392 |
| 13 | game over S2 by the airstrike timer (poke 00:03 -> 00:00 -> 59:59 wrap shown, napalm flash, text, fire) with score 9000 -> name entry "A" + END -> table -> title | go2t.txt 2900 f | hiscore track identical except 2 single frames; shots identical except flash step frames 1410-1480 (1 frame late, section 2 timing after the md_sfx cost) |
| 14 | hiscore rank rules: score 2 ties the last entry (k=9, no shift, replaces), score 8520 ties 2 entries (inserted above both), score 1 not qualifying (no entry, table unchanged); pre-filled name = spaces after an END entry | tie.txt 4400 f, dumpr of the table after each game | tables byte-identical to the emu after each game |
| 15 | persistence: PLATOON_HISCORES=FILE, first run enters "AA" 12345 (file written by the $424 save hook), second run of the headless tool boots with the file | port only | file = 5632 bytes; reloaded table byte-identical to the saved one; hiscore page shows AA 00012345 |
| 16 | config.startSection 0/1/2 (`--start-section N`) vs emu boot + fire (+poke) | tickdumps by index | S0 81 / S1 391 / S2 484 ticks RAM identical, constant offset 114 frames (S2: the 7 md_sfx ticks) |
| 17 | config.carry (PLATOON_CARRY = a6 image dumped from the emu after pokes: score 12345, morale $5000, man0 3 grenades/64 ammo/2 wounds, map flag, fx off) + --start-section 1 | tickdump $171c6, shots | 391 ticks identical, HUD shows the carried values identically |

## Fixes
- k_init: hiscore-track load passes d0 = $0007004d like the original (upper word left over), so the saved retry
  args at $12d20 match the emulator.
- ENHANCEMENT `enhancements.originalCredits` (default true; `Platoon.swift`, hook in `Resident.swift`
  `reloc_stub` -> `restoreOriginalCredits()`): see below.
