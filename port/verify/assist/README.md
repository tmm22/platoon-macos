# Assist feature tests

- Unit tests (headless models, game runs with --deterministic): `swift test --filter AssistTests`
  (speech text, message log folding, final-jungle run through timer / splits / LiveSplit / service record /
  objectives / HUD / log, record -> replay byte-identical per frame (app player and headless script), every
  practice drill resumes where it should and is healed).
- App: `./runapp.sh overlays OUT` starts a deterministic section-2 game (`newgame 2 det`), feeds
  `final_s2.plreplay` in as the player (`inject … game`) with captions, objectives (full solution), numeric HUD,
  timer, briefing and speech on; writes state.txt (context + objectives + HUD + timer per checkpoint), log.txt,
  speech.txt, rec.plreplay (the recording; replays headless to the same frames: `platoon-headless --script
  OUT/rec.plreplay --frames 2570 --start-section 2 --deterministic`), record.json (+ window PNG) and captures
  (briefing, play1/2, bunker, won, log).
  Expected: timer `won` with splits s2.bunker/s2.barnes/s2.huey, record gamesWon 1, sectionsCompleted [0,0,1],
  bestScore assisted 1500.
- `./runapp.sh practice OUT`: prepares and starts the Bridge drill (jungle level 4 with the explosives, wounds
  healed) and the Barnes drill, retries on death (attempt counter), the practice chooser from the pause menu, and
  Preferences shots of the Gameplay (difficulty summary) and Assist pages.
