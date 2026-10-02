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
DIST=1 ./build_app.sh     # distribution build without the game disk (players import their own .adf)
```
### You need your own copy of the game
This repository contains **no game data**: no disk images, graphics, music or samples. Platoon is © 1987/1988
Ocean Software / Hemdale Film Corporation. To play or run the tests you need the Amiga disk image(s) of Platoon.

The port knows these TOSEC dumps: `Platoon (1988)(Ocean)[cr 68 Darc]`, `[b]`, `[cr VF - Beyonders]` and
`[cr VF - Beyonders][t +5 LFC]`. None is perfect on its own: the Darc image has a blank hiscore track (77) and a
corrupt track 127, and the Beyonders images are corrupt in the last section. Combine two dumps into the verified image:
```sh
cd port && swift build -c release --product Platoon
.build/release/Platoon --check-disk "Platoon (1988)(Ocean)[cr 68 Darc].adf" "Platoon (1988)(Ocean)[b].adf" \
    --repair ../re/platoon_port.adf
```
`re/platoon_port.adf` is what the build script bundles, the headless runner, the tests and the regression gate use.
The app icon is generated from that disk's loading picture at build time (`tools/make_icon.py`).
Without a bundled disk the app asks for one: Game ▸ **Import Disk Image…** (⌘O), or drop `.adf` files on the window
or the Dock icon. Several dumps can be combined; each is identified from per-track fingerprints and damaged tracks
are repaired from the others.

## Controls
| | |
|---|---|
| Joystick | arrow keys, or a game controller's d-pad / left stick |
| Fire | Space or Z (controller A / B / right trigger / right shoulder) |
| Amiga SPACE (jungle grenade, flare) | Space (controller X) |
| Change soldier (jungle) | Left Option = Amiga Left-Alt (controller Y) |
| Answer prompts (trap door) | Y / N (controller LB / LT, or A = yes, B = no at the prompt) |
| Pause (in-game) | TAB (controller Menu) |
| Music / sound FX | F10 (controller Options) |
| Abort to title | DEL |
| Name entry | joystick left/right + fire (optionally type it on the keyboard) |
| HELP / keypad − on laptops | F11 / F12, or Game ▸ Send Amiga Key |

Host keys (the game never reads them): **Esc** pause menu · hold **`** (or L3) fast-forward · hold **Backspace**
(or R3, ⌘Z) rewind, when rewind is on · **M** jungle / tunnel map and **N** final-jungle navigator, when those are on.

Mac shortcuts: ⌘, Preferences · ⌘/ Controls & Bindings · ⌘P pause emulation · ⌘T turbo · ⌘R reset · ⌘K continue ·
⇧⌘S / ⇧⌘L quick save / load · ⇧⌘R retry from checkpoint · ⌘S screenshot · ⌥⌘R record video · ⌥⌘L message log ·
⌘1/⌘2/⌘3/⌘4 sharp / smooth / CRT / pixel-art upscaler · ⌃⌘F full screen · ⌘O import disk. Every key and controller
button can be rebound in Controls & Bindings.

