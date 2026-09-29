# Platoon: optional enhancement roadmap

This roadmap combines four independent idea passes: QoL, gameplay, audio-visual, and controls/accessibility/platform.
Each pass had its own feasibility review against the code. Duplicate ideas are merged, rejected ideas are listed at the
end, and useful ideas the reviewers found themselves are folded in.

**Ground rules for every item**

- **Default = the original 1988 experience.** Every item is opt-in. The only items marked "default on" are purely
  presentational, or plain bug fixes to the host app that don't change what the game does.
- **Changes inside translated logic** go only through `enhancements.xxx` flags checked at clearly marked
  `// ENHANCEMENT` sites (PORTING rule 11). With the flag off, the code path must be byte-identical, so
  `platoon-headless --deterministic` tickdumps and `--hash` lockstep against the emulator still match.
- **Host-only items** (InputManager, GameHost, MetalRenderer, AudioOutput, overlays) are preferred wherever they can do
  the job. They read RAM from `Machine.frameHook`, where the game thread is parked, so reads don't race. They must not
  write game RAM unless they are explicitly gameplay options.
- **Hiscore integrity.** Any run that used a gameplay-changing option (trainer, difficulty, mercy, load/rewind,
  practice) is tagged and kept out of the original `hiscores.bin` table (see S5).
- **Effort:** S = up to about a day, M = a few days, L = 1-2 weeks, XL = more.

**The savestate question.** The lenses disagreed. Two reviewers said savestates are impossible because the game state
includes the Swift game-thread stack (`m.waitVBlank` / `m.jump` coroutines). The QoL reviewer checked the code and
found that at the four section main-loop heads the stack holds no state: `tickPoint(0x17186)` s0MainLoop,
`0x171c6` s1_tunnelMainLoop, `0x18bd8` s1_flareMainLoop and `0x17118` s2_main_loop. There, all state is in RAM, the
chipset/CIA/Paula, and a few `Platoon` host vars. Resuming means rebuilding the Machine and `m.jump`ing into a
loop-entry wrapper. **Conclusion:** snapshots taken at loop heads are feasible (L1). Snapshots at arbitrary points,
and anything that needs them (run-ahead latency reduction), are not.

---

## Shared foundations (build these first; many items depend on them)

| ID | Foundation | Used by |
|----|------------|---------|
| F1 | **Context probe.** A read-only, host-visible description of what's on screen: loaded section (`Platoon.loadedSection` isn't reachable from GameHost today; expose it or track it from `onSectionStart`, noting that `$6e(a6)` is already off by one then), tunnel vs flare sub-mode (a host-only mode byte set in `s1_flareEnterBody`), trap-door prompt, man select, name entry, text screen. | Controller context, overlays, objectives, maps, captions, practice, speedrun |
| F2 | **Game-event observers** on existing choke points, zero-cost when nil: `onMessage(section, index, dropped)` at `k_queue_text_impl` ($1070c, before the `textN == 4` drop); `onFx(id)` at `k_fx_impl` ($10c50, before the FX-off early return); `onScore` at `k_add_score` ($10638). They run on the game thread: buffer the data and consume it in frameHook, and never touch AppKit directly. | Message log, TTS, shake/rumble, achievements, speedrun, captions |
| F3 | **Assist overlay layer.** One NSView/NSHostingView above the MTKView (MetalRenderer is single-pass and keeps redrawing the last canvas when paused). It is never drawn into the Amiga canvas or into screenshots. | Pause menu, maps, objectives, subtitles, timers, prompts |
| F4 | **Tainted-run flag and per-mode hiscore file** (S5). | Every gameplay option |
| F5 | **Loop-head snapshot/restore + round-trip test** (L1). | Quick save, checkpoints, rewind, snapshot-based practice |

---

## Top picks (best value for effort)

1. **Controller parity and input fixes (S2, S3, S4).** Today a pad-only player can't finish the game. There is no Y/N
   for the trap door (the only exit from section 0), no SPACE for jungle grenades, no Left-Alt, and a disconnected pad
   leaves input stuck. Keyboard Space is both fire and grenade, which the help text gets wrong. Cheap, host-only, and
   fixes blockers.
2. **Auto-pause + pause overlay (S4, M1).** Losing focus currently leaves the 2:00 napalm clock and enemies running
   in the background. Auto-pause is a one-line change. A pause menu then gives controller and full-screen players
   access to options, save/load and restart.
3. **Bridge failsafe and forgiving booby traps (S6, S7).** Walking past bridge column $4e without the explosives
   silently ends the whole game even with five healthy men. This is the most notorious unfair moment, and the fix is
   one guarded branch in `s0ScrollStep` that reuses an existing message.
4. **Message log and large subtitles (S8).** Every clue in this cryptic game is a one-second fading HUD line, and the
   queue silently drops messages beyond the fourth. A read-only observer makes them readable and loggable, with TTS
   as a follow-up.
5. **Tunnel automap + keep-items + flare-night retry (M3, M4).** The tunnels are the single biggest frustration: a
   43x43 maze, ten look-alike rooms, and everything is reset when a soldier dies. The automap is read-only; keep-items
   needs the flare-night fix to avoid a softlock.
6. **Final-jungle navigator (M5).** The final jungle is a 12x10 room tree with heading-relative exits and a 2:00
   timer. Heading, breadcrumb and a BFS "take the LEFT exit" hint are all computable from RAM, and the BFS can be
   validated against `re/finaljungle/assets/maze_graph.json`.
7. **Quick save/load at main-loop heads (L1) → auto-checkpoints and rewind (M8, M9).** The game has no saves. This is
   the largest single QoL gain, and once the snapshot core and its round-trip test exist, checkpoints and rewind are
   cheap additions.
8. **Music/SFX mixer + ghost voices (S12, M12).** Every rifle shot takes two of Paula's four channels, so Whittaker's
   in-game tunes lose half their voices in every firefight. Ghost voices keep the full score. They don't go through
   `chip.write`, so register-log verification is unaffected.

Next in line: difficulty presets (M10), practice mode (M11), the bug-fix pack (S9) and hold-to-fast-forward (S11).
Hiscore integrity (S5) is not a headline feature, but it has to ship with the first gameplay option.

---

## Tier S: quick wins

### S1. Fix the default display framing (verify first)
- **Value:** The HUD in every section, and the flare, tunnel and final-jungle playfields, use DIWSTRT $3c71 (lowres
  x 17..337). `MetalRenderer.crop` assumes DIW $81 (`(0x81 - canvasH0) * 2`, 640 wide). According to the review, the
  left 16 px of HUD and playfield are therefore hidden (for example the wound splat at lowres x=18), and 16 px of black
  shows on the right.
