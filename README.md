# Platoon for macOS

A native macOS port of Ocean's **Platoon** (Amiga, 1988). The original 68000 game code was reverse-engineered and
translated routine by routine into Swift. It runs on a small virtual Amiga chipset (blitter, copper, display, Paula
audio), so the gameplay, graphics, music and timing are those of the original on a real Amiga 500. Around the game
the app adds optional modern extras: a pause menu, save states, controller support, maps, accessibility options
and more. All of them are off by default.

The repository contains **no game data**. You need your own copy of the Amiga disk image (see
[Get the game disk](#2-get-the-game-disk)).

**Contents:** [Quick start](#quick-start) · [How to play](#how-to-play) · [Controls](#controls) ·
[Optional extras](#optional-extras) · [Cheats](#cheats) · [How the port works](#how-the-port-works) ·
[For developers](#for-developers) · [Legal](#legal)

## Quick start

### 1. Requirements
- macOS 14 (Sonoma) or later, on Apple silicon or Intel.
- Xcode 16 or later, or its command-line tools (`xcode-select --install`).
- Optional: Python 3 with Pillow, to generate the app icon from your disk.

### 2. Get the game disk
The port runs the TOSEC dump **`Platoon (1988)(Ocean)[cr 68 Darc].adf`**. On its own that dump has a blank
high-score table and corrupt room pictures in the final jungle; the app repairs both if you give it a second dump
as well:

| You have | Result |
|---|---|
| `[cr 68 Darc]` + `[b]` (the original) | fully repaired, identical to the tested disk (**recommended**) |
| `[cr 68 Darc]` + `[cr VF - Beyonders][t +5 LFC]` | fully repaired |
| `[cr 68 Darc]` alone | playable, with a warning: the final jungle's room pictures are damaged |
| `[b]` or `[cr VF - Beyonders]` alone | not usable (a different version of the main program) |

Unzip the `.adf` files first; the app does not read `.zip` archives.

### 3. Build and run
```sh
git clone https://github.com/tmm22/platoon-macos.git
cd platoon-macos/port
./build_app.sh
open build/Platoon.app
```
`build_app.sh` makes a universal (Apple silicon + Intel) `build/Platoon.app`. On first launch the app asks for
your disk: select the dump(s) together (⌘-click to select two). You can also import later with **Game ▸ Import
Disk Image…** (⌘O) or by dropping `.adf` files on the window or the Dock icon. The repaired disk is stored in
`~/Library/Application Support/Platoon/Platoon.adf`, so you only do this once. **Game ▸ Check Disk…** shows a
health report for the disk in use.

To put the disk inside the app instead (and to run the tests and developer tools), save the repaired image as
`re/platoon_port.adf` before building:
```sh
cd port && swift build -c release --product Platoon
.build/release/Platoon --check-disk "Platoon (1988)(Ocean)[cr 68 Darc].adf" "Platoon (1988)(Ocean)[b].adf" \
    --repair ../re/platoon_port.adf
```
`build_app.sh` bundles `re/platoon_port.adf` when it exists (`DIST=1 ./build_app.sh` leaves it out) and generates
the app icon from its loading picture.

## How to play
You lead a platoon of five soldiers through three load sections. Each section shows its mission on a text screen;
press fire to start. The game ends when the platoon is wiped out, when morale reaches zero, or when you win.

**The HUD** shows the score, morale (falls when your men are hit or when you shoot villagers; at zero the game is
over), the current soldier's wounds and ammunition, and section items (grenades, flares, compass, timer). A soldier
dies after four wounds. Clues appear as short messages on the HUD line; they are easy to miss (the optional message
log keeps them, see [Optional extras](#optional-extras)).

### 1. The jungle and the village
A side-scrolling jungle of several strips joined by paths.
- **Move** left/right. **Up** takes a path to the strip above (or enters a hut door in the village), otherwise
  jumps (over tripwires). **Down** takes a path down, otherwise crouches.
- **Fire** shoots (hold for automatic fire). **SPACE with no direction held** throws a grenade (spider-hole VC can
  only be killed with grenades). **Left Alt** (Option) lets you choose another soldier.
- Find the **explosives** on the deepest strip, then walk onto the **bridge** on the front strip: the charge is
  set automatically. Walking past the bridge without the explosives costs you the whole platoon.
- In the **village**, don't shoot villagers. Inside a hut, push **up** to search; some drawers are booby-trapped.
  Find a **torch** and the **tunnel map** (a VC guards that hut), then the **trap door**. Answer **Y** to go down;
  you need the torch.

### 2. The tunnels and the flare night
- **The tunnels** are a first-person maze. **Up** walks forward, **left/right** turn. When an enemy appears the
  stick moves the crosshair and fire shoots. In a room, move the crosshair over things and press fire to search
  them (or to leave the room).
- Collect **8 flares**; a **compass** (shows your heading) and a **map** help. The exit opens only with 8 flares.
  Only two soldiers go down into the tunnels.
- **The flare night**: hold out in a foxhole until dawn. **SPACE** (or fire on the flare box) launches a flare;
  shoot the VC while it is light. You survive when the light of your last flare dies.

### 3. The final jungle and the bunker
- You have **two minutes** before the airstrike. The jungle is a grid of look-alike rooms: **up/down** move you
  deeper into a room or back, **left/right** sideways, and **fire** shoots. Walk up to the **far end** of a room,
  then go **left or right** to leave it. Exits are relative to the way you face, so the compass from the tunnels
  helps a lot. Mines, barbed wire and snipers (who shoot if you stay at one depth too long) wait on the way.
- In the **bunker**, only grenades hurt **Sgt Barnes**: fire throws them. After five hits, walk to the bunker door.

## Controls
The defaults; every key and controller button can be changed in **Game ▸ Controls & Bindings…** (⌘/).

| Action | Keyboard | Controller |
|---|---|---|
| Joystick | arrow keys | d-pad / left stick |
| Fire | Space or Z | A, B, right trigger, right shoulder |
| Amiga SPACE (jungle grenade, flare) | Space | X |
| Choose soldier (jungle) | Left Option (= Amiga Left Alt) | Y |
| Answer Yes / No (trap door) | Y / N | LB / LT, or A = yes, B = no at the prompt |
| Pause (the game's own pause) | Tab | Menu |
| Music / sound effects on/off | F10 | Options |
| Abort to the title screen | Forward Delete (fn + Delete on a laptop) | |
| High-score name | joystick left/right + fire (or type it, optional) | |
| Amiga HELP / keypad − | F11 / F12, or Game ▸ Send Amiga Key | |

Space is both fire and the Amiga SPACE key, as on the original keyboard-and-joystick setup; the *Separate fire and
SPACE* preset in Controls & Bindings splits them.

**App keys** (the game never reads them): **Esc** pause menu · hold **`** (or L3) fast-forward · hold
**Backspace** (or R3, ⌘Z) rewind, when rewind is on · **M** jungle or tunnel map and **N** final-jungle
navigator, when those are on.

**Mac shortcuts:** ⌘, Preferences · ⌘/ Controls & Bindings · ⌘P pause · ⌘T turbo · ⌘R reset · ⌘K continue from
the last section · ⇧⌘S / ⇧⌘L quick save / load · ⇧⌘R retry from checkpoint · ⌘S screenshot · ⌥⌘R record video ·
⌥⌘L message log · ⌘1 / ⌘2 / ⌘3 / ⌘4 sharp / smooth / CRT / pixel-art upscaler · ⌃⌘F full screen · ⌘O import
disk. The menus list the rest.

## Optional extras
With every setting at its default you play the original 1988 game. Everything below is optional, set in
**Preferences** (⌘,) or the menus. Options that change the game are marked **GAMEPLAY**; a game played with one of
them, or with a cheat, a loaded save, rewind, practice or a later start section, is *assisted*: its score goes to a
separate high-score table and never to the original one.

- **Comfort:** pause menu, auto-pause, fast-forward, slow motion (60-100 %), quick save and 5 save slots, automatic
  checkpoints, rewind, continue from the last section, start a new game at any section.
- **Help for a cryptic game:** message log of every HUD clue, large captions and speech, objectives with three
  levels of detail, section briefings, a numeric HUD, a jungle and village map, a tunnel map, a final-jungle
  navigator, a booby-trap warning.
- **Difficulty and rules (gameplay):** Recruit / Veteran / Custom presets, up to five soldiers in the later
  sections or the whole platoon carried over, bridge failsafe, forgiving booby traps, fairer tunnels, separate jump
  and crouch controls, village and tunnel randomisers, and a switch for each original bug fix.
- **Practice and records:** practice drills for seven key moments, input replays, a speedrun timer with splits and
  LiveSplit export, a local service record with medals.
- **Controls and accessibility:** rebinding with presets (including one-handed), full controller support,
  QWERTZ/AZERTY layouts, tap stretching, toggle fire and directions, auto-fire, mouse and right-stick aiming,
  rumble, colour-vision modes, HUD magnifier, reduced flashing, brighter night scenes.
- **Picture:** sharp pixels, smooth, CRT looks (1084S, PVM, A520, custom), a pixel-art upscaler, integer scaling,
  ambient glow in the side bars, widescreen jungle, video / GIF recording.
- **Sound:** separate music and effects volume, panning, *ghost voices* (the music keeps all its parts during
  gunfire), band-limited synthesis, ambience, your own replacement soundtrack, A500 filter.

The full guide is [port/ENHANCEMENTS_GUIDE.md](port/ENHANCEMENTS_GUIDE.md) (also in the app: **Help ▸ Platoon
Enhancements Guide**).

## Cheats
The game's own developer cheats: type `HAMBURGER` on a title screen ("CHEAT!!!" appears in the credits), then
keypad `-` and `H I L L` for "MEGA CHEAT" (or switch on **Preferences ▸ Cheats ▸ Original developer cheats**). Then:
- jungle and village: **F1-F4** warp to the start / near the explosives / the bridge / the village, **F5 / F6**
  invincibility on / off;
- tunnels: **HELP** skips to the flare night; flare night: **HELP** skips to the final jungle;
- final jungle: **CAPS LOCK** wins the game.

The Cheats tab also has invincibility, infinite ammunition, grenades, flares, morale and soldiers, and a frozen
airstrike timer. Games with any cheat on use the assisted high-score table. Details:
[the guide's Cheats chapter](port/ENHANCEMENTS_GUIDE.md#cheats-the-original-developer-cheats-and-extra-ones).

## How the port works
- **Source port, not an emulator.** Each original routine is a Swift function that keeps the original arithmetic,
  order and memory layout. The game's data (graphics, maps, music, samples) is read from your disk image at runtime
  and lives at its original addresses in a 512 KB virtual chip RAM.
- **Verified against the original.** Every section was run side by side with the original game in a reference
  emulator, with the same inputs and the random numbers made deterministic: game RAM compared tick by tick,
  screenshots pixel by pixel and the music driver's register writes one by one. This covers complete play-throughs
  of every section and every hand-over (jungle → village → tunnels → flare night → final jungle → bunker → ending →
  high-score entry). A regression gate (`tools/regress_all.sh`, 62 scenarios) keeps the default game byte-identical.
- **Real A500 speed and sound.** Several of the game's loops run as fast as the CPU and blitter allow, so their
  speed depends on the hardware. The port's timing is calibrated tick by tick against the cycle-exact vAmiga
  emulator: the jungle runs at about 18 game ticks per second and the final jungle at about 25, as on an A500.
  Paula follows the hardware too (one audio DMA word per line, the 4.4 kHz output filter and the "LED" filter).
  Details: [port/verify/timing.md](port/verify/timing.md).

## For developers
- [port/PORTING.md](port/PORTING.md): how the port is built, the translation rules, the verification tools and the
  regression gate.
- `re/<module>/NOTES.md`: the reverse-engineered specification of each part of the original
  ([re/NOTES.md](re/NOTES.md): disk layout and memory map).
- `port/verify/`: verification evidence and test harnesses.

```sh
make -C tools/amiga                    # reference emulator (runs the original game)
cd port && swift build -c release      # app, core and headless runner
cd port && swift test                  # unit tests (the ones that need the game disk are skipped without it)
tools/regress_all.sh                   # regression gate: must print ALL PASS
```

| Path | Contents |
|---|---|
| `port/Sources/PlatoonCore/Platform/` | virtual Amiga chipset: memory, custom chips, copper, blitter, CIA, Paula, disk |
| `port/Sources/PlatoonCore/Game/` | the translated game, plus the enhancement options, save states and assist models |
| `port/Sources/PlatoonApp/` | the macOS app: AppKit, Metal, AVAudio, GameController |
| `port/Sources/platoon-headless/` | command-line runner used for verification |
| `re/` | reverse-engineering notes and extraction scripts |
| `tools/` | reference emulator (`amiga/`), vAmiga timing reference (`vamiga/`), disassembler, regression gate |
| `original/` | (not in the repository, ignored by git) a place for your own disk images |

## Legal
The code and documentation written for this project are released under the [MIT licence](LICENSE). That licence
covers only the original work in this repository. The original game, its code, data, graphics, music, names and
artwork, remains © 1987/1988 Ocean Software / Hemdale Film Corporation; no rights to it are granted (see
[NOTICE](NOTICE)). The repository contains no game data, and you must own the original game to play it. This is
an unofficial, non-commercial fan project, not affiliated with or endorsed by any rights holder.

The bundled Musashi 68000 core (`tools/Musashi`, used only by the reference emulator) is © Karl Stenerud, under an
MIT-style licence.

Original game: programmed by Sean Pearce and Colin Gordon, graphics by Sharon Beattie, music and sound effects by
David Whittaker.
