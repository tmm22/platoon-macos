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

---

## Tunnels & flare night: map, fairness, fixes (owner: section1)

Everything here is off by default. Options marked **gameplay** make the game *assisted* (separate hiscore table).
Core options are set in Preferences › Gameplay ("Tunnels & flare night (section 1)" rows), with
`--enh key=value` on the headless runner or `PLATOON_ENH`; they take effect when a new game starts.

### Tunnel map (M3) - Preferences › Assist › Tunnel map, or Assist › Show the tunnel map
- A map of the 43x43 maze beside the game (or in the game's top-right corner if the window is narrow). It fills in
  as you explore: the corridors, rooms and walls you could see from where you stood. A green arrow shows where you
  are and which way you face; the blue dot is the entrance.
- Rooms get their number when you enter them. The list below the map shows what you found in each room (flares,
  compass, map, ammunition, medical supplies, EXIT) with a tick once taken.
- What you explored is kept when a soldier dies, after loading a save and after rewinding; it is cleared when the
  tunnels start in a new game.
- **M** in the tunnels hides / shows it. The pause menu has "Show / Hide Tunnel Map".
- Options: size (3-10 points per cell), position, room list on/off, **Reveal the whole maze** (spoiler: all
  corridors and the contents of every room; marks the run as assisted). The plain map only shows what you saw, so
  it does not mark the run.
- `s1.exploredMap=1` (**gameplay**, variant B): in the game itself the map window is always open and draws the
  cells you have seen, even without the map item (the tunnel plan still reveals everything when you find it).

### Fairness (M4) - gameplay
| Option | What it does |
|---|---|
| `s1.keepItems=1` | When a soldier dies the next one keeps the flares, the compass, a map found in the tunnels and the emptied drawers (the original takes everything away and refills the rooms). If you die in the flare night you get back the flares you took into it, so the exit still opens. |
| `s1.flareRetry=1` | Dying in the flare night restarts the flare night with the next soldier and the flares you brought, instead of sending him back through the whole maze. |
| `s1.checkpointRespawn=1` | The next soldier starts in front of the last room you entered (facing away from it) instead of at the entrance. |

### More soldiers (M15, core options `game.lives`, `game.fullPlatoon`) - gameplay
- `game.lives=3..5`: after the second soldier the third (up to the fifth) takes over, each after its own
  "ONE MORE CHANCE" screen.
- `game.fullPlatoon=1`: the tunnels keep the platoon you brought from the jungle (wounds, ammunition, dead men)
  and start with your first living man; every living man gets his turn.

### Original bug fixes (S9) - gameplay, one switch each
| Option | Fix |
|---|---|
| `s1.fixLastBullet=1` | Your last bullet can kill (the original checks the ammunition after the shot has used it). Tunnels and flare night. |
| `s1.fixMoraleWrap=1` | Morale from room items stops at the maximum instead of wrapping round to almost nothing. |
| `s1.fixFoodFarm=1` | The rotten food gives its 500 points once per soldier, not on every click. |
| `s1.fixFlareSpawn=1` | Heavy firing in the flare night can no longer switch the enemy spawns off for good. |

### Difficulty (M10) - gameplay
Recruit / Veteran set these; Custom uses only the ones you set (`original` = the game's value):
| Key | Original | Recruit | Veteran | Meaning |
|---|---|---|---|---|
| `s1.diff.hitMorale` | $c00 | $800 | $1000 | morale lost per wound (tunnels and flare night) |
| `s1.diff.spawnDelay` | $10 | $20 | $08 | minimum ticks between tunnel enemies (plus 0-$31 random) |
| `s1.diff.enemyAim` | $f | $19 | $0b | ticks a corridor enemy aims before firing |
| `s1.diff.itemMorale` | $200 | $300 | $100 | morale gained per useful room item |
| `s1.diff.flareSpawnBase` | $90 | $c0 | $70 | flare night enemy interval (bigger = fewer enemies) |
| `s1.diff.flareShotSlack` | $d | 5 | $f | flare night: smaller = more time before a firing enemy hits you |

### Mouse / pointer aiming (L2) - gameplay `s1.directAim=1`
With the option on and a pointer target coming from the input settings (mouse aiming), the crosshair in tunnel
fights, in the room search and in the flare night jumps straight to the pointer (within the original limits);
fire, recoil and hit rules are unchanged. Without the option the input settings can still steer the crosshair
by moving the stick for you (assisted aiming, not gameplay).

### Randomiser (L3) - gameplay `s1.randomSeed=N` (1 and up; 0 = off)
Shuffles what lies behind each hotspot between rooms of the same kind: the flare boxes, compass, maps, ammunition
and so on move to other rooms that look alike, and the real EXIT is behind the door of either ladder room. The
same seed always gives the same tunnels. Use the tunnel map to keep track.

### Turn slide (M25) - Preferences › Video › Tunnels
"Slide the view when turning": when you turn left or right in a corridor the old view slides out and the new one
in over a few frames. Presentation only (the game, screenshots and recordings are not changed).

### For developers
- Hooks: `// ENHANCEMENT <ID>` sites in `Game/Section1/*.swift`; helpers in `Game/Section1/Section1Enhance.swift`
  (state in a RAM scratch block at $3f000, so savestates/rewind capture it), `TunnelAim.swift` (L2 API:
  `TunnelAim.setTarget(machine, x:y:)` / `clearTarget` / `info(memory, area:)`, visible-screen coordinates) and the
  public `TunnelMaze` helpers used by the overlay.
- Feature tests: `port/verify/enh-section1/s1test.py <platoon-headless> [outdir] [--only REGEX]` (headless,
  deterministic; `PLATOON_S1_AIM="FRAME:X,Y;FRAME:-"` scripts the aim target).

## Jungle & village: failsafes, fixes, map, widescreen (owner: section0)

Everything here is off by default. Options marked **gameplay** make the game *assisted* (separate hiscore table).
Core options (`s0.*`) are set in Preferences › Gameplay › "Jungle & village" / "Jungle & village: original bugs",
with `--enh key=value` on the headless runner or `PLATOON_ENH`; they take effect when a new game starts.

### Rules (gameplay)
| Option | Preferences row | What it does |
|---|---|---|
| `s0.bridgeFailsafe=1` (S6) | Bridge failsafe | Walking right towards the bridge without having planted the explosives stops you at the last column before the point of no return, with "SET THE EXPLOSIVES ON THE BRIDGE", instead of freezing you while a runner wipes out the whole platoon. With the explosives nothing changes (they are planted automatically on the bridge). |
| `s0.forgivingTraps=1` (S7) | Forgiving booby traps | Tripwires and the two booby-trapped drawers (huts 0 and 4) count as a normal hit: one wound and the usual morale loss, instead of killing the soldier outright. |
| `s0.explicitJumpCrouch=1` (M14) | Separate jump and crouch controls | Jump and crouch get their own controls (bind "Jump" / "Crouch" in the Input tab; headless: Amiga keys `s0.jumpKey=0x32` / `s0.crouchKey=0x33`). Up and down then only take the paths between the jungle strips and the hut doors, so you can no longer walk onto a path by accident instead of jumping a tripwire. You can also jump on path tiles and in front of doors. |
| `s0.villageSeed=N` (L3) | Village randomiser: off / new village at every reset / fixed village (seed) | The torch, the map and both booby traps move to other search spots in the huts (seeded: the same seed gives the same village). The map still needs the hut-2 guard dead. A toast shows the seed when the jungle starts. |

### Original bug fixes (S9) - gameplay, one switch each
| Option | Fix |
|---|---|
| `s0.fixMoraleWrap=1` (S9b) | Morale from supply crates, the torch and the map stops at full instead of wrapping round to almost nothing. |
| `s0.fixHutDummy=1` (S9f) | The invisible "enemy" in the trap-door hut (hut 1) can't be shot: in the original it gave 300 points and counted as killing the hut-2 guard, so the map could be taken without a fight. |
| `s0.fixTripwireSpawn=1` (S9g) | Tripwires always appear at the screen edge ahead of you (with some scroll positions the original put them behind you). |
| `s0.fixTrapdoorBonus=1` (S9k) | The trap-door bonus (1000 per living soldier) counts your five soldiers; the original counts five records from the soldier in control, so with soldier 2-5 it counts game variables as soldiers. |

### Difficulty (M10) - gameplay
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
(Starting morale is the core's `kernel.diff.startMorale`.) Extra soldiers (M15, `game.lives` / `game.fullPlatoon`)
need nothing in the jungle: all five soldiers play here anyway, and with `game.fullPlatoon` the platoon you leave
the jungle with (wounds, ammunition, dead men) is what the tunnels get.

### Jungle map (M6) - Preferences › Assist › Jungle map, or Assist › Show the jungle map
- A schematic of the six jungle strips below (or above) the game: level 0 at the top (the village street is its
  right half), level 1 is where you start, levels 2-4 lie deeper. Dark green = trees you can't walk through,
  yellow lines = paths between the strips, blue = the river, brown = the bridge planks, small houses = hut doors.
  The green arrow is you (white inside a hut).
- **Show**: layout only / + objectives (E = explosives on level 4, B = the bridge, ✕ = the point of no return
  without explosives) / + hut contents (spoiler: torch, map, booby traps - listed per hut, with "sprung" once they
  went off; marks the run as assisted).
- **Only what you have explored**: columns appear once you have been near them; kept after deaths and loaded
  games, cleared when the jungle starts in a new game.
- **M** in the jungle hides / shows it; the pause menu has "Show / Hide Jungle Map". Size 2-8 points per column.
- **Warn about booby-trapped drawers** (same section): inside a hut, "Something doesn't feel right here…" appears
  while you stand at a drawer that is still booby-trapped. Marks the run as assisted when it appears.

### Widescreen jungle (L4) - Preferences › Video › Widescreen jungle, or View › Widescreen Jungle
In a window wider than the game (or full screen), the jungle scenery continues into the black side bars: the
same trees, paths and river, scrolling exactly with the picture (up to 256 px per side, fading towards the
edges). Background only - enemies, bullets and you exist only in the middle, and the HUD keeps its width. Hidden
during transitions and man select, inside the huts and in the other sections. It never appears in screenshots.
It lets you see a little further ahead, so it is off by default (it does not change the game itself).

### For developers
- Hooks: `// ENHANCEMENT <ID>` sites in `Game/Section0/*.swift`; helpers in `Game/Section0/Section0Enhance.swift`
  (M14 host buttons `Section0HostButtons.of(machine).jump/.crouch`, S6 failsafe, S9b clamp, L3 shuffle with a
  host PRNG so the game's random numbers are untouched).
- Read-only models: `JungleMapModel` / `JunglePlayer` (M6) and `JungleWideLatch` + `JungleWidescreen.render`
  (L4: the scroll state is latched when the game swaps buffers, so the sides match the displayed frame).
- Feature tests: `port/verify/section0/enh/features.py <platoon-headless> [outdir] [--only REGEX]` (headless,
  deterministic). `PLATOON_S0_WIDETEST=dir[,every]` makes the headless runner check the L4 renderer against the
  real picture and write sample images (`wide_<frame>.ppm`, `wide.log`).

---

## Audio: mixer, ghost voices, sound character, soundtrack, output timing (owner: audio)

None of these options changes the game: they only change how Paula's output is mixed and played on the Mac, so
they never make a run *assisted* and they all apply immediately (no restart). With every setting at its default the
sound is bit-identical to the original port (checked by rendering WAVs, see "For developers").
App: **Preferences › Audio** (⌘,), a few toggles also in the **Sound** menu (Band-limited Synthesis, Ambience,
Ghost Voices, Replacement Soundtrack, Choose Soundtrack Folder…, Audio Mixer…).

### Mixer (S10) - Audio › Mixer
- **Music volume / Sound effects volume** (0-200 %, default 100 %). Each of Paula's four voices is tagged by who owns
  it at that moment - the music driver or a sound effect - so e.g. quieter gunfire under the tunes works even though
  both share the same four channels.
- **Voice panning:** Amiga (L R R L, default), Swapped, Soft (half-way), Mono, or Custom with one slider per voice.
  The existing *Stereo separation* slider (Audio › Output) still narrows whatever is chosen.

### Ghost voices (M12) - Audio › Music, or Sound › Ghost Voices
Every rifle shot takes one or two of the four channels away from the music, so Whittaker's in-game tunes lose parts in
every firefight. With ghost voices on, the silenced music parts keep playing on four extra host voices for exactly as
long as the sound effect owns the channel. The game, its register writes and its timing are untouched.

### Sound character (M25) - Audio › Sound character
- **Synthesis:** *Legacy* (default, the original output) or *Band-limited (BLEP)*: every sample step is rendered as
  a band-limited step, which removes the metallic aliasing of high notes and synth effects (most audible with the A500
  filter off). Measured on a high square wave: aliasing about 30 dB lower (unit test).
- **Ambience:** reverb on the **sound effects only** (the music stays dry). *Automatic* follows the area you are in:
  jungle / village / final jungle (open air), hut (small room), tunnels (echoing), the flare night (wide and far),
  the bunker (concrete); title, loading and text screens stay dry. Fixed presets are available too, plus an amount
  slider.

### Replacement soundtrack (M25) - Audio › Music, or Sound › Replacement Soundtrack
Plays your own audio files instead of the game's tunes (nothing is included). Put files into the soundtrack folder
(default `~/Library/Application Support/Platoon/Soundtrack`, *Choose Folder…* / *Show Folder in Finder*), named by
tune: `song0` … `song6`, or a leading number (`2 - Jungle.m4a`), or a name:

| tune | when | names |
|---|---|---|
| 0 | title | `song0`, `0…`, `title` |
| 1 | hiscore entry | `song1`, `hiscore` |
| 2 | jungle & village | `song2`, `jungle`, `village` |
| 3 | LOADING / message screens (plays once) | `song3`, `loading` |
| 4 | tunnels | `song4`, `tunnels` |
| 5 | final jungle | `song5`, `finaljungle`, `foxhole` |
| 6 | flare night | `song6`, `flare`, `night` |

m4a, mp3, wav, aiff, caf, flac. Tunes without a file play as usual. Sound effects are unchanged, F10 (music off) stops
the file, the GAME OVER fade fades it, pausing pauses it; *Music volume* and the main volume apply.

### Output timing (M22) - Audio › Output timing
- **Buffer control:** *Original* (default) drops whole blocks when the buffer runs ahead. *Smooth* keeps the buffer at
  the latency target by resampling up to ±0.5 % instead, so clock drift, variable-refresh displays and host hiccups
  don't click, and underruns recover cleanly. If the game ever runs slower than real time, the sound follows it at a
  lower pitch instead of stuttering. Fast-forward (S11) keeps working as before (reduced-volume real-time sound).
- **Latency:** 20 / 40 / 60 (default) / 100 / 150 ms.
- The audio engine now restarts by itself when the output device changes (headphones, AirPlay, sample rate).
- *Log audio diagnostics* prints buffer fill, ratio and underruns to the Console every 2 s (after relaunch).

Faster key-event delivery (M25) is in General › Keyboard (app option, see the App section).

### Headless / command line
The core options mirror the mixer for `platoon-headless` (`--enh list` shows them, all non-gameplay):
`audio.ghostVoices=1`, `audio.synthesis=blep`, `audio.musicVolume=0.5`, `audio.sfxVolume=1.5`, `audio.pan0..pan3=-1..1`,
`audio.ambience=off|auto|jungle|hut|tunnels|night|bunker` (auto needs a probe, e.g. `PLATOON_EVENTS=/dev/null`),
`audio.ambienceLevel=1`. Example:
`platoon-headless --enh audio.ghostVoices=1,audio.synthesis=blep --script s.txt --frames 3000 --wav out.wav`.
The driver test harness (`--music-test N` / `--sfx-test ID`) reads the same keys from `PLATOON_ENH`.

### For developers
- Paula (`Platform/Paula.swift`): `runLineLegacy` is the original renderer and is used whenever every mixer setting is
  at its default; `runLineMixer` steps the DMA state machine identically (same phase arithmetic, order, interrupts)
  and only computes the output differently. Building blocks in `Platform/PaulaMixer.swift` (BLEP bus, reverb).
- Music driver hooks (`Game/Audio/MusicDriver.swift`, `// ENHANCEMENT M12/M25`): ghost writes via
  `Paula.ghostWrite` (never `chip.write`), song cue counter; `Game/Audio/AudioEnhance.swift` installs the voice tagger
  (shadow block `$4084+12*ch+$b`) and applies `enhancements.audio` once per run, and picks the auto ambience from F1.
- M22: `Platform/HostAudioStream.swift` (ring + rate control, unit-tested); app side `PlatoonApp/AudioOutput.swift`,
  `PlatoonApp/AudioEnhancements.swift` (pref sync, soundtrack controller).
- Tests: `port/verify/audio/wavcmp.sh` (default output byte-identical to the pinned baseline, 8 scenarios),
  `port/verify/audio/enhtests.sh` (RAM hash and register log unchanged with every audio option on, ghost / BLEP /
  ambience / pan / volume behaviour), `swift test --filter AudioTests`.