- **How:** Crop x = `(0x71 - 0x60) * 2`, w = 672 (the union of $71..$1c1, which also covers the jungle's $81
  playfield). Alternatively, auto-frame per region from DIWSTRT/DIWSTOP. This is presentational, so default on once
  verified; overscan is unchanged.
- **Hooks:** `MetalRenderer.crop`; optionally read the copper DIWSTRT values.
- **Risk/testing:** First confirm with `platoon-headless --start-section 1` screenshots against emulator framing.
  Bezels, backdrops and upscalers depend on this being right.

### S2. Controller parity with context-aware buttons
- **Value:** Makes the game finishable on a pad: jungle grenades, changing soldier, answering the trap door, abort.
- **How:** Only buttons that do nothing today get new jobs. X = Amiga SPACE $40 (jungle grenade with no direction
  held, flare). Y = Left-Alt $64, sent as a tap because it is polled every tick and holding it re-enters man select.
  LB/LT = 'Y' $15 / 'N' $36. Holding Menu for 1 s = DEL $46, with confirmation; a short press still sends TAB on
  release. Context layer: while the trap-door prompt is up, A sends **fire and Y together**. RAM-based prompt
  detection goes stale while message $b fades after N, and neither side reads the other input, so sending both is
  safe. Require a fresh press after the prompt appears, so a held fire doesn't answer Y. Show GCController SF Symbol
  glyphs in the overlay.
- **Default:** Recommended ON, because no existing button changes meaning. Provide a "Controller: original mapping
  only" switch. This is the one deliberate exception to default-off; the maintainer decides.
- **Hooks:** `InputManager.attach` valueChangedHandler; `GameHost.tapKey`. The game reads keys at `s0ReadInput`
  (Section0.swift ~298/303), Left-Alt at Section0.swift:223, and Y/N in `s0TrapdoorPrompt` (Section0Village.swift:193).
  The prompt is detected through F1: text table `$4a(a6)` == $1a6de, queue head `$3c(a6)` == $0b.
- **Bug fixes bundled here (always on):** observe `.GCControllerDidDisconnect` and clear pad state (today padUp/padFire
  stay stuck, and `releaseAll()` doesn't reset them); keep per-controller state and OR it together instead of letting
  the last handler overwrite shared state.
- **Risk/testing:** Headless is unaffected. In the app, walk to the trap door with only a pad, and test Y-then-N.

### S3. Keyboard fixes: Space double-binding, international layouts, F-key conflicts
- **Value:** Mac Space is in both `joyFire` and `amigaKeys` (0x31 → $40). In the jungle, Space alone throws grenades;
  in the flare dugout one press fires a bullet **and** launches a flare. The README and the Controls alert both say
  "Fire: Space or Z". On QWERTZ the key labelled Y is keycode 0x06, which is the fire key, so pressing Y at the
  trap-door prompt fires instead. On laptops, F10/F11/F12 are media keys or Show Desktop.
- **How:** (a) A "Separate fire and SPACE" preset: Z/X = fire only, Space = Amiga SPACE only. This is arguably closer
  to the Amiga, where stick fire and the SPACE key were separate. The current default stays as it is, but the help
  text is corrected. (b) Map the letter keys the game reads (Y/N) by character (`charactersIgnoringModifiers` /
  UCKeyTranslate), not by US-ANSI keycode. This is a bug fix and always on. (c) Add menu items for HELP and keypad
  minus, plus non-F-key alternatives. Never offer Ctrl+arrow keys, which macOS reserves for Mission Control and Spaces.
- **Hooks:** `InputManager` joy*/amigaKeys tables, `GameView` key handling, `AppDelegate.showControls`, README.
- **Risk/testing:** None to the game. Test that the default tables give identical Input output.

### S4. Auto-pause, sleep and disconnect handling, resume-press swallowing
- **Value:** Stops the game running unseen after an alt-tab, a notification, sleep or a dead pad battery. Without it
  the napalm timer, morale drain and enemy fire keep going.
- **How:** Options (default off; recommended to turn on): pause on window resign/minimise, `NSApplication.didHide`,
  `NSWorkspace.willSleep` / `screensDidSleep`, and controller disconnect. Also pause while the Controls NSAlert is
  modal. On resume, ignore the resuming press until it is released, so it doesn't fire a shot. The same guard applies
  after host dialogs. Host pause avoids the in-game TAB pause's COLOR00 strobe and its message-skip quirk.
- **Hooks:** `AppDelegate.windowDidResignKey` (today only `releaseAll()`), `togglePause`, `GameHost.paused` (didSet
  already releases input and resets pacing), and new observers in `InputManager.init`.
- **Risk/testing:** Host-only, none.

### S5. Hiscore integrity: tainted runs and per-mode tables
- **Value:** Today trainer runs (applied in frameHook) write into the one `hiscores.bin`, which pollutes the original
  table. This is a prerequisite for every gameplay option.
- **How:** A host "assisted" flag is set if the trainer, difficulty ≠ Original, mercy, fixes, snapshot load/rewind,
  practice, Continue/Start-at-section, or cheat flags `$70(a6)` were used. Assisted runs either don't save, or save to
  a separate file (e.g. `hiscores-assisted.bin`, one per mode). The name-entry screen still works.
- **Hooks:** `GameHost.gameConfig()` hiscoreURL; `Platoon.saveHiscores` (KernelFlow.swift ~315-322); `k_game_over`.
  The file must stay exactly `Disk.trackSize` bytes.
- **Note:** The original name buffer `$11836` already sits inside the saved track image, so "remember my name"
  already persists across launches. Add a test to confirm this rather than a feature.

### S6. Bridge failsafe (gameplay, opt-in)
- **Value:** Removes the run-ending "YOU DID'NT BLOW UP THE BRIDGE, YOUR PLATOON HAS BEEN WIPED OUT!" when all five men
  are alive.
- **How:** On level 1 with bridge `$60c9c` == 0, block rightward movement before column $4e, the same way the game's
  own suicide guard blocks the blown gap. Queue message $11 "SET THE EXPLOSIVES ON THE BRIDGE", gated on msgCount == 0
  as the original does so the queue doesn't fill. Explosives are auto-planted at column $48, so bridge == 0 there
  already means no explosives. State 9, the runner and `all_dead` never occur.
- **Hooks:** `s0ScrollStep` (Section0Player.swift ~349-354; the original guard is `bridge == 2 && level == 1 &&
  pworld == 0x238`). Add `enhancements.bridgeFailsafe`. Compare pworld with `>=` against the world position of column
  $4d, because steps are d6 px.
- **Risk/testing:** Check that every rightward path goes through scroll_step: jump states with frozen dx, and blast
  knock-back via `$60cbc`. Headless script: walk past $4e without explosives, flag on and off.

### S7. Forgiving booby traps (gameplay, opt-in)
- **Value:** Tripwires and the hut-0 and hut-4 drawers normally kill the current man outright (hits := 3, then +1).
- **How:** Skip the `hits := 3` write, so the trap counts as a normal "YOU'RE HIT" (+1 wound, morale -$800). A separate
  host-only hint option shows a "suspicious spot" overlay when standing on a booby-trap search spot that is still
  live (entries at `$1aafa` whose msg byte is still $0f). The search itself is not changed.
- **Hooks:** `s0TrapUpdate` (`s0PlayerHit(); man.hits = 3`), `s0ItemBoobyTrap` (Section0Village.swift ~145).
- **Risk/testing:** RE test states in `re/village`, `re/jungle`.

### S8. Message log and large subtitles
- **Value:** Clues like "YOU NEED TO FIND A TORCH", "A COMPASS WOULD HELP !" and "YOU NEED MORE FLARES" are held for 25
  ticks only if they are the last message queued (otherwise for 1 tick), and anything beyond four queued messages is
  dropped.
- **How:** Uses the F2 `onMessage` observer. A scrollable log in the pause menu/overlay, with dropped messages marked.
  Optional large high-contrast captions (F3) mirror the current HUD line. Deduplicate messages that are re-queued
  continuously (the trap-door prompt, ENTER YOUR NAME, S2 hint timer, bridge hint at columns $45-$4b).
  **Phase 2 (M):** AVSpeechSynthesizer / VoiceOver announcements, with caps normalised ("DID'NT" → "didn't"), plus
  selected full text screens hooked at their routines (`s2_text_screen_music3`, `s0MsDraw`, section-start screens),
  not at `r_print`, which runs every tick for the HUD.
- **Hooks:** `k_queue_text_impl` ($1070c); decode `($4a(a6))[d0]` using the `r_print_impl` control codes
  (Resident.swift:338). The tables are S0 $1a6de, S1 $19374, S2 $189e0.
- **Risk/testing:** Read-only. Compare the headless log against `re/jungle/assets/messages.json`.

### S9. Original bug and quirk fix pack (one toggle each)
- **Value:** Lets players choose the game as intended over 1988 accidents. Exploit fixes also keep scores comparable.
- **Toggles:** (a) Final-jungle timer paused during room fades: `mem.w16(0x68, 0)` should be `a6+0x68`
  (FinalJungle.swift ~655), worth about 5 s per run. (b) Morale adds clamped at $ffff (Section0Objects ~359/367,
  Section0Village ~160/171, `s1_itemTaken`). (c) Tunnels: the last bullet can kill (`s1_crossInBox` tests ammo after
  the decrement). (d) Flare spawn interval clamped to ≥1, so the wrap to 0 can't disable spawns. (e) Tunnel food item
  $188a4 sets bit 7, so it can't be farmed. (f) Invisible hut-1 dummy / stale `$5f88a` guard kill (village §h.6,
  `s0HitPBullet`). (g) Tripwire spawning behind the player when `$60c34 < 0` (`s0TrapSpawn`). (h) Show the intended
  "YOUR PLATOON HAS WITHDRAWN FROM ACTION" (`S2.txtWithdrawn`) and stop the timer at the start of `s2_time_up` (the
  59:59 flash). (j) Phantom '.' grenade auto-throw after Barnes dies (foxhole §h.6, `s2_keytest_d0w`).
  "Rifle kills spider-hole VC" is a balance change, so it goes under difficulty (M10).
