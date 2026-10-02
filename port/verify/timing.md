# Real-A500 timing and Paula model (verification)

The port was first verified frame by frame against `tools/amiga/emu`, a Musashi-based emulator that gives the 68000
every bus cycle and completes blits instantly. Several of the original main loops have no fixed rate: they are
CPU/blitter-bound, so their speed on a real A500 depends on exactly what the emulator leaves out. This file records
how the real speed was measured, how the port reproduces it (now the default), and how the emulator timing is kept
for the lockstep gates.

## The disk image is not the cause
The three dumps in `re/` (Darc, Quartex `platoon_b.adf`, Beyonders) hold identical game code. They differ only in
the crack credit strings and the hiscore name table (track 13, $112c5-$1173x), in the resident disk loader's DMA
wait / sync code (track 1, $a9a-$ebc) and in tracks outside the loaded ranges. None of it is timing-relevant.

## Measurement: vAmiga, tick-locked to the reference
`tools/vamiga/drv` runs the original game on the vAmiga core (cycle-exact 68000, blitter, copper, DMA slots and
disk; A500 OCS PAL, `A500_OCS_1MB` scheme). AROS boots, then the cracked bootblock is high-level emulated exactly
like `tools/amiga/emu` does it, and everything after that is original code. `--deterministic` is applied the same way.

Per-frame input scripts drift apart once two machines run at different speeds, so the comparison feeds input **per
tick**: the joystick byte the game read in each tick ($60cc1 in section 0) is taken from the emulator's tick dumps and
applied at the same tick index in vAmiga and in the port (`platoon-headless --tickinput`). With that, all three play
the identical game, which is checked: the tick dumps are byte-identical. Only the time per tick differs.

| Calibration check | |
|---|---|
| CPU-only code (`$1e46` text printing, no blits) | emu 17.5 lines/glyph, vAmiga 18.7 (+6.6 %: 68000 bus alignment on chip RAM) |
| Tunnels (fixed 4-vblank tick, `$171d8`) | 4.00 frames/tick in both: unaffected |

Frame length of the CPU/blitter-bound loops (frames per tick; tick-locked runs unless noted):

| Loop | tools/amiga/emu | vAmiga (real A500) | port, real-A500 timing (default) |
|---|---|---|---|
| Jungle `$17186`, jungle_route3 (4088 ticks) | 2.00 | 2.765 (2:995 3:3062 4:27) | 2.773, total +0.28 %, 79 % of ticks equal |
| Jungle + village `$17186`, honest_village (5883 ticks) | 2.00 | 2.789 | 2.797, total +0.26 %, 83 % of ticks equal |
| Final jungle `$17118`, napalm idle 2 min (3048 ticks) | 1.00 | 1.962 | 1.962, total +0.02 %, 98 % of ticks equal |
| Flare `$18bd8`, fl_idle (frame-based input, 409 iterations) | 1.98 | 2.49 | 2.51 |

So on a real A500 the jungle and village run at ~18 ticks/s (mostly 3 frames per tick, not 2), the final jungle at
~25 ticks/s (not 50; the 2-minute napalm countdown gives about 3050 ticks, not 6000) and the flare night ~20 %
slower than in the emulator. The port with the emulator's timing ran those parts about 40 %, 95 % and 25 % too fast.

## The model (KernelSupport.swift, "Real-A500 timing")
Fitted on the 4081 jungle ticks of jungle_route3 (vAmiga time per tick against the emulator's CPU cycles and the
blits of the same tick): real time = 1.066 x Musashi CPU cycles + 2.93 CPU cycles per blitter DMA cycle
(residual 0.03 frames per tick). In the port:
- `cpuCycles` stays in Musashi cycles; a raster line holds `cpuLine` = 426 of them (454 / 1.066) instead of 454.
- every blit adds `Chipset.blitDMACycles` (the OCS cycle diagram: 2-4 DMA cycles per word by the channels in use,
  4 per pixel in line mode) x `a500BlitCost` / 1000 Musashi cycles (2720, end-to-end tuned against vAmiga).
The same two constants, unchanged, reproduce the final jungle and the flare, which were not used for the fit.

## Paula (Paula.swift, `accurate`)
- Audio DMA: one word per channel and raster line, in the channel's slot. A word request is raised when Paula loads
  a word and served at the next slot; if the next load comes first, Paula replays the old word. Periods >= 114 are
  unaffected (identical output); below, the loop advances one word per line and the pitch is capped (songs 1 and 6
  use periods 86-113 about 11 % of the time: the emulator model played those up to ~3 semitones sharp).
- Filters: the A500's fixed RC low-pass (360 ohm, 0.1 uF: 4421 Hz, one pole) instead of 4.9 kHz, plus the "LED"
  filter (Sallen-Key 10k/10k, 6.8 nF/3.9 nF: 3090 Hz, Q 0.660) while CIA-A PRA bit 1 drives the power LED on. The
  resident loader switches it on after every disk load (`bclr #1,$bfe001` at $db4), the music driver off at every
  song init / sound effect ($2854, $3c90): on an A500 the title music after the hiscore load and the loading-screen
  tunes are heard through it. Discretisation as in vAmiga's AudioFilter.

## Emulator timing for the gates
`referenceEmulator=1` (kernel group, hidden from the Preferences) restores the Musashi CPU timing with instant blits
and the emulator's Paula. `platoon-headless`, the emulator verification runner, defaults to it (`--enh
referenceEmulator=0` plays at A500 speed), so every harness under port/verify keeps working with its emulator-timed
scripts. `tools/regress_all.sh` (all scenarios) and `port/verify/audio/wavcmp.sh` set it explicitly, so they keep
comparing byte for byte against the pinned pre-enhancement baseline; the emulator lockstep information they print is
unchanged. Practice drills are prepared with it (their routes are emulator-timed scripts), and input replays of
format 1 (and plain headless scripts) are played with it; replays recorded now are format 2.

## Re-running
```sh
tools/vamiga/build.sh                                  # fetch vAmiga (pinned commit), build /tmp/vamiga-build/drv
python3 tools/vamiga/timing_check.py --bin port/.build/release/platoon-headless   # ~5 min, cached in /tmp/timing-cache
```
It prints, per scenario, whether the game state stayed identical and the frames per tick of the emulator, vAmiga and
the port. A change to the CPU-time model or to the cost constants should keep "port vs vAmiga" within 1-2 %.
