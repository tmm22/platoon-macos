# Verification evidence and test harnesses

Everything here checks the port against the original game or checks that an optional feature leaves the default
game untouched. The one command that must pass after any change under `PlatoonCore` is the regression gate,
`tools/regress_all.sh` (see [../PORTING.md](../PORTING.md#regression-gate)).

## Translation evidence (port vs the original in `tools/amiga/emu`)
| File | Covers |
|---|---|
| [kernel.md](kernel.md) | boot, title, HUD, section flow, game over, high scores (tools in `kernel/`) |
| [section0.md](section0.md) | jungle and village (harness and scripts in `section0/harness/`) |
| [section1.md](section1.md) | tunnels and flare night (tools in `section1/`) |
| [section2.md](section2.md) | final jungle, bunker and endings (scripts in `section2/`) |
| [timing.md](timing.md) | real-A500 speed and Paula model, calibrated against the cycle-exact vAmiga |

These logs record how each module was verified. They were run with the emulator's timing (today
`--enh referenceEmulator=1`). Several harnesses work in scratch copies under `/tmp/verify-<module>/` (copy the
module's folder there first); the scenario scripts the gate still uses are in this tree.

## Feature tests (run in the background)
| Path | Checks |
|---|---|
| `snapshot/roundtrip.sh` ([README](snapshot/README.md)) | save states, rewind and checkpoint retry replay byte-identically |
| `audio/wavcmp.sh`, `audio/enhtests.sh`, `audio/app/apptest.sh` | default audio output unchanged; mixer, ghost voices, BLEP, ambience, soundtrack |
| `input/run.sh` | bindings, presets, controller, motor-accessibility options, aiming |
| `presentation/selftest.sh` | renderer, filters, colour vision, flash limiter, side columns, recording |
| `assist/runapp.sh` ([README](assist/README.md)) | message log, objectives, timer, replays, practice in the app |
| `section0/enh/features.py` | jungle and village options |
| `enh-section1/s1test.py`, `enh-section1/roundtrip.sh`, `enh-section1/runapp.sh` | tunnels and flare-night options |
| `section2/enh/run_enh.py`, `section2/enh/app/run_app.sh` | final-jungle options, navigator, room slide |
| `cheats/run_cheats.py` | every cheat in every section, with control runs |
| `qa/kitchen.py`, `qa/xsection_travel.sh` | many options at once (no crash or hang); rewinds across a section change |