- **Risk/testing:** One scripted repro per fix; most exist as RE test states. Tag runs (S5).

### S10. Separate music and SFX volume, per-voice pan
- **Value:** Quieter gunfire under the tunes, or the reverse. Softer LRRL panning on headphones.
- **How:** Paula gets an injected per-channel tag closure (`voiceIsSfx(ch)` = `mem.r8($4084+12*ch+$b) != 0`), so
  Paula still doesn't hard-code game RAM. Music/SFX gain and per-voice pan are applied in `runLine`. Note that synth
  effects (<$80) are single-voice and hard-panned. Replace the unused `musicMuted` (which mutes all four voices).
  F10/`$66(a6)` are untouched.
- **Hooks:** `Paula.runLine`, `GameHost.applyAudioSettings`, `Settings`. This is also the prerequisite for ghost
  voices, ambience stems and replacement music.
- **Risk:** None at 100% and default pan.

### S11. Hold-to-fast-forward
- **Value:** Covers the flare intro (~11 s), text-screen holds, dissolves and LOADING screens on retries, without any
  hooks in translated code. It replaces the "skip sequences" idea.
- **How:** Momentary turbo while a key (e.g. backquote) or a controller trigger is held. Audio is muted or ducked
  during it, because `AudioOutput.push` drops chunks above 3x the target fill. Sticky turbo is not persisted by
  default.
- **Hooks:** `GameHost.tick` perTick, `InputManager`, `AudioOutput`.

### S12. Remember the F10 music/FX mode, and expose hidden settings
- **Value:** The F10 state resets on every boot. The scanline strength (fixed at 0.35), `originalCredits` and turbo
  have no UI.
- **How:** `enhancements.soundFlagsAtBoot` is written immediately after the first-boot `soundFlags = 3`
  (KernelTitle.swift:43), so the title tune and the MUZAK/FX credit lines come out right. Changes are persisted by
  reading `mem[$12dde+$66]` in frameHook. Add menu items or sliders for scanlines, separation and volume, and plumb
  `originalCredits` in `GameHost.gameConfig()`. Add a Dock menu (`applicationDockMenu`) with Continue / Start at
  section.
- **Risk:** One flag-gated line in first-boot init.

