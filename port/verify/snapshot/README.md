# Savestate verification (roadmap F5/L1, M8, M9)

`roundtrip.sh [s0 s1t s1f s2]` (run in the background, ~15 min) runs each scenario uninterrupted with the
pre-enhancement binary (`BASEBIN`) and then with the binary under test (`BIN`), and compares the full-RAM FNV
hash of every frame, tick dumps at the four loop heads ($12dde+$78 and $5f880+$40), screenshots every 97 frames
and the WAV output:

| phase | runs | must be |
|---|---|---|
| rt | `plain` (no options), `rtevery` (`--roundtrip-every 211`: snapshot, encode/decode, abandon the machine at the capture point, continue in a fresh Machine), `rtinplace` (`--roundtrip-every 307 --roundtrip-inplace`), `capture` (`--rewind-ring --checkpoints`) | byte-identical to base |
| travel | `--rewind-at N BACK`, `--retry-at N` (jump back and replay the same script) | every frame hash equal to base's for that frame; tick dumps = base segments (`travelcheck.py`) |
| file | `--snapshot-save N FILE` in one process, `--snapshot-load FILE` in another | as travel |

Scenarios: s0 = section-0 honest route jungle -> village (13000 frames, `--start-section 0`), s1t = tunnel combat,
s1f = flare night, s2 = honest final jungle -> bunker. Env: `PHASES="rt travel file"`, `REUSE_BASE=1`, `OUT`.
