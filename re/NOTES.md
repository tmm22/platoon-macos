# Platoon (Amiga, Ocean 1988): reverse-engineering notes (shared)

**Use `re/platoon_port.adf`** = Darc image with tracks 77 (hiscore table, blank in Darc) and 127 (section-2 room
pictures, corrupt in Darc) taken from `re/platoon_b.adf`. It is what the port ships/reads.

Base disk image: `re/platoon_darc.adf` (the "[cr 68 Darc]" dump). The Beyonders crack (`re/platoon.adf`) has
corrupt tracks in the third load section (tracks 111+); do NOT use it for section C. `re/platoon_b.adf` = original
(protected, bad dump, encrypted bootblock) — identical to Darc for all game data tracks except 0,1,13,77-83,127.

Credits: programmed by Sean Pearce & Colin Gordon, graphics Sharon Beattie, music/fx David Whittaker.

## Disk layout (track = 11*512 = $1600 bytes, ADF offset = track*$1600, DOS-format MFM tracks, cracked loader)
| tracks | content | load address |
|---|---|---|
| 0 | bootblock (crack): loads $2c00 bytes from ADF $70c00 to $76000, jmp $7613a | |
| 1-17 | main program image ($17 tracks), loaded to $400; code at $2538 relocates $404.. down to $400 | $400-$17a00 |
| 18-20 | Ocean loading picture, byte-RLE into 4 bitplanes at $78000 (see loader $761dc) | $70000 |
| 21-76 (56 trk) | Section 0: "THE JUNGLE & VILLAGE SECTIONS" | $17000-$64000 |
| 77 | hiscore table (1 track) | $116cc |
| 84-110 (27 trk) | Section 1: "THE TUNNEL & FLARE SECTIONS" | $17000 |
| 111-158 (48 trk) | Section 2: "THE JUNGLE & FOXHOLE SECTIONS" | $17000 |

Game sequence: Jungle -> Village -> Tunnels -> Flare/Bunker -> Jungle (2 min before airstrike, find bunker) -> Foxhole.

## Memory map (chip RAM 512K, no other RAM used)
- $000-$3ff vectors; SSP = $400 (stack grows down below $400).
- $400-$2534 resident: jump table at $400 (bra's); $420 -> disk loader $d1a (d0=track, d1=count, a0=dest; returns d0=0 ok);
  $566 init; debug monitor ("CMND:" prompt, shown on illegal instruction/exceptions); exception vectors -> $1bxx.
  Level-2 (CIA-A/keyboard) at $169c. $40c = key test? (d0=keycode, returns Z).
- $2538-$f7ff: title/music/fonts/etc. Music driver around $2800-$3ff8 (jsr $280e called each vblank from $10eac).
- $f800-$12dde "kernel": jump table at $f800 (bra's) used by the section code; a6 = $12dde is the global variable base.
  $f890 kernel entry. Level-3 handler at $10eac (vblank: music, timers, keyboard checks, sets $56(a6) frame flag).
  Level-6 handler at $10faa: CIA-B TOD alarm used as a raster interrupt (TOD counts hsync, reset each vblank) — swaps COP1LC
  when $12d74 flag set ($12d76 = next copper list). $10ad6 = wait for vblank (clr.b $56(a6); loop until set).
  $10b14 = wait for copper-list swap. $101d0 = load with retries (d0 track, d1 count, a0 dest).
  Section loader table at $11166 (index = word $6e(a6) = $12e4c): 0 -> tracks $15,$38 ; 1 -> $54,$1b ; 2 -> $6f,$30; all to $17000.
  Strings (texts, HUD labels) around $11172-$115d0; "MEGA CHEAT" at $115c5.
- $17000..: section code (entry $17000) followed by section data (graphics, maps, samples).

## How to reach sections in the emulator
Title appears ~frame 250. Script (frames): `300 fire 1`,`305 fire 0`, then `350 poke 12e4c N 2` (N = section 0/1/2),
`600 fire 1/605 fire 0`, `900 fire 1/905 fire 0`. Gameplay by frame ~1000. Saved states (frame 1000, in play):
`re/states/section{0,1,2}_play.state` (load with `--load-state`); RAM dumps `re/dumps/ram_section{0,1,2}.bin`.
Coverage histograms (random play): `re/cov/section{N}.hist`.

## Tools
- `tools/amiga/emu` — headless A500 emulator (Musashi CPU + copper/blitter/bitplanes/sprites/CIA/disk/Paula).
  `./tools/amiga/emu --help`. Screenshots are 384x290 PNG (lowres pixels; canvas origin DIW h=$60, v=$18).
  Scripts: one event per line `FRAME CMD ARGS` (frame relative to start/loaded state).
  Build: `make -C tools/amiga`.
- `tools/rdis.py RAM LO HI --cov HIST --labels FILE` — recursive-descent disassembler with labels/xrefs.
- `tools/m68kdis.py FILE OFFSET LEN BASE` — linear capstone disassembly.