### S13. Screen shake and controller rumble
- **Value:** Physical feedback on explosions, hits, the bridge blast and the napalm strike.
- **How:** Uses `onFx` (F2), mapping $85 explosion = strong, $81 hit = medium, $82/$83 shots = a light controller tick
  only. Extra detection for the bridge (`$60c9c` → 2) and napalm from frameHook. Shake is a MetalRenderer `dstOrigin`
  offset of at most 2-3 lowres px, decaying per *emulated* frame so it behaves the same under turbo. It never appears
  in screenshots. Rumble uses `GCController.haptics` (CHHapticEngine). Also optional: a directional "[SNIPER ◀]"
  caption for the S2 idle shot, whose side is read from the slot x ($18 or $110), and a brief screen-edge tint on
  $81 for hard-of-hearing players. Default off.
- **Risk:** Observer only. `k_fx_impl(0)` also fires on every F10 toggle, so filter it out.

### S14. Ambient backdrop border
- **Value:** Fills the black side bars with a blurred, darkened extension of the frame. No artwork needed.
- **How:** A MetalRenderer pre-pass using a downsampled or mipmapped blur of the canvas texture. Optionally include a
  scene controls card (Left-Alt change soldier, SPACE flare, Y/N) using F1. Bundled per-section bezel PNGs come later.
  Presentational, default Black.
- **Depends on:** S1 framing fix.

### S15. Tap-stretching for low-rate loops (motor accessibility)
- **Value:** Tunnels read the stick every 4 vblanks and the jungle every 2-3 frames, so short taps, including
  edge-latched tunnel turns, are lost.
- **How:** A host-only "minimum hold" in InputManager stretches every press, and every release, to at least 4 frames.
  Double taps still register as two turns, and Platform isn't touched. A true read-latch in `r_joystick_impl` is a
  possible later variant, but it must clear at the next frame start and not on the first read, because S2 reads the
  stick twice per tick. Keep it out of title, name-entry and text screens. Default off.
- **Testing:** A headless script with 1-frame taps in the tunnels, option off (taps lost, as in the original) and on
  (every turn registers).

### S16. Night black-level lift
- **Value:** Flare night0 and the tunnels were designed for a 1084 monitor's black level and are nearly invisible on
  LCD/OLED.
- **How:** A shader LUT gamma/black-lift slider, applied only while the flare or tunnel palettes are active (detected
  via `$5a(a6)`). Documented as slightly easing enemy spotting in the flare section. Default off.

### S17. Reduced-flashing pause
- **Value:** Stops the TAB-pause COLOR00 sawtooth. The review found it is below WCAG flash thresholds, but it is
  unpleasant.
- **How:** `enhancements.steadyPauseColour` skips the `KA.pauseColour` write in `level6_raster`. Optionally cap the
  napalm white ramp at 50% in the display LUT. The per-frame temporal limiter shader is not done (see Rejected).
- **Value/priority:** Low. The host pause (S4) already avoids the strobe.

### S18. Keyboard high-score name entry
- **Value:** Saves dozens of joystick presses per game over. Modest, since it happens once per game.
- **How:** `enhancements.keyboardNameEntry`, a branch in `k_wait_joy_input` / `k_name_entry` (KernelFlow.swift
  ~244/289) that consumes the ASCII the level-2 handler writes at `$23e4` (A-Z → glyphs $41-$5a, Backspace = $5d,
  Return = $5e). **Pitfall:** Z and Space are joystick fire keys, so the host must suspend the fire mapping for letter
  keys while name entry is active (F1).

---

## Tier M: medium

### M1. Pause menu overlay
- **Value:** In-game access to Resume, Quick Save/Load, Retry from checkpoint, Restart section, Objectives, Message
  log, Controls, Options and Abort to title, usable in full screen and with a pad.
- **How:** Esc opens it (the game never polls Amiga ESC $45), and so does a long press on the pad Menu button. The
  menu is built on F3, with the emulation paused and audio ducked. Abort = `tapKey(0x46)`. Restart section =
  `host.reset(startSection:carry:)`, which is only honest for load sections. Section 0 restart means a new game, and
  restarting section 1 from the flare screen returns to the tunnels, so the labels must say so. Snapshot-based
  restart (L1) fixes this later.
- **Risk:** Host-only.

### M2. Objectives, briefings and numeric HUD
- **Value:** The game never says what to do. For example: explosives on level 4 before the bridge; torch (hut 0) for
  the trap door; map in hut 2 after killing the guard; 8 flares from tunnel rooms 0 and 8, with the exit in room 9;
  fire all 8 flares; 5 grenade hits on Barnes, then walk into the bunker.
- **How:** Opt-in, with spoiler tiers. A skippable briefing card shows during the section intro text screen, drawn by
  the host, without changing the wait. A live checklist per section reads: `$28(a6)` explosives, `$60c9c` bridge,
  `$60cbd` torch, `$24(a6)` map, `$26(a6)` compass, `$2c(a6)` flares, S1 item bits `$19a38`, S2 `$57f45`, Barnes HP
  (byte 0 of slot 4, `$57e6a`), timer BCD `$6c/$6d(a6)`. An optional numeric HUD shows ammo, grenades, wounds per man
  (a6+6*i) and morale %.
- **Depends on:** F1 and F3. Read-only.

### M3. Tunnel automap with fog of war
- **Value:** Fixes the tunnels' biggest frustration. Exploration knowledge belongs to the player and survives a
  soldier's death.
- **How:** Opt-in. Sample `posX/posY` (`$1a0b0/$1a0b1`) and facing `$2a(a6)` every frame. Draw the explored cells of
  the 43x43 maze `$29720` (2 = corridor, 3 = room) with an arrow. Rooms are numbered on visit, with their taken items
  (4 flares, $11 compass, $15 real exit "needs 8 flares"). A "reveal all" spoiler is available. Detect a life restart
  by position returning to (0x15, 3) or via `$3b236`. **Variant B (gameplay hook):** draw the explored cells *inside*
  the original map window when no map is carried, by substituting a blank tile before the `s1_drawMap` cache compare
  and forcing the map layout (colLeft 0). This must skip `s1_mapScrollAnim` when already at 0.
- **Hooks:** Host overlay first (read-only). Variant B is behind a flag, checked by comparing frames with the real map
  against the original.

### M4. Tunnels fairness: keep items, flare-night retry, checkpoint respawn
- **Value:** Currently every tunnel death resets the flares, compass, a map found in the tunnels, all room item bits
  and the position (21,3). A death in the flare night sends you back through the whole maze.
