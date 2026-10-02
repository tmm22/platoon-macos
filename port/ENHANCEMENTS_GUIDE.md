# Platoon for macOS: guide to the optional extras

The port plays the original 1988 game. Around it, the app offers optional extras: comfort features (pause menu,
save states, rewind, fast-forward), help for a famously cryptic game (message log, maps, objectives, navigator),
difficulty and rule options, accessibility, better picture and sound, practice, replays and records. How to set the
game up and play it is in the [README](../README.md).

**Everything is optional.** With every setting at its default you play the original game: the translated code, its
timing and its random numbers are unchanged. The only things on by default are ones that don't change the game:
display fixes (sharp pixels, the original Ocean credits text, a sharp status bar with the pixel-art upscaler,
letter keys following your keyboard layout) and conveniences on keys and buttons the game never reads (Esc pause
menu, hold-to-fast-forward, the extra controller buttons, the message log and replay recording in the background).

## Contents
1. [Finding things](#finding-things) - Preferences, menus, the pause menu, app keys
2. [Assisted games and high scores](#assisted-games-and-high-scores)
3. [The app: pause menu, preferences, fast-forward, game speed, disk import](#the-app-pause-menu-preferences-fast-forward-game-speed-disk-import)
4. [Save states: quick save, checkpoints, rewind](#save-states-quick-save-checkpoints-rewind)
5. [Controls: keyboard, controller, accessibility, aiming, rumble](#controls-keyboard-controller-accessibility-aiming-rumble)
6. [Picture: filters, CRT looks, effects, accessibility, recording](#picture-filters-crt-looks-effects-accessibility-recording)
7. [Sound: mixer, ghost voices, sound character, soundtrack, output timing](#sound-mixer-ghost-voices-sound-character-soundtrack-output-timing)
8. [Assists: message log, captions, objectives, timer, replays, practice, difficulty page](#assists-message-log-captions-objectives-timer-replays-practice-difficulty-page)
9. [Jungle & village: failsafes, fixes, map, widescreen](#jungle--village-failsafes-fixes-map-widescreen)
10. [Tunnels & flare night: map, fairness, fixes](#tunnels--flare-night-map-fairness-fixes)
11. [Final jungle & foxhole: navigator, room slide, fixes](#final-jungle--foxhole-navigator-room-slide-fixes)
12. [Cheats: the original developer cheats and extra ones](#cheats-the-original-developer-cheats-and-extra-ones)
13. [Game options, difficulty presets, command line](#game-options-difficulty-presets-command-line)

Developer documentation (code, tests, the regression gate) is in [PORTING.md](PORTING.md).

---

## Finding things

**Preferences** (press ⌘, or choose Help ▸ Preferences…) has seven tabs. Every option of this guide has a row there:

| Tab | What is there |
|---|---|
| General | pause behaviour, pause menu, fast-forward, game speed, keyboard response, game disk, title screen and high scores, save states (checkpoints, rewind) |
| Input | keyboard and controller presets, Controls & Bindings, controller hints and dead zone, high-score name typing, motor accessibility (tap stretching, toggles, auto-fire), aiming, rumble |
| Video | filter, CRT look, pixel-art upscaler, around the picture (glow, shake, hit flash, sniper cue), accessibility (night lift, reduced flashing, colour vision, HUD magnifier), recording, widescreen jungle, tunnel turn slide, final-jungle room slide |
| Audio | output, F10 mode at start-up, mixer, music (ghost voices, replacement soundtrack), sound character, output timing |
| Gameplay | difficulty preset and summary, custom difficulty knobs per section, platoon (soldiers, full platoon), jungle & village rules and bug fixes, tunnels rules and bug fixes, final-jungle bug fixes |
| Assist | messages and captions, objectives and briefings, speedrun timer and service record, replays, practice, jungle map, tunnel map, final-jungle navigator |
| Cheats | enable / disable all, the original developer cheats and their keys, invincibility, infinite ammunition / grenades / flares / morale / soldiers, freeze the airstrike timer |

Rows marked **GAMEPLAY** change the game (see the next chapter); rows marked **ON RESET** are read when a new game
starts, and the window's footer offers **Reset Game Now** while such changes are waiting. **Restore Defaults**
resets the current tab.

**Menus.** *Game*: pause, reset, continue, start at a section, cheats, save states (quick save / load, slots, retry
from checkpoint, rewind, and the checkpoint / rewind switches), send Amiga key, screenshot, disk import and check,
Controls & Bindings. *View*: filters, CRT look, picture effects and accessibility, recording, widescreen jungle,
room slide. *Sound*: output, mixer, synthesis, ambience, ghost voices, replacement soundtrack. *Assist*: message log,
the overlay switches (captions, speech, objectives, numeric HUD, timer, jungle and tunnel maps, navigator), practice,
replays, service record. *Help*: this guide, the README, Controls & Bindings, Preferences.

**Pause menu** (Esc, Game ▸ Pause Menu, or hold the controller's Menu button when that is switched on): resume,
save / load, retry from checkpoint and rewind (when on), message log, objectives, the map or navigator of the
section you are in, recording, practice, the original cheat keys that work right now (when the original cheats
are on), restart the section, Options, Controls & Bindings, abort to title, quit.
Entries that don't apply right now (another section's map, a replay or practice drill that isn't running) are
left out. It works with the keyboard, a controller and the mouse.

**App keys** (the game never reads them, so nothing is taken away): **Esc** pause menu, hold **`** fast-forward,
hold **Backspace** rewind (when on), **M** hides / shows the jungle or tunnel map, **N** the final-jungle navigator.
Controller: **L3** fast-forward, **R3** rewind, hold **Menu** pause menu (optional).

**Overlays** (maps, objectives, numeric HUD, timer, captions, badges) are drawn above the game, never into it: they
never appear in ⌘S screenshots or recordings. They sit beside the picture when the window is wide enough, otherwise
on it, and they keep clear of each other (a panel that would cover another moves below or above it).

---

## Assisted games and high scores

A game is **assisted** when anything that changes it, or helps beyond what the original offers, was used. Its score
never enters the original high-score table (`~/Library/Application Support/Platoon/hiscores.bin`, the one the
title screen shows); it goes to a table of its own next to it:

| Table | Games |
|---|---|
| `hiscores.bin` (original) | games played with every gameplay option at its default and none of the aids below |
| `hiscores-recruit.bin`, `hiscores-veteran.bin` | the Recruit / Veteran preset and nothing else |
| `hiscores-custom.bin` | only difficulty knobs (Custom, or knobs on top of a preset) |
| `hiscores-assisted.bin` | everything else |

What makes a game assisted:
- any row marked **GAMEPLAY** in Preferences that is not at its default (difficulty, soldiers, rules, bug fixes,
  randomisers, compass assist, direct aiming, game speed below 100 %);
- any cheat (Preferences ▸ Cheats or Game ▸ Cheats, the original developer cheats switch too), from the moment it
  is switched on;
- loading a save, retrying a checkpoint, rewinding, practice drills, replays, *Continue from Last Section* and
  starting at the tunnels or the final jungle (starting a new game at the jungle is an ordinary game);
- assists that act during the game, from the moment they first act: assisted aiming, auto-fire, the objectives'
  *full solution*, the jungle map's hut contents, the booby-trap warning, the tunnel map's *reveal the whole maze*,
  the final-jungle route guide and its heading without the compass;
- optionally the original cheat codes (General ▸ Title screen and high scores).

Not assisted: everything display- or sound-only, the message log, captions and speech, objectives (goals and hints),
the plain maps, the navigator heading when you carry the compass, remapped controls, tap stretching and toggles,
faster key response, fast-forward, the pause menu, taking saves or checkpoints without loading them.
The mark is per game: a new game from the title starts clean unless a setting that marks it is still on.
The pause menu shows **ASSISTED** under its title while the current game is marked.

---

## The app: pause menu, preferences, fast-forward, game speed, disk import
These are part of the Mac app around the game. Only the game speed changes the game (it marks it assisted).

### Preferences (⌘,)
One window with tabs General, Input, Video, Audio, Gameplay, Assist and Cheats (see [Finding things](#finding-things) for
what is where). Every option of the game's enhancement catalogue has a row. Badges:
- **GAMEPLAY**: changes the game. Runs that use it are assisted and never enter the original hiscore table.
- **ON RESET**: read when a new game starts. The window footer shows how many changes are waiting, with a
  **Reset Game Now** button.

**Restore Defaults** resets the current tab. The video and audio settings from the View/Sound menus appear here
too (with sliders for scanlines, volume and stereo separation) and stay in sync with the menus.

### Pause menu
Press **Esc**, or choose Game ▸ Pause Menu. On a controller you can hold **Menu** for half a second, once
"Hold the controller Menu button" is on in General; a short press still sends the in-game TAB pause, on release.
The game is frozen and silent while the menu is open. Controls: ↑/↓ or the d-pad to move, Return/Space or Ⓐ to
choose, Esc or Ⓑ to go back. The mouse works too.
- **Resume**.
- **Save Game / Load Game** (slots), **Retry from Checkpoint** and **Rewind…** (when those are switched on),
  **Message Log**, **Show / Hide Objectives**, the jungle map, tunnel map or navigator of the section you are in,
  **Record Video**, **Practice…** (and **Restart Drill** / **Stop Replay** while a drill or replay runs).
- **New Game** (jungle) or **Restart The Tunnels & Flare / The Jungle & Foxhole**. A restart begins again at the
  start of the section, with the platoon you arrived with (the flare night restarts from the tunnels). Rewinds and
  checkpoint retries keep that platoon, also when they go back into the previous section; after loading a saved
  game it isn't known, so the row says "with a fresh platoon (loaded game)". New Game is an ordinary game;
  restarting a later section marks the run assisted.
- **Cheat: …** rows (only while the original developer cheats are on, and only the keys that work where you are):
  the jungle warps F1-F4 and the F5/F6 invincibility, HELP in the tunnels / flare night, CAPS LOCK in the final
  jungle (see [Cheats](#cheats-the-original-developer-cheats-and-extra-ones)).
- **Options…** (Preferences), **Controls & Bindings…**, **Abort to Title…** (the original DEL), **Quit Platoon…**.
  Destructive entries ask for confirmation.

Esc is free for this because the original game never reads the Amiga Esc key. You can switch "Esc opens the pause
menu" off in General.

### Auto-pause, General ▸ Pause, all off by default
- **When the window loses focus**: keep running (original) / pause and resume when you come back / pause and
  open the pause menu. This also covers minimising the window and hiding the app.
- **When the Mac or the display sleeps** and **when a game controller disconnects**: pause and open the pause menu.
- **Pause while a dialog is open** (Controls, disk import).

When the game resumes, any key or button still held down is ignored until you let go of it. The press that closed
the menu can't fire a shot, and a fire button held through a pause doesn't keep firing. A disconnected
controller's buttons are always released, so its last direction can't stay stuck. A **PAUSED** badge in the
corner says why the game is paused; you can switch it off in General.

### Fast-forward
Hold **`** (backquote, the key left of 1) or the controller's **left stick button** to run the game faster:
2×, 3×, 4× (default), 6× or 8×, set in General ▸ Fast-forward. Sound plays quietly at the speed you choose, or
is muted. It's useful for the flare intro, text screens and LOADING screens. The game itself is unchanged: it just
runs more frames per second. ⌘T switches a sticky turbo on and off; it isn't remembered between launches.
While fast-forwarding the badge shows **▶▶ 4×**.

### Game speed, General ▸ Game speed - gameplay
Slow motion for slower reactions: 100 % (original), 90, 80, 70 or 60 %. The whole game runs slower, timers
included; the sound follows at a lower pitch without stutter (the audio output switches to rate control while a
slower speed is active). The game itself is unchanged - it just runs fewer frames per second - but any speed below
100 % marks the game as assisted. It combines with fast-forward.

### Music / FX mode at start-up, Audio ▸ Music / sound FX at power-on
The original always starts with music and FX on. You can choose "Remember the last F10 choice", Music only,
Sound FX only or Off. F10 still cycles the modes during play.

### Game disk: import and health check
Game ▸ **Import Disk Image…** (⌘O), dropping `.adf` files on the window, or opening them with the app. You can
choose **several dumps at once**. Each one is identified from fingerprints of every track the port reads, and the
best image is put together from their good tracks:
- **[cr 68 Darc]** alone: its blank high-score table is replaced by the default table, but the final jungle's room
  pictures (track 127) stay corrupt. You can play, with a warning.
- **[cr 68 Darc] + the original [b] dump** (or the **[t +5 LFC]** trainer image): fully repaired. The result is
  identical to the tested disk.
- **[b]** or **[cr VF - Beyonders]** alone: refused, because their main program isn't the version the port runs.
  The dialog says what to add.

The result is stored as Application Support/Platoon/Platoon.adf, which takes precedence over the bundled disk,
and the game restarts with it. Game ▸ **Check Disk…** shows the report for the disk in use.
Command line: `Platoon --check-disk A.adf [B.adf …] [--repair OUT.adf]` (exit 0 = verified, 1 = playable with
problems, 2 = unusable).

### Help menu
**Help ▸ Platoon Enhancements Guide** opens this guide, **About This Port (README)** the README; Controls &
Bindings and Preferences are there too.

---

## Save states: quick save, checkpoints, rewind
Platoon never had saves. The port can save the whole game while you play in the jungle and village, the tunnels,
the flare night or the final jungle. It can't save on text screens, the man-select box, the trap-door prompt or
loading screens. If you save there, the save is taken as soon as play continues ("Saving at the next
opportunity…"; the pause menu goes back to its main page and says so). A save that is still waiting is dropped, with
a message, when the game is replaced first (reset, new game, loading a save, retrying a checkpoint, rewinding), so
a slot never receives a different game than the one you meant to save.

**Quick save and slots** (always available, Game menu and pause menu)
- **Quick Save** ⇧⌘S and **Quick Load** ⇧⌘L.
- **Save to Slot / Load from Slot**: five slots. Each shows a thumbnail, the section, the date and the score.
  From the pause menu (Esc), a save completes at once.
- Files are kept in `~/Library/Application Support/Platoon/saves/` (`quick.pltsnap`, `slot1…5.pltsnap`); Load
  from Slot › Show Saved Games in Finder opens the folder. A save only loads with the same disk image. A save made
  by a different build of the app still loads, with a warning.

**Automatic checkpoints** (Preferences › General › Save states, or Game menu; off by default)
- The game keeps the start of the current section plus the last three milestones: explosives found, bridge blown,
  village reached, each hut, torch and map found, tunnel rooms and tunnel items, the start of the flare night,
  every final-jungle room and the bunker. A short "Checkpoint: …" message shows when one is taken.
- **Retry from Checkpoint** ⇧⌘R (Game menu and pause menu) goes back to the latest one. Several are kept because
  the latest one can come just before a mistake you can't undo (for example walking past the bridge without the
  explosives).
- "Offer a retry when a soldier dies" shows a short ⇧⌘R reminder when a man is killed.

**Rewind** ("Keep a rewind buffer" in Preferences › General › Save states, or the Game menu; off by default)
- The game keeps a snapshot every second, for 30 s by default ("Rewind length", 10-120 s; about 1.4 MB of memory
  per second).
- **Hold Backspace** (or ⌘Z, or the controller's right-stick click R3). The picture goes back one second at a
  time, faster the longer you hold. **Release** to continue from the moment shown. While holding you can also use
  ← / → to step, Return to resume there, and Esc to cancel and continue where you were. The game is paused while
  you choose.

**Settings:** a loaded save, a checkpoint retry and a rewind continue with the current settings, including
**ON RESET** changes that were still waiting (they are applied by the restore, like by a reset).

**Hiscores:** loading a save, retrying a checkpoint or rewinding marks the game as *assisted*: its score goes into
the assisted table, not the original one. Just taking saves, checkpoints or the rewind ring changes nothing.

---

## Controls: keyboard, controller, accessibility, aiming, rumble
Everything here happens in the app: the game still reads its joystick and keyboard the way it always did. With
the default settings the keyboard does exactly what the original does on a US keyboard, and the controller only gains
jobs on buttons that did nothing before. Options that help you play (auto-fire, aim assist) mark the game as
*assisted* the first time they act.

### Controls & Bindings window: Game ▸ Controls & Bindings… (⌘/), pause menu, or Preferences › Input
- Every action with up to two keys and a controller button: Up/Down/Left/Right, Fire, SPACE (jungle grenade,
  flare), Change soldier (Left Alt), Yes/No (trap door), Pause (TAB), Music/FX, Abort (DEL), HELP, Keypad −,
  Jump/Crouch (only with the jungle option "Separate jump and crouch controls") and Turbo fire.
- Click a cell and press a key or a controller button. Modifier keys (Option, Shift, Control) work. Esc cancels,
  Backspace clears the slot. Clicking the controller cell replaces that action's buttons; the ⊕ next to it adds one
  button (or removes it, if the action already has it), e.g. to give Fire a fifth button. The ⓧ button unbinds an
  action.
- The pause menu's "Controls & Bindings…" row and Help ▸ Controls & Bindings… open this window too.
- Presets. Keyboard: **Original** (Space is fire *and* the Amiga SPACE key, Z is fire), **Separate fire and SPACE**
  (Z/X fire, Space is only SPACE, closer to the Amiga's separate stick button), **One-handed left** (WASD, Space
  fire, Q SPACE, E change soldier, R yes, F no, Z/X jump/crouch, G music) and **One-handed right** (arrows, Right
  Shift or / fire, Return SPACE, . change soldier, ; yes, ' no). Controller: **Extended** (default), **Original
  mapping only**, **One-handed left half** (d-pad, LB fire, LT SPACE, Options change soldier) and **One-handed
  right half** (right stick, RB/RT/A fire, X SPACE, Y change soldier).
- Keys not bound to an action still type their Amiga key, so the cheat codes and the high-score name keep working.
- The bottom of the window lists the current controls, generated from your bindings, and warns about keys bound
  twice. Bindings are saved and survive restarts. Restore Defaults brings back the original set.

### Controller: Preferences › Input › Controller
- **Extended** buttons (default): **X** = Amiga SPACE (jungle grenade with no direction held, flare), **Y** =
  change soldier (sent as a short tap, so holding it doesn't reopen the choose-your-man box), **LB** = Yes,
  **LT** = No. Unchanged: d-pad / left stick = joystick, A/B/RT/RB = fire, Menu = TAB, Options = F10.
- **Trap door**: at the "enter the trap door?" prompt, a fresh press of **A** (or another fire button) answers
  Yes, **B** or the SPACE button answers No. A fire button that was already held when the prompt appeared doesn't
  answer. Switch: "Trap door: A answers Yes, B answers No".
- **Hints**: while a controller is connected, the trap-door prompt, the choose-your-man box and the high-score name
  entry show which of your controller's buttons to press.
- **Stick dead zone** slider (default 40%). A controller that disconnects releases everything it was holding.
- Buttons the app keeps for itself: L3 = hold to fast-forward, R3 = hold to rewind (when those are on), Menu held
  0.5 s = pause menu (when that is on).

### Keyboard fixes: Preferences › Input › Keyboard
- **Letter keys follow the keyboard layout** (default on). On QWERTZ the key labelled Y answers Yes and the key
  labelled Z fires; on AZERTY A, Q, Z, W and M are taken by their labels. The digits row, arrows, F-keys and
  keypad stay by position. On a US keyboard nothing changes. Switch it off to get the original US positions.
- **Game ▸ Send Amiga Key**: HELP, Keypad −, SPACE, Left Alt, Y, N, TAB and F10 from the menu, for laptops where
  F10-F12 are media keys (F11 = HELP and F12 = keypad minus still work too).

### High-score name on the keyboard: Preferences › Input › High-score name
- "Type the high-score name on the keyboard" (applies after a reset): letters, digits and space type, Backspace
  deletes, Return finishes. The joystick still works. While you type, keys that type a character type it, even if
  they are bound to fire or another action (so Z and Space don't shoot, and Return finishes the name in the
  right-hand preset).

### Motor accessibility: Preferences › Input › Motor accessibility (all off by default)
- **Stretch short taps**: every press and release of the stick, fire and the Amiga keys lasts at least 2-8
  frames (default 4), so quick taps aren't lost between the tunnels' stick reads (every 4 frames) or the jungle's
  (every 2-3). Two quick taps still count as two. Only during play, not on the title, text or name-entry screens.
- **Toggle fire** / **Toggle directions**: tap to hold, tap again to release. A direction is also released by
  tapping the opposite one: tap UP once to keep walking through the tunnels or the final jungle.
- **Auto-fire**: "While fire is held" or "Turbo-fire button only" (bind Turbo fire in Controls & Bindings).
  Fire pulses on and off, at least one game tick each (automatic speed per section, or 2-6 frames). Useful for the
  final jungle's one-shot-per-press rifle. Marks the game as assisted once it fires.
- One-handed layouts: see the presets above.

### Explicit jump and crouch
- Turn on the gameplay option "Separate jump and crouch controls" (Preferences › Gameplay › Jungle & village,
  `s0.explicitJumpCrouch`). Then **Jump** (X key, controller LB) and **Crouch** (C key, controller LT) work in the
  jungle and UP/DOWN only take paths and hut doors. In the Separate preset they are C and V; rebind them in
  Controls & Bindings (the actions "Jump (jungle)" and "Crouch (jungle)"). Without the option these bindings do
  nothing (X and C type their letters as usual).

### Pointer and right-stick aiming: Preferences › Input › Aiming (tunnels and flare), off by default
- In the tunnel fights, the room searches and the flare dugout, the crosshair follows the mouse / trackpad pointer
  over the picture, or the right stick (how far ahead it aims: "Right stick reach"). It works by pressing the
  joystick for you, so the original crosshair speed and limits still apply; any direction you press yourself wins.
  Left click fires, right click is SPACE (flare) in the dugout. The pointer stops steering 1.5 s after it stops
  moving. Marks the game as assisted once it aims.
- With the tunnels gameplay option `s1.directAim` (Preferences › Gameplay) the crosshair jumps to the pointer
  instead.

### Controller rumble: Preferences › Input › Controller rumble (off by default)
- Explosions strong (jungle grenades and traps, the foxhole grenade), being hit medium, enemy fire and hits on the
  enemy light, your own shots, throws and flare launches a short tick; a wound medium, a death long and strong, the
  grenade that hits Barnes strong, and the bridge blast and the napalm strike long. Strength slider. Works with the
  sound effects switched off too. The game's sound numbers mean different things in each section (the jungle's
  "player hit" sound is the tunnels' "enemy hit"), so the rumble follows the section you are in, and the sound and
  the wound of the same hit give one pulse, not two.

---

## Picture: filters, CRT looks, effects, accessibility, recording
Everything in this section is display-only: nothing reaches the emulated Amiga, so none of it makes a run
assisted. It never shows in ⌘S screenshots or in recordings unless stated. Settings: **Preferences › Video**
(⌘,) and the **View** menu.

### Filters - View › Sharp Pixels ⌘1 / Smooth ⌘2 / CRT ⌘3 / Pixel-Art Upscaler (MMPX) ⌘4
- **Sharp Pixels** (default): every pixel keeps its exact Amiga colour; only the one-pixel seams at non-integer
  scales are blended. With Integer Scaling the image is pixel-exact.
- **Pixel-Art Upscaler**: MMPX (McGuire & Gagiu 2021), which smooths diagonal edges of the 64×48 jungle
  tiles, sprites and the pictures without blurring the dithering and without inventing colours.
  **Keep the status bar sharp** (Preferences › Video › Pixel-art upscaler, on by default) leaves the HUD's
  digits and bars as square pixels and smooths only the game window.
- **CRT** with a **CRT look** (View › CRT Look or Preferences › Video › CRT look): *Classic* is the port's
  first CRT shader. *Commodore 1084S* (slot mask, bloom, a little phosphor persistence, PAL colour response),
  *Sony PVM* (aperture grille, sharp, strong scanlines), *A520 composite* (colour bleed from the TV modulator), and
  *Custom* (mask type and strength, bloom, persistence, colour bleed, sharpness, 1084 colour). The mask is sized
  to whole triads per Amiga pixel, so it never beats against the picture (no moiré at 1080p/1440p); below about
  2.5 screen pixels per triad it switches itself off. Persistence fades per emulated frame, so it looks the same
  under fast-forward. It is a look only: it does not smooth the jungle's ~18 Hz movement.
- **Colour-managed output (sRGB)** (Video › Around the picture, off by default): wide-gamut (P3) displays show
  the Amiga colours as intended instead of over-saturated.

### Around the picture
- **Side bars: ambient glow** - fills the black bars beside the picture with a blurred, darkened extension
  of the frame (brightness slider). View › Ambient Glow in the Side Bars.
- **Screen shake** - Off / Subtle / Strong. Explosions (jungle grenades and trap, foxhole grenades), the
  bridge blast, the napalm strike and your wounds shake the picture by up to 2-3 Amiga pixels. It decays per
  emulated frame. Controller rumble is the input section's option.
- **Red screen-edge flash when you are hit** - a visual cue for playing without sound.
- **Final jungle: show which side a sniper shot comes from** (off by default) - a "◀ SNIPER" / "SNIPER ▶"
  caption at that edge of the picture while the idle shot (fired at you when you stay at one depth too long) is in
  flight; another cue for playing without sound.
- **Widescreen jungle** - see the jungle section; the columns are composited by this renderer.

### Accessibility
- **Brighten the dark night scenes** + amount - lifts the dark tones of the game window (never the HUD,
  black stays black) while the tunnels or the flare night are on screen. It makes enemies a little easier to spot
  in the flare night.
- **Reduce flashing** + flash strength - limits the red flash when you are hit in the tunnels and the
  flare night, the napalm white-out, and the flare's sudden light-up, to the chosen strength. The picture stays
  visible even at the peak of a flash (where the original turns every colour into the same red or white).
  **Steady background colour while TAB-paused** switches off the pause colour cycling (core option, after a reset).
- **Colour vision** - assist modes for deuteranopia / protanopia / tritanopia (they move the colour
  differences you can't see into ones you can: the HUD's red and green, enemies against the jungle), plus
  simulations of each type and greyscale, with a strength slider.
- **HUD magnifier** - the status bar (time, score, morale, ammo) again, enlarged 1.25-3×, below the picture;
  the picture gets smaller to make room. Empty on the title and text screens.

### Recording and screenshots
- **View › Record Video (⌥⌘R)** - H.264 + AAC movie of the game picture and Paula's sound, 50 frames per second
  of *game time*: fast-forward is recorded at normal speed and pauses are left out. 2×/3×/4× size (nearest
  neighbour), optionally tagged with the PAL pixel aspect so players show it 4:3. The pause menu has
  Record Video / Stop Recording too. A REC badge shows while recording (not recorded).
- **View › Record GIF (⌥⌘G)** - animated GIF (exact colours, 25 or 50 fps, 320×256 or 640×512, stops by itself
  after 60 s).
- **View › Copy Screenshot (⌥⌘C)** - the visible 320×256 picture to the clipboard.
- Folders: recordings go to Movies ▸ Platoon (or Desktop / Pictures ▸ Platoon); **Save screenshots (⌘S) to**
  picks the ⌘S folder (Desktop by default) and can also copy them to the clipboard.
  View › Show Recordings in Finder.

---

## Sound: mixer, ghost voices, sound character, soundtrack, output timing
None of these options changes the game: they only change how Paula's output is mixed and played on the Mac, so
they never make a run *assisted* and they all apply immediately (no restart). With every setting at its default you
hear a real A500: Paula fetches one audio word per channel and raster line (so very short periods are capped in
pitch, as on the hardware), the fixed 4.4 kHz output filter is on, and the 3.1 kHz "LED" filter is heard whenever the
game has the power LED on (after each disk load until the next tune or sound effect, e.g. the title music after the
high scores load). The A500 filter switch (Preferences › Audio) turns both filters off.
App: **Preferences › Audio** (⌘,); a few toggles are also in the **Sound** menu (Band-limited Synthesis, Ambience
(Automatic), Replacement Soundtrack, Choose Soundtrack Folder…, Audio Mixer…, Ghost Voices).

### Mixer - Audio › Mixer
- **Music volume / Sound effects volume** (0-200 %, default 100 %). Each of Paula's four voices is tagged by who owns
  it at that moment - the music driver or a sound effect - so e.g. quieter gunfire under the tunes works even though
  both share the same four channels.
- **Voice panning:** Amiga (L R R L, default), Swapped, Soft (half-way), Mono, or Custom with one slider per voice.
  The *Stereo separation* slider (Audio › Output) narrows whatever is chosen.

### Ghost voices - Audio › Music, or Sound › Ghost Voices
Every rifle shot takes one or two of the four channels away from the music, so Whittaker's in-game tunes lose parts in
every firefight. With ghost voices on, the silenced music parts keep playing on four extra voices on the Mac while the
sound effect owns the channel, and afterwards until the music next retriggers that voice (the original driver's
restore restarts the part out of step with the tune; the ghost bridges that gap seamlessly). Measured: the music of a
run with sound-effect bursts, effects muted, is sample-identical to the same tune played without any effects. The
game, its register writes and its timing are untouched.

### Sound character - Audio › Sound character
- **Synthesis:** *Legacy* (default, the original output) or *Band-limited (BLEP)*: every sample step is rendered as
  a band-limited step, which removes the metallic aliasing of high notes and synth effects (most audible with the A500
  filter off). Adds 0.5 ms of delay.
- **Ambience:** reverb on the **sound effects only** (the music stays dry). *Automatic* follows the area you are in:
  jungle / village / final jungle (open air), hut (small room), tunnels (echoing), the flare night (wide and far),
  the bunker (concrete); title, loading and text screens stay dry. Fixed presets are available too, plus an amount
  slider.

### Replacement soundtrack - Audio › Music, or Sound › Replacement Soundtrack
Plays your own audio files instead of the game's tunes (nothing is included). Put files into the soundtrack folder
(default `~/Library/Application Support/Platoon/Soundtrack`, *Choose Folder…* / *Show Folder in Finder*), named by
tune: `song0` … `song6` (or `tune0` … `tune6`), a leading number (`2 - Jungle.m4a`), or a name:

| tune | when | names |
|---|---|---|
| 0 | title | `title` |
| 1 | high-score entry | `hiscore`, `hiscores`, `highscore` |
| 2 | jungle & village | `jungle`, `village`, `section0` |
| 3 | LOADING / message screens (plays once) | `loading`, `intro`, `message` |
| 4 | tunnels | `tunnels`, `tunnel`, `section1` |
| 5 | final jungle | `finaljungle`, `foxhole`, `section2` |
| 6 | flare night | `flare`, `night`, `bunker` |

Formats: m4a, mp3, wav, aiff / aif, caf, flac, aac, mp4. Tunes without a file play as usual. Sound effects are
unchanged, F10 (music off) stops the file, the GAME OVER fade fades it, pausing pauses it; *Music volume* and the
main volume apply.

### Output timing - Audio › Output timing
- **Buffer control:** *Original* (default) drops whole blocks when the buffer runs ahead. *Smooth* keeps the buffer at
  the latency target by resampling up to ±0.5 % instead (PI control, so a constant clock difference is absorbed and
  the latency stays at the target), so clock drift, variable-refresh displays and host hiccups don't click, underruns
  recover cleanly and catch-up bursts never let the latency grow beyond 4x the target. If the game ever runs slower
  than real time, the sound follows it at a lower pitch instead of stuttering (Smooth is switched on automatically
  while a slower game speed is active). Fast-forward is unaffected (quieter real-time sound). Short host hitches are not mistaken
  for slow motion. On an overloaded Mac that emulates only 90-99 % of real time, Smooth notices the repeated
  underruns (two within 6 s) and follows the game's real speed until it is back above 99 %, instead of
  re-buffering every second or so.
- **Latency:** 20 / 40 / 60 (default) / 100 / 150 ms.
- The audio engine restarts by itself when the output device changes (headphones, AirPlay, sample rate).
- *Log audio diagnostics* prints buffer fill, ratio and underruns to the Console every 2 s (after relaunch).

Faster key-event delivery is in General › Keyboard.

---

## Assists: message log, captions, objectives, timer, replays, practice, difficulty page
Everything in this section reads the game and draws on top of it, except practice drills (which load a prepared
game). None of it is ever drawn into the game picture, screenshots or recordings. Switch things on in
**Preferences › Assist** (⌘,) or from the **Assist** menu; most rows also have a menu toggle there.

### Message log and captions
The game shows its clues as a one-line message that fades after a second, and silently drops a message when four
are waiting.
- **Message Log** (Assist menu ⌥⌘L, or the pause menu): every HUD message of the current game with its game time.
  Messages the game re-queues constantly (the trap-door question, "PLEASE DON'T ATTEMPT SUICIDE!!", the hint timer)
  are folded into one line with a count. Messages the game **dropped** (never shown) are marked "not shown".
  ↑↓ / Page Up / Page Down scroll, **C** copies the log, Esc closes it; on a controller the d-pad scrolls and Ⓑ closes.
  The game is paused while the log is open. "Copy Message Log" in the Assist menu copies it without opening it.
- **Large captions** (default off): the current HUD message in big yellow-on-black text below the picture (or at the
  bottom / top of the picture). "Keep each caption at least" (default 2.5 s) keeps messages readable that the game
  replaces after a single tick: a message that follows sooner waits until the current caption has had its time (only
  the newest one waits, so a caption is never more than one hold time behind the game). Messages the game dropped
  are never captioned (they are in the log).
- **Read messages aloud** (default off): every new message, and optionally the full-screen texts (section intros,
  ONE MORE CHANCE, the endings), spoken in sentence case ("DID'NT" becomes "didn't", "(Y/N)" becomes "Y or N").
  With VoiceOver running the text goes to VoiceOver instead. Nothing is spoken while fast-forwarding.

### Objectives, briefings and the numeric HUD
- **Show objectives** (default off): a checklist of the current section beside the picture (left bar) or on it.
  Detail: *Goals only* ("Find the explosives"), *Goals + hints* (where to look), or *Full solution* (exact
  places, room numbers, the final-jungle route L R L R L R L R R L R L R L). The solution tier marks the game as
  assisted while it is shown. Progress is read from the game: explosives, bridge, village, torch, map (optional),
  trap door; flares (x/8), compass and map (optional), exit; flares fired in the flare night; bunker, Barnes' hits,
  the door. With the village or tunnel randomiser on, location hints are left out.
- **Briefing when a section loads** (default off): a mission card over LOADING / ENTERING THE COMBAT ZONE. The game's
  own waiting time is not changed; click it to hide it, it also goes 4 s after play starts.
- **Numeric HUD** (default off): morale in %, the current soldier's wounds, ammunition and grenades, flares, the
  timer, Barnes' remaining hits and the whole platoon (● fit … ✕ dead), beside the picture (right bar) or on it.
- When a difficulty preset other than Original is chosen, **DIFFICULTY: RECRUIT** (etc.) is shown on the ENTERING
  THE COMBAT ZONE screen.

### Speedrun timer and Service Record
- **Show the speedrun timer** (default off): run time from the start of a game in game frames (50 per second),
  without TAB pauses; host pauses and fast-forward don't change it. **Splits**: explosives, bridge, village, torch,
  map, trap door, 8 flares, tunnel exit, dawn, bunker, Barnes, Huey, with the difference to your personal best
  (green ahead, red behind; always against the PB you had when the run started) and the next PB split. Personal bests and best segments are kept per category:
  `original`, `recruit` / `veteran` / `custom`, `assisted`, and `@1` / `@2` for games started at a later section.
- **Service Record** (Assist menu ⇧⌥⌘R; recording on by default, "Announce medals" off): games started / won / lost,
  time in action, enemies killed, wounds, soldiers lost, sections completed, best score and fastest win per table,
  your speedrun PBs (Copy Splits, or **Export LiveSplit…**: one `.lss` splits file per category, in game time, with
  your gold segments), and ten medals: Mission Complete, Veteran, Band of Brothers (trap door with all
  five men), Tunnel Rat (tunnel exit without a map), Night Owl (flare night without a hit), Five for Five (Barnes
  without wasting a grenade), Beat the Clock (win with ≥ 1:00 left), Nobody Left Behind, Scholar (the history book
  in the tunnels), Don't Do It. Medals are not awarded in assisted games; practice drills and replays don't count.
  Stored in `~/Library/Application Support/Platoon/service-record.json` and `speedrun.json`.

### Replays
The port is deterministic: the joystick and keys of a game reproduce it exactly.
- **Record the current game** (default on) keeps the input since the last reset in memory (a few KB).
- **Assist › Replays › Save Replay of This Game…** (⌥⌘S) writes a `.plreplay` file. **Play Replay…** (⌥⌘O) plays one:
  the game restarts with the recorded settings (difficulty and other options, cheats, start section) and your own
  input is ignored. You can pause, open the pause menu and fast-forward; **Stop Replay (take over)** (Replays menu or
  pause menu) hands you the controls at that moment, and the recording carries on, so saving afterwards gives a
  replay of both parts. A replayed game is marked assisted and never writes a high score, and neither a replay nor a
  practice drill moves your Game ▸ Continue from Last Section point.
- The last finished game and your best-scoring game are kept automatically (`Play Last Game`, `Play Best Game`;
  files in `~/Library/Application Support/Platoon/replays/`).
- Loading a save state, retrying a checkpoint or rewinding ends the recording (the game can no longer be replayed
  from its start); switching a cheat during a game does too.
- A plain `platoon-headless --script` file (joystick and key lines, no pokes) can be played with Play Replay… too;
  its keys are paced like the headless runner's, so a key press and release on the same frame still register.
- A `.plreplay` is also a `platoon-headless --script`; its header lists the command line, e.g.
  `platoon-headless --adf ADF --script game.plreplay --frames 51234 --start-section 1 --enh referenceEmulator=0`
  (the headless runner defaults to the reference emulator's timing, so the command states the replay's timing). A carry
  block, if any, is saved next to it as `.carry` (use `PLATOON_CARRY=file`). Replays made from headless
  `--deterministic` runs carry a `# deterministic 1` header line; the app then plays them with the same random-number
  rule.
- Replays are recorded at real-A500 speed (`# PLATOON INPUT REPLAY 2`). Replays saved by earlier versions (format 1)
  and plain headless scripts were made with the reference emulator's faster timing: they are played with
  `referenceEmulator=1`, so they still reproduce their game.

### Practice
**Assist › Practice** (or "Practice…" in the pause menu) starts a drill: The Jungle (from the start), The Bridge (with
the explosives, before the bridge), The Village (the street: torch, map, trap door), The Tunnels (entrance), The
Flare Night (in the foxhole with 8 flares), The Final Jungle (start) and Sgt Barnes (at the bunker).
- The first time, a drill is prepared from recorded play in the background ("preparing… %", up to a minute for the
  village); after that it starts at once (cached in `Application Support/Platoon/practice/`).
- Drills that start mid-section (bridge, village, Barnes) begin with the soldiers' wounds healed, so a single hit
  doesn't end the attempt at once; ammunition, grenades, morale and score are as the recorded play left them.
- A badge shows the drill, the attempt number, the time and your best time. When a soldier dies (option "Restart the
  drill when a soldier dies", on) or the game is over, the drill restarts after a moment. Reaching the goal (bridge
  blown, trap door, tunnel exit, dawn, bunker, the Huey) shows the time and keeps the best one.
- **Restart Drill** ⌥⌘P (Practice menu / pause menu), **Stop Practice** keeps playing from where you are.
- Practice games are marked assisted ("Practice: …") and never enter the original high-score table.

### Gameplay page: difficulty and platoon
Preferences › **Gameplay** starts with:
- **Difficulty**: Original / Recruit / Veteran / Custom. Below the popup, a live list shows exactly what the chosen
  preset changes, with the original values (e.g. "Jungle: morale lost per hit: $400 (original $800)").
- **Custom difficulty** sections (all sections, jungle, tunnels, final jungle): every difficulty knob with a short
  title and a description of what it changes. A knob set here overrides the preset; with Custom only these apply.
- **Platoon**: soldiers in the tunnels and the final jungle (2 = original, up to all 5) and *Full platoon* (wounds,
  ammunition and fallen men carry over from the jungle).
All of these are gameplay options (applied when a new game starts): Recruit / Veteran / Custom games rank in their
own high-score tables, other combinations in the assisted table.

---

## Jungle & village: failsafes, fixes, map, widescreen
Everything here is off by default. Options marked **gameplay** make the game *assisted* (separate hiscore table).
Options (`s0.*`) are set in Preferences › Gameplay › "Jungle & village" / "Jungle & village: original bugs",
with `--enh key=value` on the headless runner or `PLATOON_ENH`; they take effect when a new game starts.

### Rules (gameplay)
| Option | Preferences row | What it does |
|---|---|---|
| `s0.bridgeFailsafe=1` | Bridge failsafe | Walking right towards the bridge without having planted the explosives stops you at the last column before the point of no return, with "SET THE EXPLOSIVES ON THE BRIDGE", instead of freezing you while a runner wipes out the whole platoon. With the explosives nothing changes (they are planted automatically on the bridge). |
| `s0.forgivingTraps=1` | Forgiving booby traps | Tripwires and the two booby-trapped drawers (huts 0 and 4) count as a normal hit: one wound and the usual morale loss, instead of killing the soldier outright. |
| `s0.explicitJumpCrouch=1` | Separate jump and crouch controls | Jump and crouch get their own controls (bind "Jump" / "Crouch" in Controls & Bindings; headless: Amiga keys `s0.jumpKey=0x32` / `s0.crouchKey=0x33`). Up and down then only take the paths between the jungle strips and the hut doors, so you can no longer walk onto a path by accident instead of jumping a tripwire. You can also jump on path tiles and in front of doors. |
| `s0.villageSeed=N` | Village randomiser: off / new village at every reset / fixed village (seed) | The torch, the map and both booby traps move to other search spots in the huts (seeded: the same seed gives the same village). The map still needs the hut-2 guard dead. A toast shows the seed when the jungle starts. |

### Original bug fixes - gameplay, one switch each
| Option | Fix |
|---|---|
| `s0.fixMoraleWrap=1` | Morale from supply crates, the torch and the map stops at full instead of wrapping round to almost nothing. |
| `s0.fixHutDummy=1` | The invisible "enemy" in the trap-door hut (hut 1) can't be shot: in the original it gave 300 points and counted as killing the hut-2 guard, so the map could be taken without a fight. |
| `s0.fixTripwireSpawn=1` | Tripwires always appear at the screen edge ahead of you (with some scroll positions the original put them behind you). |
| `s0.fixTrapdoorBonus=1` | The trap-door bonus (1000 per living soldier) counts your five soldiers; the original counts five records from the soldier in control, so with soldier 2-5 it counts game variables as soldiers. |

### Difficulty - gameplay
Recruit / Veteran set these; Custom uses only the ones you set (`original` = the game's value). Rows appear
automatically in Preferences › Gameplay.
| Key | Original | Recruit | Veteran | Meaning |
|---|---|---|---|---|
| `s0.diff.shootMask` | $1f | $3f | $0f | a walking soldier tries to shoot when random & mask = 0 (bigger = fewer shots) |
| `s0.diff.hitMorale` | $800 | $400 | $c00 | morale lost per wound |
| `s0.diff.villagerMorale` | $1200 | $900 | $1b00 | morale lost for shooting a villager |
| `s0.diff.grenades` | 9 | 9 | 6 | grenades per soldier |
| `s0.diff.ammo` | $90 | $90 | $60 | rounds per soldier (crates still refill up to $90) |
| `s0.diff.spawnFloor` | 7 | 4 | 12 | lowest enemy spawn chance per tick (out of 256) |
| `s0.diff.rifleKillsSpider` | 0 | 1 | 0 | 1 = rifle bullets kill the spider-hole VC (originally grenades only) |
| `s0.diff.trapsWound` | 0 | 1 | 0 | same as `s0.forgivingTraps` |
| `s0.diff.bridgeFailsafe` | 0 | 1 | 0 | same as `s0.bridgeFailsafe` |
| `s0.diff.noMap` | 0 | 0 | 0 | Custom challenge: the tunnel map in hut 2 can't be found |
(Starting morale is `kernel.diff.startMorale`.) Extra soldiers (`game.lives` / `game.fullPlatoon`)
need nothing in the jungle: all five soldiers play here anyway, and with `game.fullPlatoon` the platoon you leave
the jungle with (wounds, ammunition, dead men) is what the tunnels get.

### Jungle map - Preferences › Assist › Jungle map, or Assist › Show the Jungle Map
- A schematic of the six jungle strips beside the game: level 0 at the top (the village street is its
  right half), level 1 is where you start, levels 2-4 lie deeper. Dark green = trees you can't walk through,
  yellow lines = paths between the strips, blue = the river, brown = the bridge planks, small houses = hut doors.
  The green arrow is you (white inside a hut).
- **Position**: below the game, above it, or at the top of the game image.
- **Show**: layout only / + objectives (E = explosives on level 4, B = the bridge, ✕ = the point of no return
  without explosives) / + hut contents (spoiler: torch, map, booby traps - listed per hut, with "sprung" once they
  went off; marks the run as assisted).
- **Only what you have explored**: columns appear once you have been near them; kept after deaths and loaded
  games, cleared when the jungle starts in a new game.
- **M** in the jungle hides / shows it; the pause menu has "Show / Hide Jungle Map". Size 2-8 points per column.
- **Warn about booby-trapped drawers** (same section): inside a hut, "Something doesn't feel right here…" appears
  while you stand at a drawer that is still booby-trapped. Marks the run as assisted when it appears.

### Widescreen jungle - Preferences › Video › Widescreen jungle, or View › Widescreen Jungle
In a window wider than the game (or full screen), the jungle scenery continues into the black side bars: the
same trees, paths and river, scrolling exactly with the picture (up to 256 px per side, optionally fading towards
the edges). Background only - enemies, bullets and you exist only in the middle, and the HUD keeps its width.
Hidden during transitions and man select, inside the huts and in the other sections. The columns are drawn by the
game renderer (same scale, screen shake, over the backdrop), but never appear in ⌘S screenshots.
**Make room in narrow windows** (0-128 px per side) shrinks the picture so the columns also show in a 4:3 window.
It lets you see a little further ahead, so it is off by default (it does not change the game itself).

---

## Tunnels & flare night: map, fairness, fixes
Everything here is off by default. Options marked **gameplay** make the game *assisted* (separate hiscore table).
Options (`s1.*`) are set in Preferences › Gameplay ("Tunnels & flare night" and "Tunnels & flare night: original bugs"),
with `--enh key=value` on the headless runner or `PLATOON_ENH`; they take effect when a new game starts.

### Tunnel map - Preferences › Assist › Tunnel map, or Assist › Show the tunnel map
- A map of the 43x43 maze beside the game (or in the game's top-right corner if the window is narrow). It fills in
  as you explore: the corridors, rooms and walls you could see from where you stood. A green arrow shows where you
  are and which way you face; the blue dot is the entrance.
- Rooms get their number when you enter them. The list below the map shows what you took in each room (flares,
  compass, map, ammunition, medical supplies, with a tick) and the doors you tried: "blocked exit", or
  "EXIT (8 flares)" for the real way out (its room number turns red). Nothing you have not found yet is listed.
- What you explored is kept when a soldier dies, after loading a save and after rewinding; it is cleared when the
  tunnels start in a new game.
- **M** in the tunnels hides / shows it. The pause menu has "Show / Hide Tunnel Map".
- Options: size (3-10 points per cell), position, room list on/off, **Reveal the whole maze** (spoiler: all
  corridors and the contents of every room; marks the run as assisted). The plain map only shows what you saw, so
  it does not mark the run.
- `s1.exploredMap=1` (**gameplay**; Gameplay row "The game's map window shows what you explored"): in the game
  itself the map window is always open and draws the cells you have seen, even without the map item (the tunnel plan still reveals everything when you find it).

### Fairness - gameplay
| Option | What it does |
|---|---|
| `s1.keepItems=1` (Keep items when a soldier dies) | When a soldier dies the next one keeps the flares, the compass, a map found in the tunnels and the emptied drawers (the original takes everything away and refills the rooms). If you die in the flare night you get back the flares you took into it, so the exit still opens. |
| `s1.flareRetry=1` (Flare night: retry with the next soldier) | Dying in the flare night restarts the flare night with the next soldier and the flares you brought, instead of sending him back through the whole maze. |
| `s1.checkpointRespawn=1` (Next soldier starts at the last room) | The next soldier starts in front of the last room you entered (facing away from it) instead of at the entrance. |

### More soldiers (`game.lives`, `game.fullPlatoon`) - gameplay
- `game.lives=3..5`: after the second soldier the third (up to the fifth) takes over, each after its own
  "ONE MORE CHANCE" screen.
- `game.fullPlatoon=1`: the tunnels keep the platoon you brought from the jungle (wounds, ammunition, dead men)
  and start with your first living man; every living man gets his turn.

### Original bug fixes - gameplay, one switch each
| Option | Fix |
|---|---|
| `s1.fixLastBullet=1` (Your last bullet can kill) | Your last bullet can kill (the original checks the ammunition after the shot has used it). Tunnels and flare night. |
| `s1.fixMoraleWrap=1` (Morale from room items stops at full) | Morale from room items stops at the maximum instead of wrapping round to almost nothing. |
| `s1.fixFoodFarm=1` (Rotten food scores once) | The rotten food gives its 500 points once per soldier, not on every click. |
| `s1.fixFlareSpawn=1` (Flare night: enemies keep coming) | Heavy firing in the flare night can no longer switch the enemy spawns off for good. |

### Difficulty - gameplay
Recruit / Veteran set these; Custom uses only the ones you set (`original` = the game's value):
| Key | Original | Recruit | Veteran | Meaning |
|---|---|---|---|---|
| `s1.diff.hitMorale` | $c00 | $800 | $1000 | morale lost per wound (tunnels and flare night) |
| `s1.diff.spawnDelay` | $10 | $20 | $08 | minimum ticks between tunnel enemies (plus 0-$31 random) |
| `s1.diff.enemyAim` | $f | $19 | $0b | ticks a corridor enemy aims before firing |
| `s1.diff.itemMorale` | $200 | $300 | $100 | morale gained per useful room item |
| `s1.diff.flareSpawnBase` | $90 | $c0 | $70 | flare night enemy interval (bigger = fewer enemies) |
| `s1.diff.flareShotSlack` | $d | 5 | $f | flare night: smaller = more time before a firing enemy hits you |

### Mouse / pointer aiming - gameplay `s1.directAim=1` ("Pointer aiming moves the crosshair directly")
With the option on and a pointer target coming from the input settings (mouse aiming), the crosshair in tunnel
fights, in the room search and in the flare night jumps straight to the pointer (within the original limits);
fire, recoil and hit rules are unchanged. Without the option the input settings can still steer the crosshair
by moving the stick for you (assisted aiming, not gameplay).

### Randomiser - gameplay `s1.randomSeed=N` (1 and up; 0 = off)
Preferences › Gameplay › Tunnels & flare night › "Tunnel randomiser": off / new tunnels at every reset / fixed
tunnels (seed). Shuffles what lies behind each hotspot between rooms of the same kind: the flare boxes, compass,
maps, ammunition and so on move to other rooms that look alike, and the real EXIT is behind the door of either ladder room. The
same seed always gives the same tunnels. Use the tunnel map to keep track.

### Turn slide - Preferences › Video › Tunnels
"Slide the view when turning": when you turn left or right in a corridor the old view slides out and the new one
in over a few frames. Presentation only (the game, screenshots and recordings are not changed).

---

## Final jungle & foxhole: navigator, room slide, fixes
Everything here is off by default. Options marked **gameplay** make the game *assisted* (separate hiscore table).
Options (`s2.*`) are set in Preferences › Gameplay ("Final jungle & foxhole: original bugs", the difficulty
knobs) and Preferences › Assist (compass assist) or with `--enh key=value`
on the headless runner / `PLATOON_ENH`; they take effect when a new game starts. The navigator and the room slide
are display features in the app and can be switched at any time.

### Final-jungle navigator - Preferences › Assist › Final jungle navigator, or Assist › Final Jungle Navigator
The last section is a 10x12 grid of look-alike rooms whose exits are "left" and "right" relative to the way you
face, with a 2:00 napalm timer. The navigator is a small panel beside the game (or in the playfield's top-right
corner when the window is narrow; "Position" chooses). It never appears in screenshots or recordings.
| Level | Shows |
|---|---|
| Heading | the way you face (N/E/S/W, north = up on the map) and which side(s) this room can be left by, even without the compass (without the compass from the tunnels this **marks the run as assisted**, like `s2.compassAssist`; with it, the panel only repeats the HUD) |
| Heading + map | also a map of the rooms you have been in this game (green, the bunker red), where you are and which way you face; the start room is outlined. Rooms you have not entered stay blank (no spoiler) |
| Heading + map + route guide | also "Go ◀ LEFT" / "Go RIGHT ▶" towards the nearest bunker and how many rooms are left, "Walk up to the far end first" (the side exits only work at the back of the room), and in the bunker Barnes' remaining grenade hits. **Marks the run as assisted** |

- ⇧⌘J cycles the levels; **N** in the final jungle hides / shows the panel while the navigator is on; the pause menu
  has "Show / Hide Final Jungle Navigator".
- The route is a shortest path over (room, heading) computed with the game's own turning rules, checked against the
  reverse-engineered maze graph (from the start: L R L R L R L R R L R L R L, 14 rooms).
- `s2.compassAssist=1` (**gameplay**, Preferences row "Start with the compass (HUD heading)"): the final jungle starts
  with the compass, so the game's own HUD shows the heading and the first hint becomes "GET GOING!" instead of
  "A COMPASS WOULD HELP !".

### Room slide - Preferences › Video › Final jungle, or View › Final Jungle Room Slide
Instead of the fade to black between rooms, the old view slides out to the side you turned to and the next room
slides in edge to edge ("Slide length" 6-16 frames, default 12). The game underneath fades and decodes exactly as
before; the slide ends before the game shows the new room and holds it, then the game's own picture takes over on
the first frame it shows the room (pixel-identical apart from what moved; never a black frame). Presentation only;
it is not in screenshots or recordings.

### More soldiers (`game.lives`, `game.fullPlatoon`) - gameplay
- `game.lives=3..5`: when a soldier dies the next one takes over with "ONE MORE CHANCE" and a fresh 2:00 at the start
  room, until the last of them is killed ("YOUR PLATOON HAS BEEN DESTROYED!"). The original allows two.
- `game.fullPlatoon=1`: the final jungle keeps the platoon you brought (wounds, grenades, ammunition, dead men)
  instead of five fresh soldiers; it starts with your first living man and every living man gets his turn
  (`s2.diff.grenades` then does not apply).

### Original bug fixes - one switch each
| Option | Fix |
|---|---|
| `s2.fixRoomTimer=1` (**gameplay**) | The airstrike timer pauses while the screen is black between rooms, as the programmer intended (the original clears the wrong address). Worth about 5 s over the shortest route. |
| `s2.napalmStopsTimer=1` | When time is up the HUD timer stays at 00:00 instead of wrapping to 59:59 during the napalm flash. |
| `s2.withdrawnText=1` | Running out of morale shows the intended "YOUR PLATOON HAS WITHDRAWN FROM ACTION" screen instead of "YOUR PLATOON HAS BEEN DESTROYED!". |
| `kernel.timerStopsAtZero=1` | (all sections, row "HUD timer never wraps to 59:59") The kernel's mission timer stops at 00:00 instead of wrapping when it runs out. |
| `s2.fixPhantomGrenades=1` | Once Barnes is dead your remaining grenades are no longer thrown one after another by themselves. |

### Difficulty - gameplay
Recruit / Veteran set these; Custom uses only the ones you set (`original` = the game's value):
| Key | Original | Recruit | Veteran | Meaning |
|---|---|---|---|---|
| `s2.diff.timer` | 120 | 180 | 90 | airstrike timer in seconds at every (re)start of the final jungle |
| `s2.diff.maxSoldiers` | 5 | 3 | 5 | at most this many soldiers per room visit (the game draws 0-5 at random) |
| `s2.diff.spawnDelay` | $14 | $14 | $0c | minimum ticks between soldiers entering (+0-15 random) |
| `s2.diff.fireCooldown` | $14 | $20 | $0e | minimum ticks between soldier shots (+0-15 random) |
| `s2.diff.sniperDelay` | 50 | 80 | 35 | ticks you may stand at one depth before the sniper shoots (twice that after entering a room or a hit) |
| `s2.diff.hitMorale` | $800 | $400 | $c00 | morale lost per hit |
| `s2.diff.barnesHits` | 5 | 3 | 7 | grenade hits that kill Barnes |
| `s2.diff.barnesCooldown` | $0a | $18 | $06 | minimum ticks between Barnes' shots (+0-15 random) |
| `s2.diff.grenades` | 9 | 9 | 9 | grenades per man at the start of the final jungle |

The random draws stay exactly where the original makes them; only the resulting numbers are bounded or offset.

---

## Cheats: the original developer cheats and extra ones
**Preferences ▸ Cheats** (or **Game ▸ Cheats**). Every cheat is off by default and takes effect at once, in the
middle of a game too. **Enable All Cheats** / **Disable All Cheats** (top of the tab, and in the menu) switch every
switch of this chapter together. A game in which any cheat was on, even for a moment, is **assisted**: its score
goes to `hiscores-assisted.bin`, never to the original table. Switching every cheat off makes the next new game an
ordinary one again.

### Original developer cheats - `cheat.original`
The game has cheats of its own: type `HAMBURGER` on a title screen ("CHEAT!!!" appears on the credits page), then
`KEYPAD-` `H I L L` ("MEGA CHEAT"). The switch **Original developer cheats (CHEAT!!! + MEGA CHEAT)** does exactly
what typing both does (the credits page shows MEGA CHEAT), without typing. Switching it off again
undoes it (also codes you typed by hand). What the codes unlock, and where (the keys only work in these places;
the Cheats tab buttons, the Game ▸ Cheats items and the pause-menu **Cheat:** rows press them for you and are greyed
out / left out elsewhere):

| Where | Key | What it does |
|---|---|---|
| Jungle & village | **F1** | *Warp to the start*: the jungle restarts at its start (level 1, column 5). |
| | **F2** | *Warp near the explosives*: restart on the rear path (level 4, column 45), just before the box of explosives. |
| | **F3** | *Warp to the bridge*: restart on the river path (level 1, column 65), in front of the bridge. |
| | **F4** | *Warp to the village*: restart in the village street (level 0, column 65). |
| | **F5** / **F6** | The developers' own invincibility on / off (jungle and village only; "CHEAT!" is shown while it is on). |
| Tunnels | **HELP** | *Skip to the flare night*: "LET'S GO TO THE FLARE SCREEN!", with 9 flares. |
| Flare night | **HELP** | *Survive the night*: "WELL DONE, YOU MADE IT THROUGH THE NIGHT", on to the final jungle. |
| Final jungle & bunker | **CAPS LOCK** | *Win the game*: "YOU MADE IT! A HUEY IS ON IT'S WAY…", then the usual game over and high score. |

The jungle keys need either code, the others MEGA CHEAT. Every warp re-equips all five soldiers (the original's
restart). The keys are held for a few frames, so they also work with *Faster key response*.

### Extra cheats
| Switch (key) | What it does |
|---|---|
| **Invincibility** (`cheat.invincible`) | Nothing can hurt you in any section: enemy bullets, knives and bodily contact, the hut guard, snipers, tripwires and the booby-trapped drawers (they still go off), the tunnel, room-guard and water enemies (their shot misses), the flare-night enemies (they keep shooting, harmlessly, and can still be shot), mines (they still explode), barbed wire (it still blocks you) and Barnes. No wound, no morale loss, no *CHOOSE YOUR MAN* interruption. In the jungle it also stops you before the bridge while the explosives are not planted, like the *Bridge failsafe*: otherwise you would stand frozen at the bridge for ever, because the runner's shot that normally ends it can't hurt you. The napalm strike at 0:00 is not an attack and still comes: use *Freeze the airstrike timer*. |
| **Infinite ammunition** (`cheat.infiniteAmmo`) | Firing never uses rounds (jungle, tunnels, flare night, final jungle). |
| **Infinite grenades** (`cheat.infiniteGrenades`) | Throwing never uses grenades (jungle; final jungle and the bunker). |
| **Infinite flares** (`cheat.infiniteFlares`) | In the tunnels you always carry the 8 flares the exit asks for (the most the boxes of flares give), so the exit lets you through. In the flare night the flares count down to dawn - the night is survived when the last one burns out - so they are used up there as usual (with endless flares the night would never end). |
| **Infinite morale** (`cheat.infiniteMorale`) | Morale never drops: no loss per hit or per villager, and the jungle's slow drain stops. |
| **Freeze the airstrike timer** (`cheat.freezeTimer`) | The final jungle's two-minute countdown to the napalm strike stands still. |
| **Infinite soldiers** (`cheat.infiniteMen`) | The platoon can't be wiped out: when your last soldier is killed he is patched up (no wounds) and carries on - in the tunnels and the final jungle through the section's usual "one more chance" restart. Morale at zero still ends the game (add *Infinite morale*), and so does walking past the unmined bridge (the whole platoon is shot; add *Invincibility*). |

Command line / environment: `platoon-headless --enh cheat.invincible=1,cheat.infiniteAmmo=1` or
`PLATOON_ENH=cheat.original=1`; the legacy keys `infiniteAmmo` / `infiniteMorale` are aliases of the
`cheat.` ones.

---

## Game options, difficulty presets, command line
The translated game reads its options from one registry of `key=value` settings (the rows of Preferences map onto
them). This chapter lists the game-wide ones and how to set any option outside the app.

### Where options are switched on
- **App:** Preferences (⌘,): every option has a row (mostly the Gameplay tab; the rows of this chapter are in
  General ▸ Title screen and high scores, Input ▸ High-score name, Video ▸ Accessibility, Audio ▸ Music / sound FX
  at power-on and the Final-jungle bug list). Options are read when a game starts, so use **Reset Game Now** after
  changing one.
- **Command line (headless runner):** `platoon-headless --enh key=value[,key=value]` (repeatable);
  `platoon-headless --enh list` prints every option with its default and help text.
- **Environment:** `PLATOON_ENH="key=value,key=value"` works for the app and the headless runner.

Values: `1`/`0` (also on/off, true/false) for switches, numbers in decimal or hex (`0x4800`, `$4800`), `original`
for "use the game's own value".

### Difficulty presets (`difficulty`) - gameplay
`difficulty=original` (default, the real game), `recruit`, `veteran`, or `custom`. Recruit and Veteran adjust a set
of per-section values (enemy fire, wounds, timers, ...; the tables are in the jungle, tunnels and final-jungle chapters).
Custom uses only the values you set yourself (keys ending in `.diff.<name>`). The core value is:
- `kernel.diff.startMorale` - morale at the start of a new game (the original is `$9000`; Recruit `$c000`,
  Veteran `$6c00`; "half morale" is `$4800`).

### Extra soldiers (`game.lives`, `game.fullPlatoon`) - gameplay
- `game.lives=2..5` - how many soldiers you get in the tunnels and the final jungle (the original gives you 2).
- `game.fullPlatoon=1` - the platoon you kept alive in the jungle (wounds, ammunition, fallen men) carries over into
  the later sections; each section then starts with your first living man.
(How each section uses them: see the tunnels and final-jungle chapters. Preferences › Gameplay › Platoon.)

### Other game options (not gameplay)
| Option | What it does |
|---|---|
| `originalCredits` (default **on**; General ▸ Title screen and high scores) | The credits page shows the original "GAME DESIGN (C)1988 OCEAN." / "CONVERSION BY CHOICE" lines instead of the cracker's text on the disk image. |
| `kernel.soundFlagsAtBoot=0..3` (Audio ▸ Music / sound FX at power-on) | Music/FX mode at power-on (what F10 cycles through): 0 = all off, 1 = music only, 2 = sound effects only, 3 = both (the original). The app uses this to remember your last F10 choice. |
| `kernel.steadyPauseColour=1` (Video ▸ Accessibility) | The TAB pause no longer makes the background flash. |
| `kernel.keyboardNameEntry=1` (Input ▸ High-score name) | Type your hiscore name on the keyboard: letters, digits, space; Backspace goes back one letter; Return finishes the name. The joystick still works as before. |
| `kernel.timerStopsAtZero=1` (Gameplay ▸ Final jungle & foxhole: original bugs, "HUD timer never wraps") | The mission timer stops at 00:00 instead of jumping to 59:59 while the napalm strike plays (a cosmetic original bug). |
| `kernel.separateCheatScores=1` (General ▸ Title screen and high scores) | Games in which the original cheat codes (HAMBURGER / MEGA CHEAT) were typed also go to the assisted hiscore table. |
| `referenceEmulator=1` (`kernel.referenceEmulator`; command line / `PLATOON_ENH` only, for verification) | The timing and Paula of the reference emulator `tools/amiga/emu` instead of a real A500: the CPU gets every bus cycle and blits take no time (the jungle then runs at 25 ticks per second instead of ~18, the final jungle at 50 instead of ~25), no audio DMA limit, no LED filter, a 4.9 kHz output filter. The regression and audio tests use it, and `platoon-headless` defaults to it; see [verify/timing.md](verify/timing.md). |

### Hiscores and assisted runs
See [Assisted games and high scores](#assisted-games-and-high-scores). Name entry in a separate table works as
usual and your usual name is pre-filled; the title screen keeps showing the original table. On the command line,
`platoon-headless --enh list` marks the gameplay options (the ones that make a game assisted) with `*`.

### Command-line examples
`platoon-headless` is the command-line runner used for testing (see [PORTING.md](PORTING.md)). The audio options,
for example, mirror the mixer: `audio.ghostVoices=1`, `audio.synthesis=blep`, `audio.musicVolume=0.5`,
`audio.sfxVolume=1.5`, `audio.pan0..pan3=-1..1`, `audio.ambience=off|auto|jungle|hut|tunnels|night|bunker` (auto
needs the event probe, e.g. `PLATOON_EVENTS=/dev/null`), `audio.ambienceLevel=1`:
`platoon-headless --enh audio.ghostVoices=1,audio.synthesis=blep --script s.txt --frames 3000 --wav out.wav`.

