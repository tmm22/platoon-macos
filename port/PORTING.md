# Platoon macOS port — translation guide

The port is a **source port**: the original 68000 game logic is translated routine by routine into
readable Swift, running on a small virtual Amiga chipset written in Swift (`Sources/PlatoonCore/Platform`).
All game data (graphics, maps, tables, text, music, samples) is read from the original disk image at
runtime and lives at its original address in a 512 KB `Memory` image, so translated code can use the
original addresses and table layouts unchanged.

Reverse-engineering specs for every module are in `re/<module>/NOTES.md` with annotated listings
`re/<module>/<module>.s`. The reference emulator `tools/amiga/emu` runs the original game and is the
ground truth for verification.

## Layout
```
Sources/PlatoonCore/Platform/   virtual hardware (do not put game logic here)
  Memory.swift    r8/r16/r32 (unsigned), s8/s16/s32 (signed), w8/w16/w32 — big-endian, address & $7FFFF
  Chipset.swift   custom registers: chip.write(reg, v) / chip.writeL(reg, v) / chip.read(reg) / chip.readL(reg)
                  copper, sprites, display (renders canvas line by line), interrupts
  Blitter.swift   exact blitter; a write to BLTSIZE ($058) performs the blit immediately
  CIA.swift       chip.ciaA / chip.ciaB: read(r)/write(r, v) with r = register nibble (address >> 8 & 15)
  Paula.swift     audio DMA channels (driven by writes to $0A0-$0DF and DMACON)
  Disk.swift      disk.loadTracks(first:count:to:memory:) == the resident loader at $d1a
  Machine.swift   frame driver + game thread: waitVBlank(), waitFrames(n), waitLine(v)
  Input.swift     joystick/fire/keyboard state (feeds JOY1DAT, CIA-A PRA, keyboard SDR interrupt)
Sources/PlatoonCore/Game/
  Game.swift            PlatoonGame.main(m) — entry point (boot, then resident init at $566)
  Platoon.swift         `final class Platoon` — shared context (m, mem, chip, disk, input) + dispatch helpers
  Resident.swift        $400-$2534
  Kernel*.swift         $f800-$12dde (+ title code in $2538-$f7ff)
  Audio/MusicDriver.swift  David Whittaker driver ($2800-$3ff8)
  Section0/Jungle.swift, Village.swift ; Section1/Tunnels.swift, Flare.swift ; Section2/FinalJungle.swift, Foxhole.swift
```
Every module is an `extension Platoon { ... }` so all routines can call each other directly.

## Translation rules
1. **Keep state in RAM.** Variables, object tables, copper lists, bitplanes stay at their original addresses
   (`a6 = $12dde` globals etc.). Define named constants for addresses (`let vFrameFlag: UInt32 = 0x12dde + 0x56`)
   and small computed accessors where it helps readability. Do not mirror RAM state in Swift properties unless it
   is purely host-side (settings, enhancement flags).
2. **One Swift function per original routine**, named descriptively, with a doc comment giving the original
   address range, e.g. `/// $10ad6 wait for vertical blank`. Registers become parameters/locals/return values.
   Keep the exact arithmetic: use `&+ &- &*` and explicit `UInt16(truncatingIfNeeded:)`/`Int16(bitPattern:)`
   where the 68k wraps or sign-extends; byte/word/long sizes matter. `ext.w`, `asr` vs `lsr`, `mulu` vs `muls`,
   `divu` (quotient low word, remainder high word) must be reproduced. Condition-code-dependent control flow
   (e.g. a `bcc` after `add`, `dbra` counts, `tst` then `bmi`) must be translated precisely.
3. **Hardware access** maps 1:1: `move.w #x,$dff096` → `chip.write(0x096, x)`; `move.l a0,$dff080` →
   `chip.writeL(0x080, a0)`; `btst #7,$bfe001` → `chip.ciaA.read(0) & 0x80 == 0` (fire pressed when bit clear);
   `move.w $dff00c,d0` → `chip.read(0x00c)`. Blits: write the same registers in the same order, BLTSIZE last.
   `btst #14,$dff002` busy-waits for the blitter are no-ops (blits are instant).
4. **Waiting.** A loop waiting for a flag set by the vertical-blank interrupt → `m.waitVBlank()` (it resumes after
   the level-3 handler ran for the new frame). Raster waits (`cmp.b #$xx,$dff006` loops) → `m.waitLine(v)`.
   Never busy-loop on RAM or hardware in Swift — the host cannot advance while the game thread spins.
   Timing loops (`dbra` delay loops) → drop, or `m.waitFrames(n)` if they are long enough to be visible.