- **How:** Three toggles. (1) **Keep items:** skip the resets in `s1_tunnelsRestart` (Section1.swift ~209). The
  **softlock** the review found must be handled: the flare night consumes flares (Flare.swift:149), and a death there
  runs the same restart, so kept taken-bits plus fewer than 8 flares make the exit refuse you. (2) **Flare-night
  retry:** a death in the flare night restarts at `s1_flareEnter`, with the flare count saved at flare entry and the
  next man. This is required whenever keep-items is on. (3) **Checkpoint respawn:** respawn at the entry cell
  (`$19aec`) of the last room entered.
- **Risk:** Guarded writes in the restart path. Tag runs (S5).

### M5. Final-jungle navigator
- **Value:** The 12x10 room grid with heading-relative exits and a 2:00 timer is almost impossible to learn by trial
  (shortest route L R L R L R L R R L R L R L).
- **How:** Three opt-in levels. (1) Heading always shown: either host-drawn, or the one-write `$26(a6) = 1` compass
  assist at S2 start, which also changes hint 0 to "GET GOING!". This is labelled a mild assist. (2) Breadcrumb grid
  of visited rooms with position and heading. (3) Guide: "take the LEFT/RIGHT exit", computed by BFS over (room,
  heading) using the exact `trans_left/trans_right` rol/ror-by-8 rotation of the dirs long `$18f40`. The room map is at
  `$18ea4`, exits per type at `$18f2e`, current room at `$18f1c`, bunker type 16. Plus a "walk to the far end first"
  reminder (depth ≥ $5a).
- **Hooks:** frameHook watching `$18f1c`; no tickPoint needed. Compute from RAM (the disk is the only data source),
  and validate offline against `maze_graph.json`.

### M6. Jungle and village mini-map
- **Value:** 6 strips × 90 columns, with paths only at certain columns and a boxed-in start (the exit is the down-path
  at col 13). Finding the explosives on level 4 and the single village access is trial and error.
- **How:** Opt-in overlay, toggled with M or from the pause menu. A schematic is precomputed from `$1b000 +
  level*$10e + row*90 + col` at section start, with solid cells using the same attribute test as `s0SolidAt`. Path
  tiles 3/4 are marked, the bridge patch at `$1b209/$1b20a` is tracked, and a player marker comes from `$60c26/$60c28`
  (use `$60c2a` plevel where the original does). Spoiler tiers: layout / + items (explosives L4 cols 49-53, bridge
  cols 71-72, doom col 78) / + hut contents from `$1aaf4`/`$1aafa` (torch, trap door, guard + map, booby traps, shown
  as "already sprung" once fired).
- **Hooks:** Read-only. Shares F3 with M2.

### M7. Controls window and rebinding
- **Value:** WASD, left-handed layouts, controller remaps, a dead-zone setting (0.4 is hard-coded today), and help
  text generated from the live bindings.
- **How:** Replaces the NSAlert. Lists logical actions (directions, Fire, Amiga SPACE, Change soldier, Yes, No, Pause,
  Music/FX, Abort, HELP, keypad minus), with up to two keys plus a controller element each. Presets: Original,
  Separate fire/SPACE (S3), one-handed left and right (from M13). Captures modifier keys (flagsChanged). Default =
  today's tables, and a unit test asserts identical mapping.
- **Hooks:** `InputManager` static tables become instance tables loaded from `Settings`; `AppDelegate.showControls`.

### M8. Auto-checkpoints and "Retry from checkpoint"
- **Value:** Sensible resume points for players who don't want to manage quick saves: explosives found, bridge blown,
  village street, each hut, tunnel room entries and pickups, flare-loop start, every final-jungle room and the bunker.
- **How:** Opt-in. Checkpoints are taken at the first loop head after a trigger (explosives `$12e06`, `$60c9c` == 2,
  hut `$60c40`, S1 `$3b230` toggles and item bits, S2 `$18f1c` change). Keep a **ring** of checkpoints (the last 3
  beats plus section start), because a single rolling checkpoint can be taken at a doomed moment (bridge pcol ≥ $4e
  with bridge == 0; S2 with 3 s left). Start with a pause-menu item and hotkey; a modal death overlay can come later.
  Detect deaths from RAM in frameHook (man hits == 4, morale 0).
- **Depends on:** L1. Runs are tagged (S5).

### M9. Rewind
- **Value:** Undo an unseen tripwire, a spider-hole VC, a mine, or a wrong tunnel turn a few seconds after it happens.
- **How:** Opt-in. A ring of loop-head snapshots paced by `m.frameCount` (not by ticks: S0 ticks every 2-3 frames, S1
  every 4, S2 up to 50 Hz), e.g. one every ~1 s for 30 s. Full 512 KB copies are fine (~16 MB); delta compression is
  unnecessary. Store a downscaled canvas thumbnail per snapshot. While Backspace (Amiga $41, never polled) or a
  shoulder button is held, scrub through the thumbnails, then do a single restore on release. Audio is muted while
  scrubbing.
- **Depends on:** L1. Runs are tagged.

### M10. Difficulty presets (Recruit / Original / Veteran / Custom)
- **Value:** Lets newcomers see Barnes, and gives experts a harder game. Original stays bit-exact.
- **How:** `enhancements.difficulty` tuning table. Every hook reads `difficulty?.x ?? <literal>` and never adds or
  removes a `k_random()` call. Useful knobs: jungle shoot chance (`s0EnSt2Walk & 0x1f`), hit morale (-$800 S0 /
  -$c00 S1), tunnel spawn delay `(r & 0x31) + 0x10`, S2 timer (BCD: 3:00 = $300), S2 soldiers per room (`k_random() &
  7` masked or clamped after the call), Barnes HP $32 and cooldown `(r & 0xf) + 0xa`, men's grenades/ammo (all three
  init sites together, plus the ammo caps `== / >= 0x90`), spider-hole rifle kills. **Reviewer corrections:** the
  jungle morale drain barely matters (~24 min to empty), so tune hits and villager kills instead. The final-jungle
  timer only bites when the player is lost (the route takes ~32 s). **Custom** absorbs the sensible challenge
  modifiers: Ironman (men 1-4 start KIA, `$22(a6) = 1` at S1/S2 start), No map, Rifle only (grant 5 grenades at the
  bunker), Pacifist village, half starting morale. The preset is shown on the "ENTERING THE COMBAT ZONE" screen, not
  queued as a HUD message.
- **Testing:** Original vs no preset gives a byte-identical tickdump. Recruit must still complete via the honest-play
  scripts. Enhancements are copied at `PlatoonGame.main`, so changing the preset requires a reset.

