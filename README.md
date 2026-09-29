# Platoon — native macOS port

A source port of Ocean's **Platoon** (Amiga, 1988) to macOS. The original 68000 game code has been reverse-engineered
and translated routine by routine into Swift; it runs on a small virtual Amiga chipset (blitter, copper, display,
Paula audio) written in Swift, so gameplay, graphics, music and timing match the original, with modern presentation on top.

The game data (graphics, maps, music, samples) is read at runtime from the original Amiga disk image.

## Build & run
Requirements: macOS 14+, Xcode 16+ command-line tools.
```sh
cd port
./build_app.sh            # universal (arm64 + x86_64) build/Platoon.app, bundles re/platoon_port.adf
open build/Platoon.app
```
`re/platoon_port.adf` is built from the disk images in `original/` (Darc crack with tracks 77 and 127 from the
original dump, which the Darc image has blank/corrupt). If the bundled disk is missing, the app asks for an `.adf`.

## Controls
| | |
|---|---|
| Joystick | arrow keys, or a game controller's d-pad / left stick |
| Fire | Space or Z (controller A / B / right trigger) |
| Pause (in-game) | TAB (controller Menu) |
| Music / sound FX | F10 (controller Options) |
| Abort to title | DEL |
| Name entry | joystick left/right + fire |

Mac shortcuts: ⌘P pause emulation · ⌘T turbo · ⌘R reset · ⌘S screenshot (Desktop) · ⌘1/⌘2/⌘3 sharp / smooth / CRT ·
⌃⌘F full screen · ⌘/ controls.

## Enhancements
- Metal renderer: sharp-pixel scaling (no shimmer at any size), smooth, or CRT (scanlines, slot mask, curvature),
  PAL aspect correction, optional integer scaling and overscan, full screen, Retina.
- Audio: low-latency output, optional A500 low-pass filter, sample interpolation, adjustable stereo separation, volume.
- Game controller support (GameController framework), turbo mode, pause, screenshots.
- High scores are saved (Application Support/Platoon/hiscores.bin) instead of the crack's disabled disk save.
- The original credits text is restored in place of the crack's credit line.
- Instant loading.

## Repository layout
- `original/` — the supplied disk images.
- `re/` — reverse-engineering: per-module specs (`re/<module>/NOTES.md`), annotated listings, extraction scripts.
- `tools/amiga/emu` — headless reference Amiga emulator used to verify the port (`make -C tools/amiga`).
- `port/` — the Swift package: `PlatoonCore` (platform + translated game), `PlatoonApp` (macOS app),
  `platoon-headless` (verification runner). See `port/PORTING.md`.