5. **Interrupts.** Translated handlers are installed in `chip.interruptHandlers[level]` where the original writes
   the vector (`$64..$78`). Handlers must acknowledge INTREQ like the original. `move #$2700,sr` →
   `chip.ipl = 7`; `move #$2000,sr` → `chip.ipl = 0; chip.checkInterrupts()`.
6. **Code pointers stored as data** (jump tables in RAM, "current state" routine pointers, object behaviour
   pointers): keep the original address values in RAM and dispatch with `call(addr)` — each module registers the
   addresses it owns in its `dispatch` switch. Never invent new pointer values.
7. **Non-local exits** (stack games like `addq.l #4,sp; rts`, `move.l saved,sp`, jumping out of subroutines):
   restructure with return values or Swift `throws` (define a module-local Error) — document it in a comment.
8. **Disk loads**: `disk.loadTracks(first:count:to:memory:)`; the "LOADING..." screens can be kept but no drive
   noise/delay is needed. Hiscore save to disk → `Platoon.saveHiscores()` (host file in Application Support).
9. **Randomness**: translate the RNG exactly. If it samples hardware (VHPOSR, CIA timers), keep that read via
   `chip.read`/`ciaX.read` — the value differs from the emulator but the distribution is the same.
10. **Debug monitor / exception handlers / copy protection** are not translated (log and fatalError instead).
11. **No enhancements inside translated logic** except through explicit hooks (`enhancements.xxx` flags checked at
    clearly marked places, default = original behaviour).

## Verification
- `swift build -c release` then `.build/release/platoon-headless --frames N --script S --out DIR --shot-every K`
  produces PNGs framed exactly like `tools/amiga/emu` screenshots (same script format), so compare
  `emu` vs `platoon-headless` output for the same input script (python3 + PIL, `ImageChops.difference`).
- Lockstep: both tools accept `--hash HEXLO HEXLEN` and print a per-frame FNV-1a hash of a RAM region; diff the two
  outputs to find the first diverging frame, then `dumpr` both sides at that frame and compare bytes.
  Expect small timing offsets around loads/boot; compare from a synchronised point (e.g. section start).
- `platoon-headless --chipdump FILE` renders an emulator `chipdump` snapshot (display regression test).

## Non-returning jumps
`jmp` to routines that never return (k_next_section, k_game_over, k_init, section entry, DEL warm restart) use
`m.jump { ... }` (`-> Never`): the program continues on a fresh game thread and the old stack is discarded.
From an interrupt handler running on the host thread use `m.requestJump { ... }`.

## Lockstep tools
- `--deterministic` (emu and platoon-headless): removes BOTH per-vblank RNG terms (`add.l d1,$12d70` and
  `addi.l #1,$12d70`; emu NOPs $10ede-$10eed) and sets the seed `$12d70 := $31415926` when section code starts
  (emu: whenever PC hits $17000; port: at the start of `sectionN_start()` when `config.deterministicRNG`). The port's
  vblank handler must skip both terms in that mode. Then the RNG depends only on call order, so logic can be
  compared exactly regardless of frame pacing.
- `--tickdump HEXPC HEXLO HEXLEN FILE` (both tools): append `[u32 frame][LEN bytes at LO]` each time the original PC
  executes (emu) / translated code calls `tickPoint(PC)` (port). Put `tickPoint(0x....)` at the head of every main
  loop with the ORIGINAL address. Compare with `tools/tickcmp.py A B HEXLEN --base HEXLO` — ticks are aligned by index,
  so differences in frame pacing do not matter.
- `platoon-headless --start-section N` skips the title and starts a new game in load section N.
- Frame pacing: several section loops are CPU-bound on the A500 (e.g. the jungle takes ~2-3 frames per tick with no
  explicit pacing). Measure the emulator's typical frames-per-tick with --tickdump and reproduce it with explicit
  `m.waitFrames`/`k_wait_vbl` so game speed matches. Document the choice.

## Team rules (parallel translation)
- Each agent owns its files (listed in its task). Do not edit other agents' files. `KernelAPI.swift` and
  `Audio/MusicDriverAPI.swift` signatures are frozen (the kernel/audio owners may add, not change).
- Platform files: only minimal bug fixes, announced in `port/STATUS.md` (append a line).
- Build with your own scratch path to avoid lock contention: `swift build -c release --scratch-path /tmp/pbuild-<module>`.
  Keep the build green: never leave your files non-compiling for more than a few minutes. If the build breaks in a
  file you don't own, wait and retry; do not fix it.
- Do not run git commands that modify the repo (no commit/add/stash/checkout); the coordinator commits.
- Progress/handoff notes: append to `port/STATUS.md` ("[module] ..."), e.g. when a milestone works.