### M11. Practice mode
- **Value:** Drills for the bridge, the tunnel exit, the flare night and Barnes, without replaying 10+ minutes.
- **How (phase 1, no snapshots):** reuse `k_start_new_game(section:)` + carry. Patch RAM after load:
  - Jungle positions go in long `$1a6da` (the F1-F4 warp values `$00050001 / $002d0004 / $00410001 / $00410000`).
  - "Before the bridge with explosives" needs a hook after `sec0_start` clears `$24-$2c(a6)`, in `s0RestartInit`.
  - Flare night uses `s1_flareCheatEntry`-style entry with 8 flares.
  - Bunker: poke start room `$18174` and dirs `$18f44`.

  On game over, `m.jump` back to the checkpoint instead of `k_game_over`, with no hiscore write. Shows a PRACTICE tag
  and an attempt counter. **Phase 2:** with L1, practice checkpoints can be snapshots generated at runtime from
  deterministic headless input scripts. No RAM images are shipped.
- **Risk:** Flag-gated patches and a game-over redirect.

### M12. Ghost voices: music survives sound effects
- **Value:** Keeps Whittaker's full in-game arrangement (songs 2, 4, 5, 6) during firefights.
- **How:** Opt-in. At the 6 `if !sfxOwns()` sites in `md_channelTick` and the 2 in `md_effects`, feed the dropped
  music writes to 4 host-only ghost Paula channels. The shadow block `$4084+12*ch` is always written, so it can be
  mirrored. A ghost is audible only while its hardware channel is owned by an SFX, and it goes silent exactly when
  `md_sfx_chan` restores from the shadow, to avoid doubling. Ghosts never call `raiseInterrupt` and never go through
  `chip.write`. Handle `md_noteCommitTie`'s unconditional DMA-on without restarting a voice that is already running.
  Optional music duck.
- **Testing:** `--reglog`/audcmp identical with the flag on and off; `--wav` of combat scripts.

### M13. Motor accessibility pack
- **How (host-only):** toggle-hold for fire and each direction (tap UP to keep walking in the tunnels and final
  jungle); auto-fire pulse, at least 1 tick on and 1 off (~3-4 frames each; valuable for the S2 one-shot-per-press
  rifle `$57f52`, and period-authentic); one-handed presets (WASD + Q SPACE, E Alt, R Y, F N; mouse-driven crosshair
  with L2; half-controller). Default off.
- **Hooks:** `InputManager.sync`, using F1 to apply auto-fire per section.

### M14. Explicit jump and crouch buttons (gameplay option)
- **Value:** In the jungle, UP means door, up-path or jump depending on position, and DOWN means down-path or crouch.
  Mis-gestures cause deaths: walking onto a path instead of jumping a tripwire, or dropping a level instead of
  ducking.
- **How:** Two host-only Input bits (not written into `v0.input`), tested at the top of `s0PlSt0Walk` after the align
  check under `enhancements.explicitJumpCrouch`. Jump calls `s0PlStartJump` (take-off direction from held left/right,
  as the original does). Crouch must be re-asserted every tick while held. UP/DOWN then only take paths and doors.
  This is a rule change: it allows jumping on path tiles and at doors, so document it and tag runs.
- **Testing:** Flag-off tickdump identical; flag-on headless tripwire jumps on path tiles.

### M15. Full platoon / extra lives
- **Value:** Men kept alive in the jungle matter later, instead of S1 and S2 re-initialising all records and using
  only 2 men.
- **How:** Two variants. (a) **Lives slider** (simpler): allow N men (2..5) in S1/S2 by replacing the hard-coded
  `$22(a6) == 1` / `a6+6` second-man logic with "next record with hits < 4". (b) **Full platoon:** also skip the S1/S2
  re-init loops so wounds, ammo and KIA carry over. `k_section_start_body` must then pick a living man
  (`curMan = a6`). The switch uses S1/S2's own ONE MORE CHANCE text screens.
- **Hooks:** `section1_start` (~180), `s1_killedInAction` (Section1Engine), `s2_fj_entry` (FinalJungle.swift:24-29),
  `s2_second_chance` (Foxhole.swift:206). S2 becomes much easier (each death restarts at room 105 with a fresh 2:00),
  so tag runs.
- **Testing:** PLATOON_CARRY files with different KIA patterns.

### M16. Event bus features: speedrun timer and local "Service Record"
- **Value:** Splits and personal bests for a short, well-routed game; medals that point players to content they would
  otherwise miss (ROMAN EMPIRE book, suicide message, all 5 men at the trap door, Barnes with exactly 5 grenades, win
  with ≥1:00 left).
- **How:** Built together on F2 + frameHook RAM polling.
  - **Timer:** emulated frames minus host pause and TAB pause (`$10eaa` != 0).
  - **Splits:** `$28(a6)`, `$60c9c` == 2, torch/map, section loads, flare win, S2 room type `$57f44` == 0, Barnes HP
    byte 0, `s2_game_won` (tickPoint $17c0a). Optional LiveSplit export; PBs per category (Original / preset / fixes
    / full platoon).
  - **Medals:** stored in Application Support, shown in a sheet. Toasts are off by default so default play is
    unchanged. Messages that repeat are deduplicated. "Five for Five" is read at the kill tick, before the phantom '.'
    grenades.
- **Risk:** Observer only.

### M17. Input replays
- **Value:** Watch your best run, verify scores, attach replays to bug reports.
- **How:** The port is already fully deterministic: `interruptedD1` is never assigned, so the vblank RNG term is
  constant. Recording the per-frame Input state and key events from power-on reproduces a run. Use the headless
  `--script` format, plus a header with the build hash, ADF hash and GameConfig (enhancements, trainer,
  startSection/carry). Playback runs in the app or headless.
- **Risk:** None to game code. Replays of runs that started from a snapshot need the snapshot embedded.

### M18. Preferences window
- **Value:** One home for all the new Game/Assist, Input, Video and Audio options, with sliders instead of fixed menu
  steps.
- **How:** A standard ⌘, window over `Settings.swift` keys. It is only worth building once several M items exist.

### M19. Pixel-art upscaler (one good one)
- **Value:** Smooth edges on the 64x48 jungle tiles and the room pictures at 4K/5K, as an alternative to square
  pixels.
- **How:** Presentational. Pass 1 point-samples every other hires texel to 320 lowres (every screen is BPLCON0 $4200
  lowres). Pass 2 runs **MMPX** (single pass, easier on the heavy ordered dither than xBRZ). Pass 3 is the existing
  aspect/integer/CRT. An optional sharp HUD uses per-line region masks, because the split and the DIW origin differ
  per section. Sharp stays the default.