## Enhancements
**All optional.** With every setting at its default you play the original 1988 game at real-A500 speed: the
translated code runs byte-identically to the verified port (`tools/regress_all.sh`, 62 lockstep scenarios). Options that change the game
are marked *gameplay*; a game played with any of them (or with a cheat, a loaded save, rewind, practice, a
section start…) is *assisted* and its score goes to a separate high-score table, never the original one.
The full user guide is [port/ENHANCEMENTS_GUIDE.md](port/ENHANCEMENTS_GUIDE.md) (also in the app's Help menu).

- **Playing comfort:** pause menu (Esc / controller), auto-pause on focus loss, sleep or controller disconnect,
  hold-to-fast-forward, slow motion (game speed 60-100 %), quick save / 5 save slots, automatic checkpoints with
  *Retry from Checkpoint*, rewind, *Continue from Last Section* and *Start New Game At* any disk section.
- **Help for a cryptic game:** message log of every HUD clue (including the ones the game drops), large captions and
  text-to-speech, objectives with three detail levels, section briefings, a numeric HUD, a jungle & village map, a
  tunnel automap with fog of war, a final-jungle navigator (heading, visited rooms, route guide), a booby-trap warning.
- **Difficulty and rules (gameplay):** Recruit / Veteran / Custom presets with per-section knobs, up to five soldiers
  or the full platoon carried over, bridge failsafe, forgiving booby traps, keep items / flare-night retry /
  checkpoint respawn in the tunnels, separate jump and crouch, village and tunnel randomisers, and a fix for each
  original bug (morale wrap, last bullet, room timer, phantom grenades, …).
- **Practice, replays, records:** practice drills for seven key moments, input replays (last / best game kept
  automatically, also playable by the headless runner), speedrun timer with splits and LiveSplit export, a local
  Service Record with medals.
- **Controls and accessibility:** Controls & Bindings window with presets (incl. one-handed), full controller
  support with context buttons and hints, keyboard layouts (QWERTZ / AZERTY), tap stretching, toggle fire /
  directions, auto-fire, mouse / right-stick aiming, controller rumble, colour-vision modes, HUD magnifier, reduced
  flashing, night-scene brightening, typing the high-score name.
- **Picture:** sharp pixels (pixel-exact), smooth, CRT with presets (1084S, PVM, A520 composite, custom), MMPX
  pixel-art upscaler, PAL aspect, integer scaling, overscan, ambient glow side bars, widescreen jungle, screen shake,
  sniper cue, tunnel turn and final-jungle room slides, video / GIF recording and screenshots.
- **Sound:** separate music and effects volume, per-voice panning, *ghost voices* (the music keeps all four parts
  during gunfire), band-limited synthesis, per-area ambience, your own replacement soundtrack, smooth output timing
  with a latency setting, A500 filter, interpolation.
- **Cheats (assisted):** Preferences ▸ Cheats / Game ▸ Cheats with *Enable All*: the original developer cheats as
  one switch (plus buttons for their keys), invincibility, infinite ammunition, grenades, flares, morale and
  soldiers, and a frozen airstrike timer.
- **Disk:** import and health check of your own `.adf` dumps with automatic repair.
- **Original extras kept:** saved high scores (Application Support/Platoon),
  the original Ocean credits text, instant loading, 50 Hz presentation on variable-refresh displays.

## Faithfulness
Every section was verified against the original running in the reference emulator with identical inputs:
game RAM compared tick by tick (with the RNG made deterministic in both), screenshots pixel by pixel and the audio
driver's register stream write by write, including complete honest play-throughs of every section and all hand-overs
(jungle → village → tunnels → flare → final jungle → foxhole → ending → high-score entry). Evidence: `port/verify/`.

Speed and sound are those of a real Amiga 500. The reference emulator gives the 68000 every bus cycle and finishes
blits instantly, which made the CPU-bound parts run too fast there (the jungle and village, the flare night and the
final jungle). The port's timing was therefore calibrated against the cycle-exact vAmiga, tick by tick on identical
games: jungle ~18 ticks per second instead of 25, final jungle ~25 instead of 50. Paula follows the hardware too:
one audio DMA word per line (caps very high notes), the A500's 4.4 kHz filter and its "LED" filter, which the game's
loader switches on. Details: `port/verify/timing.md`.

## Original cheats
Type `HAMBURGER` on a title screen ("CHEAT!!!" appears in the credits), then `KEYPAD-` `H I L L` for "MEGA CHEAT"
(or switch on Preferences ▸ Cheats ▸ *Original developer cheats*, which does the same). Then: in the jungle & village
F1-F4 warp to the start / near the explosives / the bridge / the village and F5 / F6 switch invincibility on / off;
HELP skips the tunnels (to the flare night) and the flare night (to the final jungle); CAPS LOCK in the final jungle
wins the game. The Cheats tab also has extra cheats (invincibility everywhere, infinite ammunition, grenades, flares,
morale and soldiers, frozen airstrike timer). A game with any cheat on goes to the assisted high-score table
(typed codes too, if General ▸ *Games with the original cheat codes use the assisted table* is on). Details:
[port/ENHANCEMENTS_GUIDE.md](port/ENHANCEMENTS_GUIDE.md#cheats-the-original-developer-cheats-and-extra-ones).

## Legal
The code and documentation written for this project are released under the MIT licence (`LICENSE`). That licence
covers only the original work here: the original game — its code, data, graphics, music, names and artwork — remains
© Ocean Software / Hemdale, and no rights to it are granted (see `NOTICE`). The repository contains no game assets;
you must own the original game. This is an unofficial fan project, not affiliated with or endorsed by any rights
holder. The bundled Musashi 68000 core (`tools/Musashi`) is © Karl Stenerud, MIT-style licence.

## Repository layout
- `original/` — (not in the repository) put your own disk images here.
- `re/` — reverse-engineering: per-module specs (`re/<module>/NOTES.md`), annotated listings, extraction scripts.
- `tools/amiga/emu` — headless reference Amiga emulator used to verify the port (`make -C tools/amiga`).
- `tools/vamiga/` — cycle-exact real-A500 reference (driver for the vAmiga core, fetched by `build.sh`) used to
  calibrate the game speed (`timing_check.py`).
- `port/` — the Swift package: `PlatoonCore` (platform + translated game), `PlatoonApp` (macOS app),
  `platoon-headless` (verification runner). See `port/PORTING.md`.
