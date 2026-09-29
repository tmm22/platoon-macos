# Platoon: enhancements guide

Everything described here is optional. With every option at its default you play the original 1988 game, byte for
byte (checked by `tools/regress_all.sh`). Options that change what the game does are marked **gameplay**: a game
played with any of them is an *assisted* run and its score goes to a separate hiscore table (see "Hiscores" below).

Each feature owner has one section in this file and edits only that section.

---

## Core: options, hiscores, kernel extras (owner: core)

### Where options are switched on
- **App:** Preferences (⌘,): every option listed below has a row (Gameplay / Audio / Assist tabs). Options are read
  when a game starts, so use "Restart now" after changing one.
- **Command line (headless runner):** `platoon-headless --enh key=value[,key=value]` (repeatable);
  `platoon-headless --enh list` prints every option with its default and help text.
- **Environment:** `PLATOON_ENH="key=value,key=value"` works for the app and the headless runner.

Values: `1`/`0` (also on/off, true/false) for switches, numbers in decimal or hex (`0x4800`, `$4800`), `original`
for "use the game's own value".

### Difficulty presets (`difficulty`) - gameplay
`difficulty=original` (default, the real game), `recruit`, `veteran`, or `custom`. Recruit and Veteran adjust a set
of per-section values (enemy fire, wounds, timers, ...: filled in by each section owner, see their sections).
Custom uses only the values you set yourself (keys ending in `.diff.<name>`). The core value is:
- `kernel.diff.startMorale` - morale at the start of a new game (the original is `$9000`; Recruit `$c000`,
  Veteran `$6c00`; "half morale" is `$4800`).

### Extra soldiers (`game.lives`, `game.fullPlatoon`) - gameplay
- `game.lives=2..5` - how many soldiers you get in the tunnels and the final jungle (the original gives you 2).
- `game.fullPlatoon=1` - the platoon you kept alive in the jungle (wounds, ammunition, fallen men) carries over into
  the later sections; each section then starts with your first living man.
(The section owners implement these in their sections; see their notes for what is available.)

### Kernel extras (presentational, not gameplay)
| Option | What it does |
|---|---|
| `originalCredits` (default **on**) | The credits page shows the original "GAME DESIGN (C)1988 OCEAN." / "CONVERSION BY CHOICE" lines instead of the cracker's text on the disk image. |
| `kernel.soundFlagsAtBoot=0..3` | Music/FX mode at power-on (what F10 cycles through): 0 = all off, 1 = music only, 2 = sound effects only, 3 = both (the original). The app uses this to remember your last F10 choice. |
| `kernel.steadyPauseColour=1` | The TAB pause no longer makes the background flash. |
| `kernel.keyboardNameEntry=1` | Type your hiscore name on the keyboard: letters, digits, space; Backspace goes back one letter; Return finishes the name. The joystick still works as before. |
| `kernel.timerStopsAtZero=1` | The mission timer stops at 00:00 instead of jumping to 59:59 while the napalm strike plays (a cosmetic original bug). |
| `kernel.separateCheatScores=1` | Games in which the original cheat codes (HAMBURGER / MEGA CHEAT) were typed also go to the assisted hiscore table. |

### Hiscores and assisted runs
- The original table (`~/Library/Application Support/Platoon/hiscores.bin`, the one the title screen shows) only
  receives scores from games played without any gameplay option, trainer, save-state load, rewind or
  "Continue / Start at section".
- Other games are ranked in their own table next to it: `hiscores-recruit.bin`, `hiscores-veteran.bin`,
  `hiscores-custom.bin` (difficulty presets on their own) or `hiscores-assisted.bin` (everything else). Name entry
  works as usual; your usual name is pre-filled. The title screen keeps showing the original table.
- A trainer switched on at any moment during a game makes that game assisted. Starting a new game clears the mark
  (unless the reason is still active).

### For developers
- Regression gate: `tools/regress_all.sh --bin <your platoon-headless>` (see port/PORTING.md "Regression gate").
- Core feature tests: `tools/regress/core_features.sh <platoon-headless>`.
- Event/context log: `PLATOON_EVENTS=/tmp/events.txt platoon-headless ...` writes every game event (messages incl.
  dropped ones, sound effects, score, wounds, deaths, section start/end, game over, hiscores) and every screen/area
  change, as the app's features see them.

---

## App: preferences, pause menu, fast-forward, disk import (owner: app)

None of these change the game. They are part of the Mac app around it.

### Preferences (⌘,)
One window with tabs General, Input, Video, Audio, Gameplay and Assist. Every option in the game's enhancement
catalogue gets a row automatically; feature owners can replace it with a custom row. Badges:
- **GAMEPLAY**: changes the game. Runs that use it are assisted and never enter the original hiscore table.
- **ON RESET**: read when a new game starts. The window footer shows how many changes are waiting, with a
  **Reset Game Now** button.

**Restore Defaults** resets the current tab. The video and audio settings from the View/Sound menus appear here
too (with sliders for scanlines, volume and stereo separation) and stay in sync with the menus.

### Pause menu (M1)
Press **Esc**, or choose Game ▸ Pause Menu. On a controller you can hold **Menu** for half a second, once
"Hold the controller Menu button" is on in General; a short press still sends the in-game TAB pause, on release.
The game is frozen and silent while the menu is open. Controls: ↑/↓ or the d-pad to move, Return/Space or Ⓐ to
choose, Esc or Ⓑ to go back. The mouse works too.
- **Resume**.
- **Save Game / Load Game** (slots), and any entries added by features (checkpoints, rewind, message log, maps).
- **New Game** (jungle) or **Restart The Tunnels & Flare / The Jungle & Foxhole**. A restart begins again at the
  start of the section, with the platoon you arrived with (the flare night restarts from the tunnels). Restarting
  a later section marks the run assisted.