- **Depends on:** S1.

### M20. CRT preset pack
- **Value:** 1084S (slot mask, bloom), PVM (aperture grille), A520 composite (chroma bleed), Custom.
- **How:** A mask-size uniform tied to output resolution; the current fixed 3-px mask moirés at 1080p/1440p.
  Optional phosphor persistence via a ping-pong previous-frame texture, decaying per emulated frame. It is sold as a
  look: it does **not** fix the 25 Hz jungle judder. Composite needs a multi-pass shader. Add an optional 1084/PAL
  gamma/phosphor colour LUT and tag the layer's colour space; this is cheap.
- **Risk:** Shader only.

### M21. Colour-vision presets and HUD magnifier
- **How:** Canvas colours are exact nibble*17 values, so the shader can recover the 12-bit Amiga colour and apply a
  4096-entry LUT (deuteranopia, protanopia, tritanopia). No Chipset change is needed. A **HUD magnifier** (a second
  draw of the HUD sub-rect beside the game) is easy and the most useful part for low-vision players. High-contrast HUD
  text needs the per-section split line as a uniform, which is fiddly, so it comes last.
- **Risk:** Display-only.

### M22. Audio robustness: dynamic rate control, latency, slow-motion
- **Value:** No clicks when turbo or VRR pacing changes. A latency setting. And the **game speed 60-100%**
  accessibility option (host `frameTime` only), which is the single biggest help for slower reactions.
- **How:** Replace block-dropping in `AudioOutput.push` (fill > 3x target) with ±0.5% resampling based on ring fill.
  Slow-motion needs resampling or time-stretch, or accepts a pitch drop. Tag slow-motion runs.
- **Risk:** Host-only.

### M23. Bring-your-own disk import and health check
- **Value:** Needed before any distribution (build_app.sh currently bundles the ADF). Also catches bad dumps, e.g.
  the Darc crack's track-127 picture corruption, before section 2 rather than in it.
- **How:** Drag-and-drop onto the window or Dock icon, or a file picker. The image is copied to Application
  Support/Platoon/Platoon.adf (already a `loadDisk` candidate, so no security-scoped bookmark is needed).
  Per-section track hashes for known dumps (21-76, 77, 84-110, 111-158) and a check that the picture-5 decode ends at
  $301a2. Repair from a second dump is offered only for identified cracks. `DIST=1` in build_app.sh drops the ADF
  copy and adds CFBundleDocumentTypes for .adf. Developer ID + notarization, not the App Store.
- **Hooks:** `Disk.validate` (Disk.swift:30, today two byte checks), `AppDelegate.loadDisk`.

### M24. Gameplay video/GIF capture
- **How:** AVAssetWriter fed from the uploaded canvas plus the Paula output stream, and a configurable screenshot
  folder or clipboard (today the Desktop only). Host-only.

### M25. Lower-priority cosmetic and audio items (build only if wanted)
- **Final-jungle directional room slide:** render the new room from the background bitplanes during the ~12 decode
  frames and finish before the palette is set, so it never shows frames the game isn't at. Detect via `$18f1c` and
  `$2a(a6)` in frameHook. Cosmetic.
- **Tunnel turn slide:** only on heading changes. Forward steps already animate via the walk-phase frames.
  Presentation only; it isn't what makes the tunnels disorienting.
- **Band-limited Paula synthesis (BLEP):** reduces aliasing on the PWM instrument 5 and the synth waves. Keep the
  current output as "Legacy" so captures still match. The A500 LED-filter model is pointless here (see Rejected).
- **Per-section ambience** (tunnel echo, night air) on the SFX stem via AVAudioUnitReverb. It needs S10's stem split
  and may sound muddy on 8-bit samples.
- **User-supplied replacement soundtrack:** poll `$12cce` / `$66(a6)` / `$2d98` in frameHook and mute the
  music-tagged voices. Nothing is bundled (licensing). Tune 3 is a one-shot.
- **Faster key-event delivery** (host flag, off in headless): `deliverKey` paces one event per 3 frames, so bursts of
  SPACE/Alt/Y/N lag 6-9 frames.

---

## Tier L / XL: big projects

### L1. Quick save / quick load at main-loop heads (foundation F5)
- **Value:** Platoon has no saves, and one mistake undoes 10-25 minutes.
- **How:** Opt-in by use. The host sets a request flag; the game thread takes the snapshot at the next loop head
  (`$17186`, `$171c6`, `$18bd8`, `$17118`) via a GameConfig callback, because `Platoon` isn't reachable from GameHost.
  The UI says "saving at next opportunity" when on a text, man-select or trap-door screen. 3-5 slots with a canvas
  thumbnail, section name and score, stored in Application Support/Platoon/saves/ with a format tag (build hash + ADF
  checksum).
- **State to capture:**
  - RAM: the full `$00000-$7FFFF`.
  - Chipset: regs/dmacon/intena/intreq/adkcon and the copper.
  - CIA-A and CIA-B **including TOD, alarm, icr, timers, tickAcc and todLatched**. The level-6 split is the CIA-B TOD
    alarm; without it `k_wait_swap` hangs.
  - Paula channel state.
  - Platoon host vars: cpuCycles, irqDepth/irqPreempted/irqBusyUntil, musicPlaying, loadedSection, interruptedD1,
    cpuBusy, s2PaceIndex.
  - Clear the Input key queue.
- **Restore:**
  - Build a fresh Machine (as `GameHost.reset` does).
  - Reinstall the interrupt closures from the RAM vectors: `k_install_vectors`, the level-2 handler, and the S2 fade
    hook when `mem[$6c]` == `S2.l3HookFade`.
  - Re-register the section dispatch.
  - `m.jump` into new loop-entry wrappers. S0: `s0RegisterDispatch(); while true { s0MainLoop(); s0RestartInit() }`.
    S1: the tunnel loop without `s1_tunnelsRestart`. The flare and S2 loops are already `-> Never`.
  - Add `Machine.start(atLine:)`, or accept a 1-frame shift for mid-frame loop heads.
- **Platform impact:** A small public snapshot API on Machine/Chipset/Paula/CIA (the fields are partly internal).
  Announce it in STATUS.md.
- **Testing (mandatory):** A headless round-trip mode: run `--deterministic` to frame N, snapshot, restore into a new
  Machine, continue, and compare `--tickdump` against an uninterrupted run with `tools/tickcmp.py`, in each of the
  four loops. Loaded games are tagged (S5).
