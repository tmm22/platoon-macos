# CLAUDE.md

Native macOS source port of **Platoon** (Ocean, Amiga 1988). The original 68000 code was reverse-engineered and
translated routine by routine into Swift, running on a small virtual Amiga chipset. With all options at their
defaults the port is verified byte-identical, tick by tick, against the original running in a reference emulator.
Keep it that way.

## Layout
- `port/` — Swift package (macOS 14+, Swift 6 toolchain, tools-version 5.9)
  - `Sources/PlatoonCore/Platform/` — virtual chipset: Memory (512 KB chip RAM, big-endian), Chipset (custom regs,
    copper, display → 768x290 canvas), Blitter, CIA, Paula, Disk (ADF), Machine (frame driver + game-thread coroutine).
  - `Sources/PlatoonCore/Game/` — translated game: `Resident.swift`, `Kernel*.swift`, `Audio/` (Whittaker driver),
    `Section0/` (jungle+village), `Section1/` (tunnels+flare), `Section2/` (final jungle+foxhole), `Enhance/`
    (options registry, difficulty, context probe, events, hiscore modes), `Snapshot/` (save states), `Assist/`.
  - `Sources/PlatoonApp/` — AppKit + Metal + AVAudio + GameController app (menus, Prefs, Overlay, Input, Video, Assist).
  - `Sources/platoon-headless/` — verification runner (same script format as the emulator).
  - `Tests/PlatoonCoreTests/` — XCTest suites. `verify/` — per-module verification evidence and harnesses.
- `re/` — reverse-engineering specs (`re/<module>/NOTES.md` is the source of truth for original behaviour),
  annotated listings, extraction scripts; disk images (`re/platoon_port.adf` is the one to use).
- `tools/amiga/emu` — headless reference Amiga emulator (Musashi CPU), `tools/rdis.py` disassembler,
  `tools/tickcmp.py`, `tools/regress_all.sh` regression gate.

## Commands
```sh
make -C tools/amiga                                   # build the reference emulator
cd port && swift build -c release                     # build everything (use --scratch-path /tmp/pbuild-X for parallel work)
cd port && swift test                                 # unit tests
cd port && ./build_app.sh                             # universal build/Platoon.app (bundles re/platoon_port.adf; DIST=1 omits it)
port/.build/release/platoon-headless --start-section N --frames F --script S --out DIR --shot-every K
tools/regress_all.sh > /tmp/regress.log 2>&1          # default-settings lockstep gate (run in background, ~5-10 min)
```
`platoon-headless --enh list` prints every enhancement option; `--enh k=v,...` or `PLATOON_ENH` sets them.

## Rules
- **Faithfulness first.** Game logic lives in RAM at original addresses; translated routines keep the original
  arithmetic, order and timing. Read `port/PORTING.md` before touching `PlatoonCore/Game`.
- **Every enhancement is optional and off by default** (purely presentational fixes excepted). Changes inside
  translated logic only at `// ENHANCEMENT <ID>` sites guarded by an option. Gameplay-changing options must mark the
  run as assisted (separate hiscore table; see `Game/Enhance/Hiscores.swift`).
- **Gate:** after any change under `PlatoonCore`, `tools/regress_all.sh` must print ALL PASS (byte-identical to the
  pinned baseline commit `716172f`, which it builds from git history — keep that commit reachable).
- Never busy-wait in translated code: use `m.waitVBlank()`, `m.waitFrames(n)`, `m.waitLine(v)`; non-returning jumps
  use `m.jump { }` / `m.requestJump { }`. CPU-time pacing uses the cost model in `KernelSupport.swift`.
- The CPU-bound pacing, RNG (`--deterministic`) and tick-dump lockstep tooling are documented in `port/PORTING.md`.
- Long-running commands (emulator runs, regression, full builds) should run in the background.

## Docs
`README.md` (users), `port/ENHANCEMENTS_GUIDE.md` (all options), `port/ENHANCEMENT_IDEAS.md` (roadmap),
`port/PORTING.md` (developer guide), `port/STATUS.md` (history log), `re/NOTES.md` (disk layout, memory map).
