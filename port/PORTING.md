# Platoon for macOS: developer guide

How the port is built, the rules for changing it, and the tools that check it. Player documentation is in the
[README](../README.md) and the [enhancements guide](ENHANCEMENTS_GUIDE.md).

**Contents:** [Overview](#overview) · [Source layout](#source-layout) · [Translation rules](#translation-rules) ·
[Timing](#timing-and-cpu-cost) · [Verification tools](#verification-tools) · [Regression gate](#regression-gate) ·
[Enhancements](#enhancements) · [Feature areas](#feature-areas) · [Command line and environment](#command-line-and-environment)

## Overview
The port is a **source port**: the original 68000 game logic is translated routine by routine into readable Swift and
runs on a small virtual Amiga chipset written in Swift (`Sources/PlatoonCore/Platform`). All game data (graphics,
maps, tables, text, music, samples) is read from the original disk image at runtime and lives at its original
address in a 512 KB `Memory` image, so translated code uses the original addresses and table layouts unchanged.

- `re/<module>/NOTES.md` is the reverse-engineered specification of each module and the source of truth for the
  original behaviour ([re/NOTES.md](../re/NOTES.md): disk layout, memory map). Annotated listings
  (`re/<module>/*.s`) contain the game's code bytes, so they are not in the repository; regenerate them from your
  disk with `tools/rdis.py`.
- `tools/amiga/emu` (`make -C tools/amiga`) runs the original game headless (Musashi 68000 + chipset). It is the
  ground truth for the logic. `tools/vamiga/` (cycle-exact vAmiga core) is the ground truth for real-A500 speed.
- Every tool, test and the regression gate read `re/platoon_port.adf` (how to make it: [README](../README.md#3-build-and-run)).

```sh
make -C tools/amiga                                    # reference emulator
cd port && swift build -c release                      # everything (--scratch-path /tmp/pbuild-X for parallel builds)
cd port && swift test                                  # unit tests
cd port && ./build_app.sh                              # build/Platoon.app (see the header of the script for options)
tools/regress_all.sh > /tmp/regress.log 2>&1           # regression gate (background, ~5-10 min): must print ALL PASS
```

## Source layout
```
Sources/PlatoonCore/Platform/   virtual hardware (no game logic here)
  Memory.swift       r8/r16/r32 (unsigned), s8/s16/s32 (signed), w8/w16/w32 - big-endian, address & $7FFFF
  Chipset.swift      custom registers: chip.write(reg, v) / writeL / read / readL; copper, sprites, display
                     (renders the canvas line by line), interrupts
  Blitter.swift      exact blitter; a write to BLTSIZE ($058) performs the blit immediately
  CIA.swift          chip.ciaA / chip.ciaB: read(r) / write(r, v), r = register nibble (address >> 8 & 15)
  Paula.swift        audio DMA channels (writes to $0A0-$0DF and DMACON); PaulaMixer.swift: optional mixer stages
  Disk.swift         disk.loadTracks(first:count:to:memory:) == the resident loader at $d1a
  Machine.swift      frame driver + game thread: waitVBlank(), waitFrames(n), waitLine(v); MachineSnapshot.swift
  Input.swift        joystick / fire / keyboard state (feeds JOY1DAT, CIA-A PRA, the keyboard SDR interrupt)
  HostAudioStream.swift  ring buffer and rate control between Paula and the host audio output
Sources/PlatoonCore/Game/
  Game.swift         PlatoonGame.main(m): entry point (boot, then the resident init at $566)
  Platoon.swift      final class Platoon: shared context (m, mem, chip, disk, input) + dispatch helpers
  Resident.swift     $400-$2534
  Kernel*.swift      $f800-$12dde (+ title code in $2538-$f7ff); KernelSupport.swift has the CPU-time model
  Audio/             David Whittaker music driver ($2800-$3ff8) and its optional enhancements
  Section0/          jungle and village (Section0*.swift) + the jungle map and widescreen models
  Section1/          tunnels (Tunnels.swift, Section1Engine.swift) and flare night (Flare.swift)
  Section2/          final jungle (FinalJungle.swift), bunker (Foxhole.swift), navigator model
  Enhance/           option registry, difficulty, context probe and events, high-score tables
  Snapshot/          save states (taken at the four section main-loop heads)
  Assist/            message log, objectives, run tracker, replays, practice drills (headless-testable models)
  Cheats.swift, Trainer.swift   cheat helpers; legacy host trainer (old replays only)
Sources/PlatoonApp/              the macOS app (AppKit, Metal, AVAudio, GameController): GameHost, MetalRenderer,
                                 InputManager, AudioOutput, Menus/, Prefs/, Overlay/, Video/, Input/, Assist/
Sources/platoon-headless/       command-line runner (same script format as tools/amiga/emu)
Tests/PlatoonCoreTests/         XCTest suites (tests that need the game disk skip without it)
```
Every game module is an `extension Platoon { ... }`, so all routines can call each other directly.

## Translation rules
1. **Keep state in RAM.** Variables, object tables, copper lists and bitplanes stay at their original addresses
   (`a6 = $12dde` globals etc.). Define named constants for addresses and small computed accessors where it helps
   readability. Don't mirror RAM state in Swift properties unless it is purely host-side.
2. **One Swift function per original routine**, named descriptively, with a doc comment giving the original address,
   e.g. `/// $10ad6 wait for vertical blank`. Registers become parameters, locals and return values. Keep the exact
   arithmetic: `&+ &- &*`, `UInt16(truncatingIfNeeded:)`, `Int16(bitPattern:)` where the 68000 wraps or
   sign-extends; byte/word/long sizes matter. `ext.w`, `asr` vs `lsr`, `mulu` vs `muls`, `divu` (quotient in the low
   word, remainder in the high word) and condition-code-dependent control flow (`bcc` after `add`, `dbra` counts,
   `tst` then `bmi`) must be reproduced precisely.
3. **Hardware access maps 1:1:** `move.w #x,$dff096` → `chip.write(0x096, x)`; `move.l a0,$dff080` →
   `chip.writeL(0x080, a0)`; `btst #7,$bfe001` → `chip.ciaA.read(0) & 0x80 == 0` (fire pressed when the bit is
   clear); `move.w $dff00c,d0` → `chip.read(0x00c)`. Blits: write the same registers in the same order, BLTSIZE
   last. Blitter busy-waits (`btst #14,$dff002`) are dropped; the blit's time is charged by the cost model.
4. **Never busy-wait.** A loop waiting for a flag set by the vertical-blank interrupt → `m.waitVBlank()`. Raster
   waits (`cmp.b #$xx,$dff006` loops) → `m.waitLine(v)`. The host can't advance while the game thread spins.
   `dbra` delay loops → drop them, or `m.waitFrames(n)` if they are long enough to be visible.
5. **Interrupts.** Translated handlers go in `chip.interruptHandlers[level]` where the original writes the vector
   (`$64..$78`) and acknowledge INTREQ like the original. `move #$2700,sr` → `chip.ipl = 7`; `move #$2000,sr` →
   `chip.ipl = 0; chip.checkInterrupts()`.
6. **Code pointers stored as data** (jump tables, "current state" routine pointers, object behaviour pointers): keep
   the original address values in RAM and dispatch with `call(addr)`; each module registers the addresses it owns
   in its `dispatch` switch. Never invent new pointer values.
7. **Non-local exits** (`addq.l #4,sp; rts`, `move.l saved,sp`, jumping out of subroutines): restructure with
   return values or Swift `throws` (a module-local Error), with a comment.
8. **Disk loads**: `disk.loadTracks(first:count:to:memory:)`; no drive noise or delay. The hiscore save to disk →
   `Platoon.saveHiscores()` (a host file in Application Support).
9. **Randomness**: translate the RNG exactly. Hardware samples (VHPOSR, CIA timers) stay `chip.read` /
   `ciaX.read`.
10. **Not translated:** the debug monitor, exception handlers and copy protection (log and `fatalError`).
11. **No enhancements inside translated logic** except at `// ENHANCEMENT <ID>` sites guarded by an option whose
    default is the original behaviour (see [Enhancements](#enhancements)).
12. **Non-returning jumps** (k_next_section, k_game_over, k_init, section entry, the DEL warm restart) use
    `m.jump { ... }` (`-> Never`): the program continues on a fresh game thread and the old stack is discarded. From
    an interrupt handler on the host thread use `m.requestJump { ... }`.

## Timing and CPU cost
Several section loops are CPU- or blitter-bound on the A500 (the jungle takes 2-3 frames per tick with no explicit
pacing). Their routines charge their Musashi cycle cost with `cpu(n)` (the cost model in `KernelSupport.swift`), and
the model pays it as raster lines before the next wait. Keep new costs in Musashi cycles.

There are two timings:
- **Real A500 (default):** a raster line holds `cpuLine` = 426 Musashi cycles instead of 454, and every blit
  charges its DMA cycles × `a500BlitCost` (`Chipset.onBlitCycles`). Calibrated tick-locked against vAmiga:
  jungle about 18 ticks per second, final jungle about 25. Paula: one audio DMA word per line, the 4.4 kHz output
  filter and the LED filter. Evidence: [verify/timing.md](verify/timing.md).
- **Reference emulator (`--enh referenceEmulator=1`):** the CPU gets every bus cycle and blits take no time (jungle
  25 ticks per second, final jungle 50), with the emulator's Paula. All lockstep work against `tools/amiga/emu`
  and the regression gate use it. `platoon-headless` defaults to it; the app defaults to the real A500.

Changes to the cost model or the Paula model also need `tools/vamiga/build.sh && python3
tools/vamiga/timing_check.py --bin <platoon-headless>` (~5 min; port vs vAmiga within 1-2 %) and
`port/verify/audio/wavcmp.sh`.

## Verification tools
- **Screenshots:** `platoon-headless --frames N --script S --out DIR --shot-every K` writes PNGs framed exactly like
  `tools/amiga/emu` screenshots (same script format), so the same input script can be compared pixel by pixel.
- **RAM hash lockstep:** both tools accept `--hash HEXLO HEXLEN` and print a per-frame FNV-1a hash of a RAM region.
  Diff the outputs to find the first diverging frame, then `dumpr` both sides there.
- **Deterministic RNG:** `--deterministic` (both tools) removes both per-vblank RNG terms (`add.l d1,$12d70` and
  `addi.l #1,$12d70`; emu NOPs $10ede-$10eed) and seeds `$12d70 := $31415926` when section code starts (emu: when
  PC hits $17000; port: at the start of `sectionN_start()`). The RNG then depends only on call order.
- **Tick dumps:** `--tickdump HEXPC HEXLO HEXLEN FILE` (both tools) appends `[u32 frame][LEN bytes]` each time the
  original PC executes (emu) or translated code calls `tickPoint(PC)` (port). Put `tickPoint(0x....)` at the head
  of every main loop with the ORIGINAL address. Compare with `tools/tickcmp.py A B HEXLEN --base HEXLO`: ticks are
  aligned by index, so frame pacing differences don't matter.
- **Per-tick input:** `--tickinput HEXPC FILE` (`TICKIN` for `tools/vamiga/drv`) applies inputs at the N-th
  `tickPoint(PC)`, so machines running at different speeds play the same game.
- `--start-section N` skips the title and starts a new game in load section N; `--chipdump FILE` renders an
  emulator `chipdump` snapshot (display test).

Evidence and harnesses per module: [verify/README.md](verify/README.md).

## Regression gate
`tools/regress_all.sh` checks the rule "all options at their defaults = the verified game, byte for byte". It must
print **ALL PASS** after any change under `PlatoonCore`.
```sh
tools/regress_all.sh [--bin PATH/platoon-headless] > /tmp/regress.log 2>&1   # background; without --bin it builds the tree
tools/regress_all.sh --only 's0_|k_hs'     # regex subset;  --skip REGEX;  --list;  --jobs N;  --no-emu;  --out DIR
```
- **62 scenarios:** kernel, boot, title, hiscores, DEL and continue (`k_*`, scripts in `tools/regress/kernel/`),
  section 0 (`s0_*`, `port/verify/section0/harness/sc`), section 1 (`s1_*`, `port/verify/section1/scripts`), section
  2 (`s2_*`, `port/verify/section2/*.txt`), with the harnesses' tick-dump PCs and RAM regions.
- Each scenario runs with `--deterministic` and `PLATOON_ENH=originalCredits=0,referenceEmulator=1` (a few `k_*`
  scenarios vary this, e.g. with `PLATOON_HISCORES` / `PLATOON_CARRY`) in the **baseline** port built from the pinned
  commit `716172f` (`git archive`, cached in `/tmp/regress-cache`; keep that commit reachable), in the binary under
  test and, for all but three `k_*` scenarios, in `tools/amiga/emu`.
- **PASS** = byte-identical to the baseline: every tick dump (RAM + frame numbers), the FNV hash of all 512 KB of RAM
  after every frame, every screenshot and every dumped file. **FAIL** prints the first difference plus the lockstep
  numbers against the emulator. The emulator line after each verdict is information only; the translation's known
  residuals (frame pacing, dissolves) are listed in `port/verify/*.md`.
- ~10 min cold, ~3-5 min warm. Exit code 0 = all pass, 1 = a failure, 2 = a build failed or no binary. A
  deliberate change of default behaviour fails the gate by design and needs a new `BASE` commit in the script.

## Enhancements
Every enhancement is optional and off by default; purely presentational fixes are the only exceptions. The user
guide is [ENHANCEMENTS_GUIDE.md](ENHANCEMENTS_GUIDE.md).

**Rules**
- Changes inside translated logic only at `// ENHANCEMENT <ID>` sites, behind an option declared in
  `Game/Enhance/<Group>Options.swift`. With the option off the code path is byte-identical (the gate checks it).
- Options that change the game are declared `gameplay: true`; a run using one is *assisted* and ranks in a separate
  high-score table (`Game/Enhance/Hiscores.swift`). Host features that help beyond the original mark the run with
  `markAssisted` when they act.
- Host features read RAM in `Machine.frameHook` (the game thread is parked there) and never write it unless they
  are a gameplay option.

**Foundations** (`Game/Enhance/`)
- **Registry** (`Registry.swift`): `Enhancements` = root options + typed groups `kernel`, `game`, `section0..2`,
  `audio`, `assist`, `cheat` (one file per group). String access `set(key, value)`, `apply("k=v,...")`, `catalog`,
  `changed`, `assistReasons`; used by `PLATOON_ENH`, `platoon-headless --enh k=v` (`--enh list`) and the app's
  Preferences. Hooks read `enhancements.<group>.<field>`.
- **Difficulty** (`Difficulty.swift`): `difficulty=original|recruit|veteran|custom`; knobs are Optionals in each
  group's `<Group>Difficulty` (nil = the original literal), resolved at game start.
- **Context and events** (`GameContext.swift`, `GameProbe.swift`, `ProbeHooks.swift`): put a `GameProbe` in
  `GameConfig.probe`; its `context` (screen, area, section, men, items, section RAM views) is refreshed and its
  observers (`onMessage`, `onFx`, `onScore`, `onDeath`, `onManSelect`, `onSectionStart/End`, `onGameOver`,
  `onHiscore`, `addObserver`) run in `Machine.frameHook`. `probe.markAssisted(reason)` /
  `PlatoonGame.markAssisted(machine, reason)` mark the current run. Debug log: `PLATOON_EVENTS=file`.
- **High-score tables** (`Hiscores.swift`): assisted runs rank in `hiscores-<recruit|veteran|custom|assisted>.bin`
  next to `GameConfig.hiscoreURL`; the original table is never written by them.
- **Cheats** (`CheatOptions.swift`, group `cheat`, helpers `Game/Cheats.swift`): the host may switch them live with
  `PlatoonGame.setCheats` from `frameHook`; they mark the run per game, not per session.

**Enhancement IDs.** The IDs used in `// ENHANCEMENT <ID>` comments, option declarations (`id:`) and file comments:

| ID | Feature | ID | Feature |
|---|---|---|---|
| F1 | context probe (`GameContext`) | M1 | pause menu |
| F2 | game-event observers | M2 | objectives, briefings, numeric HUD |
| F3 | app overlay layer | M3 | tunnel automap (`s1.exploredMap` = variant B) |
| F4 | assisted-run marking | M4 | tunnel fairness: keep items, flare-night retry, checkpoint respawn |
| F5 | loop-head snapshot / restore | M5 | final-jungle navigator, compass assist |
| S1 | display framing (crop DIW $71..$1B1 × lines $2C..$12B, 320×256) | M6 | jungle and village map |
| S2 | controller buttons and hints | M7 | Controls & Bindings window |
| S3 | keyboard layout fixes, Send Amiga Key | M8 | automatic checkpoints |
| S4 | auto-pause, resume-press swallowing | M9 | rewind |
| S5 | high-score tables for assisted runs | M10 | difficulty presets and knobs |
| S6 | bridge failsafe | M11 | practice drills |
| S7 | forgiving booby traps | M12 | ghost voices |
| S8 | message log, captions, speech | M13 | toggles, auto-fire |
| S9 | original bug fixes (a-k, see below) | M14 | separate jump and crouch |
| S10 | music / effects volume, voice panning | M15 | extra soldiers, full platoon |
| S11 | hold-to-fast-forward | M16 | speedrun timer, service record |
| S12 | F10 mode at start-up | M17 | input replays |
| S13 | screen shake, rumble, sniper cue | M18 | Preferences window |
| S14 | ambient glow side bars | M19 | MMPX pixel-art upscaler |
| S15 | tap stretching | M20 | CRT looks |
| S16 | night brightening | M21 | colour vision, HUD magnifier |
| S17 | reduced flashing, steady pause colour | M22 | audio rate control, latency, game speed |
| S18 | keyboard high-score name | M23 | disk import and health check |
| L1 | quick save / slots | M24 | video and GIF recording |
| L2 | pointer and right-stick aiming | M25 | room / turn slides, BLEP, ambience, soundtrack, faster keys |
| L3 | village and tunnel randomisers | L4 | widescreen jungle |

S9 fixes: (a) final-jungle room timer, (b) morale wrap, (c) last bullet, (d) flare-night spawns, (e) rotten food
score, (f) hut-1 dummy, (g) tripwire spawn, (h) withdrawn text and timer stop at 00:00, (j) phantom grenades,
(k) trap-door bonus. `CHEAT-*` sites belong to the cheats.

## Feature areas
Build with your own scratch path (`swift build -c release --scratch-path /tmp/pbuild-<name>`) and run long tests in
the background.

### App
- Settings: `Prefs/Prefs<Owner>.swift` (declarative `PrefSection`s). Menus and launch hooks:
  `Menus/Menu<Owner>.swift`. Services: `AppServices.shared` (`onFrame`, `onDisplay`, `onReset`, `onSectionStart`,
  `onPauseChange`, `onHostReady`, `onNewGame`, `probe`, `pause/resume`, `toast`, `addPauseMenuItem`,
  `keyHooks`/`padHooks`, `snapshots`, `markAssisted` / `markAssistedOnce` (per game; call it every frame while an
  assist acts)).
- Overlays: `AppServices.shared.overlay.add(OverlayPanel)`. They never show in ⌘S screenshots or the Metal picture.
  Panels are laid out in zIndex order and move clear of panels already placed (`avoidsOverlap`, default on).
  Pause-menu entries: `PauseMenuItem(... isEnabled:, isShown:, action:)`; hide entries that don't apply with
  `isShown`. Menu toggles generated from prefs (`.inMenu(...)`) get title-case names next to their related group.
- `Platoon --list-prefs` prints the registry and checks that the current settings reach the core.
- App test driver: `PLATOON_DEBUG_SCRIPT=script PLATOON_DEBUG_CAPTURE=outdir [PLATOON_DEBUG_FRESH_PREFS=1]
  [PLATOON_ADF=disk] [PLATOON_PREFS=k=v,…]`; the commands are listed in `DebugScript.swift`.
  `PLATOON_SUPPORT_DIR` redirects the disk, high scores, assist files and the soundtrack folder (save states:
  `PLATOON_SAVES_DIR`); copy the binary under another name so its UserDefaults domain is private.
- App bundle: `build_app.sh` (`SCRATCH=/tmp/dir`, `OUT=dir`, `DIST=1` without the game disk, `ARCHS="arm64"`,
  `CONFIG=debug`). The bundle registers `.adf` files and contains the README and the enhancements guide for the
  Help menu.

### Save states
Snapshots are taken only at the four section main-loop heads (`tickPoint` $17186 jungle, $171c6 tunnels, $18bd8
flare night, $17118 final jungle), where the whole game state is in chip RAM, the chipset (copper, CIA timers, TOD
and alarm, Paula) and a few host variables. A restored game continues from that point on a fresh game thread.
`port/verify/snapshot/roundtrip.sh` checks that a restored game plays on byte-identically (RAM hash every frame,
tick dumps, screenshots, audio) in all four loops, including rewind, checkpoint retry and files saved in one process
and loaded in another. Headless options: `--snapshot-save N FILE`, `--snapshot-load FILE`, `--roundtrip N[,N..]`,
`--roundtrip-every K`, `--roundtrip-inplace`, `--rewind-ring`, `--rewind-at N BACK`, `--checkpoints`,
`--retry-at N[,N..]`. Unit tests: `SnapshotCodecTests`.

### Controls
- Code: `PlatoonApp/InputManager.swift` (binding resolution, reference-counted Amiga keys, controllers, context
  buttons, frame tick), `PlatoonApp/Input/` (Bindings, KeyLayout, InputPipeline = S15/M13, AimAssist = L2, Rumble =
  S13, ControlsWindow = M7, InputFeature, InputSelfTest), `Prefs/PrefsInput.swift`, `Menus/MenuInput.swift`. No
  PlatoonCore code; M14 uses `Section0HostButtons`, L2 uses `TunnelAim`.
- With every option off the joystick is written at event time exactly as before; with S15/M13/L2 on it is written
  once per emulated frame from `Machine.frameHook`.
- Test: `port/verify/input/run.sh [Platoon binary] [outdir]` (~3 min; `PLATOON_INPUT_ONLY=...` runs a subset).
  `PLATOON_KEYLAYOUT=qwertz|azerty` simulates a layout in the app.

### Picture
- `PlatoonApp/MetalRenderer.swift` (passes, layout, `renderOffscreen`), `Video/VideoShaders.swift` (all Metal
  code), `Video/VideoLook.swift` (settings), `Video/VideoFX.swift` (per-frame effect state from the probe: shake,
  night lift, flash limiter, HUD split), `Video/VideoRecorder.swift` + `GIFWriter.swift`, `Video/SniperCue.swift`,
  `Video/SideColumns.swift` (`SideColumnCompositor` for the widescreen jungle).
- The flash limiter reads the copper list's top palette ($115fa) and `$5a(a6)` at the frame hook; while a flash is
  limited, the renderer maps each pixel by its palette index from the last canvas before the flash.
- Test: `port/verify/presentation/selftest.sh <Platoon> <platoon-headless> [outdir]` (~8 min). In the app:
  `PLATOON_VIDEO_TEST=dir`, `PLATOON_VIDEO_SCRIPT=file`, `PLATOON_VIDEO_LOG=file`, `PLATOON_RECORD_DIR`,
  `PLATOON_SCREENSHOT_DIR`.

### Sound
- `Platform/Paula.swift`: `runLineLegacy` is the original renderer, used whenever every mixer setting is at its
  default; `runLineMixer` steps the DMA state machine identically and only computes the output differently.
  Building blocks in `Platform/PaulaMixer.swift` (BLEP, reverb).
- Music driver hooks (`Game/Audio/MusicDriver.swift`, `// ENHANCEMENT M12/M25`): ghost writes via
  `Paula.ghostWrite` (never `chip.write`); `Game/Audio/AudioEnhance.swift` installs the voice tagger and applies
  `enhancements.audio` once per run.
- Output: `Platform/HostAudioStream.swift` (ring and rate control); app side `AudioOutput.swift`,
  `AudioEnhancements.swift`. A host running the game slower than real time sets
  `host.audio.stream.speedHint = speed` (nil at 100 %).
- Tests: `port/verify/audio/wavcmp.sh BIN OUT` (output with `referenceEmulator=1` byte-identical to the baseline, 9
  scenarios), `port/verify/audio/enhtests.sh BIN OUT`, `swift test --filter AudioTests`,
  `port/verify/audio/app/apptest.sh PLATOON_BIN OUT`. `PLATOON_DEBUG_AUDIO_WAV=file.wav` records the app's final
  mix. Driver harness: `platoon-headless --music-test N` / `--sfx-test ID` (reads `PLATOON_ENH`).

### Assists
- Models (PlatoonCore, headless-testable): `Game/Assist/MessageLog.swift`, `Objectives.swift`, `RunTracker.swift`,
  `InputReplay.swift`, `PracticeDrills.swift` (+ `PracticeScripts.swift`, generated from `port/verify` scripts). App:
  `PlatoonApp/Assist/`. Unit tests: `swift test --filter AssistTests`.
- App driver: `PLATOON_DEBUG_ASSIST=file` (commands in `Assist/AssistDebug.swift`); scripted runs in
  `port/verify/assist/`; `PLATOON_ASSIST_SILENT=1` mutes speech.
- A `.plreplay` file is a `platoon-headless --script`; its header holds the command line that replays it.

### Jungle and village
- Hooks in `Game/Section0/*.swift`; helpers in `Section0Enhance.swift` (M14 `Section0HostButtons`, S6 failsafe, S9b
  clamp, L3 shuffle with a host PRNG so the game's random numbers are untouched).
- Read-only models: `JungleMapModel` / `JunglePlayer` (M6), `JungleWideLatch` + `JungleWidescreen.render` (L4).
- Tests: `port/verify/section0/enh/features.py <platoon-headless> [outdir] [--only REGEX]`,
  `PLATOON_S0_WIDETEST=dir[,every]`, `Tests/PlatoonCoreTests/Section0OptionsTests.swift`.

### Tunnels and flare night
- Hooks in `Game/Section1/*.swift`; helpers in `Section1Enhance.swift` (state in a RAM scratch block at $3f000, so
  save states capture it), `TunnelAim.swift` (L2 API) and the public `TunnelMaze` helpers used by the overlay.
- Tests: `port/verify/enh-section1/s1test.py <platoon-headless> [outdir] [--only REGEX]`,
  `port/verify/enh-section1/roundtrip.sh`, `Tests/PlatoonCoreTests/Section1EnhanceTests.swift`,
  `port/verify/enh-section1/runapp.sh <Platoon binary>`.

### Final jungle and bunker
- Hooks in `Game/Section2/FinalJungle.swift` and `Foxhole.swift`; helpers in `Section2Enhance.swift`.
- Read-only model `Game/Section2/FinalNavigator.swift`: `FinalJungleMaze` (map from RAM, BFS `route(from:)`),
  `FinalJungleLive.read(memory)` and `FinalJungleRenderer` (the game's picture decoder). App overlays:
  `Overlay/FinalNavigator.swift`, `FinalRoomSlide.swift`.
- Tests: `swift test --filter FinalJungleTests`, `port/verify/section2/enh/run_enh.py [--bin platoon-headless]`,
  `port/verify/section2/enh/app/run_app.sh APP HEADLESS [OUT]`.

### Cheats
- `Game/Enhance/CheatOptions.swift` (every option `gameplay: true`; its header lists the `// ENHANCEMENT CHEAT-*`
  sites), helpers in `Game/Cheats.swift`. The app's `GameHost.syncCheats` applies Preferences ▸ Cheats every frame
  (except during a replay). The legacy host `Trainer` only runs for old replays and
  `platoon-headless --trainer ammo,morale,invulnerable`.
- Tests: `port/verify/cheats/run_cheats.py [--bin platoon-headless] [--only REGEX]`, `swift test --filter CheatTests`.

### Robustness
`port/verify/qa/kitchen.py <platoon-headless> <outdir> [all|veteran|custom|cheats]` runs every gate scenario with many
options on at once and reports crashes or hangs; `port/verify/qa/xsection_travel.sh` (env `BIN`) checks rewinds and
checkpoint retries across the tunnels → final-jungle change. Core feature tests:
`tools/regress/core_features.sh <platoon-headless>`.

## Command line and environment
**platoon-headless** (run `platoon-headless` with a bad flag for the full usage text):
```
platoon-headless [--adf FILE] [--frames N] [--script FILE] [--out DIR] [--shot-every N] [--wav FILE]
                 [--hash HEXLO HEXLEN] [--chipdump FILE] [--start-section N] [--deterministic]
                 [--tickdump HEXPC HEXLO HEXLEN FILE] [--tickinput HEXPC FILE] [--enh K=V[,K=V]] [--enh list]
                 [--music-test SONG] [--sfx-test ID] [--audio-test] [--reglog FILE] [--wav-rate HZ] [--no-filter]
                 [save-state options, see Save states]
```
Script lines (same as `tools/amiga/emu`): `FRAME up|down|left|right|fire 0|1`, `FRAME key CODE 0|1`,
`FRAME shot NAME`, `FRAME dump FILE`, `FRAME dumpr HEXADDR HEXLEN FILE`, `FRAME poke HEXADDR HEXVAL SIZE`,
`FRAME quit`. The default disk is `../re/platoon_port.adf` (run it from `port/`).

**Platoon** (the app binary): `--check-disk A.adf [B.adf …] [--repair OUT.adf]` (exit 0 = verified, 1 = playable
with problems, 2 = unusable), `--list-prefs`.

**Options:** `PLATOON_ENH="key=value,..."` (app and headless) or `--enh`. Values: `1`/`0` (also on/off,
true/false), decimal or hex (`0x4800`, `$4800`), `original` = the game's own value. `--enh list` prints every option
with its default and help text and marks gameplay options.

**Other environment variables:** `PLATOON_ADF` (the app's disk image; the headless runner uses `--adf`),
`PLATOON_EVENTS=file` (every game event and screen
change), `PLATOON_CARRY=file` (start with a carried platoon), `PLATOON_HISCORES`, `PLATOON_SUPPORT_DIR`,
`PLATOON_SAVES_DIR`, `PLATOON_PREFS`, and the test drivers listed under [Feature areas](#feature-areas).