- **Effort:** L. Unlocks M8, M9 and practice phase 2.

### L2. Pointer and analog aiming for the crosshair sections
- **Value:** The tunnel combat, room search and flare dugout are crosshair games steered with a digital stick whose
  speed ramps and overshoots, at 12.5 Hz.
- **How:** (a) **Assisted** (host-only, keeps the original pacing): read the crosshair from RAM each frame (tunnels
  `$19d34/$19d36`, flare `$19eac+2/+4`) and press the virtual stick towards the mouse/touch point. Release inside the
  `crossSpeed $1a0ae` step window. Move one axis at a time because of the flare up-skips-left branch. Right stick =
  proportional speed. Left click = fire through `Input.fire`, right click = SPACE in the flare section. (b) **Direct**
  (`enhancements`, a difficulty change): set x/y directly in `s1_inCombat` / `s1_inRoom` / `s1_hFlareCrosshair` with
  the original clamps.
- **Pitfalls:** Canvas-to-crosshair calibration per mode (the +9,+9 centre, aspect/scale; verify from screenshots).
  A merge layer is needed because `InputManager.sync` overwrites Input. F1 is needed for context.
- **Testing:** A headless synthetic-target script; tickdump identical with it off.

### L3. Randomiser (village and tunnels only)
- **Value:** Brings back exploration once the route is known.
- **How:** A seeded, opt-in option. Patch RAM at `k_section_start_body` (the disk data is reloaded per section).
  Village: swap msg/msg2 bytes of torch, map and trap entries among `$1aafa` search spots. Leave furniture-flavour
  entries and the two dead entries alone; the map stays gated by the hut-2 guard. Tunnels: swap item lists `$19a38`
  between rooms of the same picture type. The EXIT stays in a type-3 room and both flare boxes stay reachable. The
  final-jungle bunker relocation is **dropped** (see Rejected). Runs are tagged.

### L4. Widescreen jungle (host-rendered side columns)
- **Value:** Fills 16:9 in the longest section. Marginal: the ambient backdrop (S14) gets most of the benefit.
- **How:** Re-render background-only tile columns from `$1b000` map / `$1c000+n*$600` tiles beside the 320 px window,
  with a fog gradient. Enemies stay in the centre. **Hard part:** latch the scroll vars (`$60c24/$60c34/$60cb2/$60c26`)
  at the buffer swap, not at frame end, or the sides tear by a tick. Disable it for dissolves, man select, hut level 5
  and other sections. The result is T-shaped (the HUD stays 320 wide) and it gives a small navigation advantage, so
  it is off by default.

### XL1. iPad / Apple TV target
- **Value:** PlatoonCore imports only Foundation and zlib, and touch aiming would suit the crosshair sections.
- **Blockers:** ADF import (tvOS has no user file system), rewriting all AppKit code (AppDelegate, GameView,
  InputManager keycodes → GCKeyboard HID), and sideload-only distribution. It is a separate project; note it, don't
  schedule it.

---

## Considered and rejected

- **Smooth 50 Hz jungle via interpolated half-ticks.** There is no spare buffer: tick N+1 draws while N is shown. It
  would need a third buffer, a full redraw off the clock, and extrapolation that jitters on turns and stops. XL for
  presentation only.
- **"Hyper" 50 Hz jungle logic.** It is just a turbo that doubles game speed, and ⌘T turbo already exists.
- **True flare lighting in the dugout.** The flare object is gone before the palette lighting starts, so there is
  nothing to light from. Brightening near-black enemies also changes the challenge.
- **HD HUD/text layer.** XL and fragile: glyphs would have to be tracked across double buffers, fades and clears. Integer
  scaling or the upscaler already makes 8x8 text clean.
- **Game Center achievements and leaderboards.** Needs a team-signed App ID and App Store Connect for a fan port of a
  copyrighted game. The local Service Record (M16) covers it.
- **iCloud sync of scores, Continue slot and settings.** Needs a ubiquity entitlement and team signing. The Dock menu
  (S12) is kept.
- **App Store / sandboxed distribution.** The translated code itself is Ocean's program. Keep a Developer ID direct
  download (M23).
- **App Intents / Shortcuts.** A gimmick for this app; the Dock menu is enough.
- **Score attack with invented end-of-section bonuses.** These are new scoring rules. Only per-mode tables (S5) are
  kept.
- **Seeded daily challenge.** There is no online component, and RNG call order diverges with player actions, so
  "same game" doesn't hold. Replays (M17) are kept.
- **Flag-based "skip non-interactive sequences".** It needs about 8 set/clear sites in translated `-> Never` code for
  small savings. Hold-to-fast-forward (S11) replaces it.
- **"Fire skips message waits".** It writes the text counters, which changes frame counts and therefore the RNG. Not
  outcome-identical.
- **"Hold messages longer".** The queue is capped at 4, so longer holds drop more messages and delay code that waits
  on msgCount. The message log (S8) does this job.
- **"Napalm clock in every section" modifier.** S0/S1 have no time-up handling or ending, and the jungle and village
  take far longer than 2:00.
- **Final-jungle bunker relocation (randomiser).** The maze is a tree where every branch already ends in a bunker, and
  room types encode the heading exits. It would need a regenerated grid.
- **Run-ahead / latency reduction via savestates.** Needs snapshots at arbitrary points, which aren't serialisable
  (the game-thread stack).
- **Photosensitivity temporal-limiter shader.** It could hide enemy muzzle flashes, which are the threat cue, and the
  pause strobe is below flash thresholds. The one-line steady-pause hook (S17) is kept.
- **Accurate A500 LED-filter model.** The driver switches the LED filter off at every song init and SFX trigger, so it
  is never heard. BLEP resampling (M25) is kept.
- **DualSense adaptive-trigger ammo resistance and wound light bar.** Gimmicks. Basic rumble (S13) is kept.
- **Tunnel forward-step zoom.** It fights the original walk-phase frames. Turn slide (M25) is kept as optional.
- **Amiga '.' grenade key on LB.** Redundant: fire already throws grenades in the bunker.
- **Rewind delta compression / RAM-diff assumptions.** Unnecessary (full copies are ~16 MB), and the premise was
  wrong: bitplanes, copper, music vars and map patches change every tick.
- **Sticky turbo persistence by default.** At 4x, AudioOutput drops chunks. Momentary fast-forward (S11) replaces it.
- **"Ctrl = fire" bindings.** Ctrl+arrow keys belong to macOS Mission Control and Spaces.