- **Options…** (Preferences), **Controls…**, **Abort to Title…** (the original DEL), **Quit Platoon…**.
  Destructive entries ask for confirmation.

Esc never reached the game: the original never reads the Amiga Esc key. You can switch "Esc opens the pause
menu" off in General.

### Auto-pause (S4), General ▸ Pause, all off by default
- **When the window loses focus**: keep running (original) / pause and resume when you come back / pause and
  open the pause menu. This also covers minimising the window and hiding the app.
- **When the Mac or the display sleeps** and **when a game controller disconnects**: pause and open the pause menu.
- **Pause while a dialog is open** (Controls, disk import).

When the game resumes, any key or button still held down is ignored until you let go of it. The press that closed
the menu can't fire a shot, and a fire button held through a pause doesn't keep firing. A disconnected
controller's buttons are always released, so its last direction no longer stays stuck. A **PAUSED** badge in the
corner says why the game is paused; you can switch it off in General.

### Fast-forward (S11)
Hold **`** (backquote, the key left of 1) or the controller's **left stick button (L3)** to run the game faster:
2×, 3×, 4× (default), 6× or 8×, set in General ▸ Fast-forward. Sound plays quietly at the speed you choose, or
is muted. It's useful for the flare intro, text screens and LOADING screens. The game itself is unchanged: it just
runs more frames per second. ⌘T is still a sticky turbo toggle; it isn't remembered between launches.
While fast-forwarding the badge shows **▶▶ 4×**.

### Music / FX mode at start-up (S12), Audio tab
The original always starts with music and FX on. You can choose "Remember the last F10 choice", Music only,
Sound FX only or Off. F10 still cycles the modes during play.

### Game disk: import and health check (M23)
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

### Display framing (S1)
By default the picture is cropped to the Amiga display window DIW $71..$1B1 × lines $2C..$12B (320×256 lowres).
Checked on headless captures of the title, jungle, village, man select, tunnels, flare, final jungle and the
ending: all of the game's pixels lie inside this window, and they touch both side edges. The previous $81 crop hid
the leftmost 16 pixels of the HUD and playfield, for example the wound splat.

### For developers (app extension API)
- Settings: `Prefs/Prefs<Owner>.swift` (declarative `PrefSection`s). Menus and a launch hook:
  `Menus/Menu<Owner>.swift`. Services: `AppServices.shared` (`onFrame`, `onDisplay`, `onReset`, `onSectionStart`,
  `onPauseChange`, `onHostReady`, `probe` (F1/F2), `pause/resume`, `toast`, `markAssisted`, `addPauseMenuItem`,
  `keyHooks`/`padHooks`, `snapshots`). Overlays (F3): `AppServices.shared.overlay.add(OverlayPanel)`.
  Overlays never show up in ⌘S screenshots or in the Metal picture.
- `Platoon --list-prefs` prints the registry and checks that the current settings reach the core.
- App test driver: `PLATOON_DEBUG_SCRIPT=script PLATOON_DEBUG_CAPTURE=outdir [PLATOON_DEBUG_FRESH_PREFS=1]
  [PLATOON_ADF=disk] [PLATOON_PREFS=k=v,…]`. The commands are listed in `DebugScript.swift`: key, pad, resign,
  sleep, disconnect, pausemenu, menu ID, prefs, pref, reset, capture (game + overlay composited), shot, log, quit.

---

## Save states: quick save, checkpoints, rewind (owner: snapshot)

Platoon never had saves. The port can save the whole game while you play in the jungle and village, the tunnels,
the flare night or the final jungle. It can't save on text screens, the man-select box, the trap-door prompt or
loading screens. If you save there, the save is taken as soon as play continues ("Saving at the next
opportunity…").

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

**Rewind** (Preferences › General › Save states, or Game menu; off by default)
- The game keeps a snapshot every second, for 30 s by default ("Rewind length", 10-120 s; about 1.4 MB of memory
  per second).
- **Hold Backspace** (or ⌘Z, or the controller's right-stick click R3). The picture goes back one second at a
  time, faster the longer you hold. **Release** to continue from the moment shown. While holding you can also use
  ← / → to step, Return to resume there, and Esc to cancel and continue where you were. The game is paused while
  you choose.

**Hiscores:** loading a save, retrying a checkpoint or rewinding marks the game as *assisted*: its score goes into
the assisted table, not the original one. Just taking saves, checkpoints or the rewind ring changes nothing.

**How it works / verification** (for developers): snapshots are taken only at the four section main-loop heads,
where the whole game state is in chip RAM, the virtual chipset (copper, CIA timers, TOD and alarm, Paula) and a few
host variables. A restored game continues from exactly that point on a fresh game thread. `port/verify/snapshot/
roundtrip.sh` checks that a restored game plays on byte-identically to one that was never interrupted: the full-RAM
hash every frame, the tick dumps, the screenshots and the audio, in all four loops. It also covers rewind and
checkpoint retry, and files saved in one process and loaded in another. Headless options: `--snapshot-save N FILE`,
`--snapshot-load FILE`, `--roundtrip N`, `--roundtrip-every K`, `--rewind-at N BACK`, `--checkpoints`,
`--retry-at N`.
