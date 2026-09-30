#!/bin/bash
# Audio enhancement functional tests (OWNER: audio; headless, ~3 min, run in the background).
#   enhtests.sh BIN OUTDIR
# 1   the game is unaffected by every audio option: full-RAM hash every frame identical (game runs + driver harness),
#     Paula register log identical;
# 2-8 behaviour of the options (mixer neutrality, ghost voices, BLEP, ambience, pan, volumes), printed as numbers.
B=$1; O=$2
[ -z "$B" ] || [ -z "$O" ] && { echo "usage: enhtests.sh BIN OUTDIR"; exit 2; }
R=$(cd "$(dirname "$0")/../../.." && pwd); H=$R/port/verify/audio; ADF=$R/re/platoon_port.adf
S=$H/wavstat.py; MIX=$H/sfxmix.txt; NOSFX=$H/nosfx.txt
mkdir -p "$O"; cd "$O" || exit 2
fail=0
ALL="audio.ghostVoices=1,audio.synthesis=blep,audio.musicVolume=0.7,audio.sfxVolume=1.3,audio.pan0=-0.5,audio.pan2=0.2,audio.ambience=auto,audio.ambienceLevel=1.5"
echo "== 1. game unaffected: full-RAM hash every frame, all audio options on vs defaults"
for sc in "s1combat 3600 $R/port/verify/section1/scripts/combat.txt" "s2combat 1900 $R/port/verify/section2/combat.txt" "f10 1400 $R/tools/regress/kernel/f10.txt"; do
  set -- $sc
  env -i PATH=$PATH HOME=$HOME PLATOON_EVENTS=/dev/null PLATOON_ENH=originalCredits=0 $B --adf $ADF --out o_h --frames $2 --script $3 --hash 0 80000 --wav h_def_$1.wav > h_def_$1.txt 2>&1
  env -i PATH=$PATH HOME=$HOME PLATOON_EVENTS=/dev/null PLATOON_ENH=originalCredits=0,$ALL $B --adf $ADF --out o_h --frames $2 --script $3 --hash 0 80000 --wav h_all_$1.wav > h_all_$1.txt 2>&1
  if cmp -s h_def_$1.txt h_all_$1.txt; then echo "PASS $1 RAM hashes identical ($(grep -c hash h_def_$1.txt) frames)"; else echo "FAIL $1 RAM hashes differ"; fail=1; fi
  if cmp -s h_def_$1.wav h_all_$1.wav; then echo "FAIL $1 wav identical (options had no effect)"; fail=1; else echo "  wav differs as expected"; fi
done
echo "== 1b. driver harness (music-test 2 with sfx bursts, all options): RAM + register log"
env -i PATH=$PATH HOME=$HOME $B --adf $ADF --out o_h --frames 900 --music-test 2 --script $MIX --hash 0 80000 > mh_def.txt 2>&1
env -i PATH=$PATH HOME=$HOME PLATOON_ENH=$ALL $B --adf $ADF --out o_h --frames 900 --music-test 2 --script $MIX --hash 0 80000 > mh_all.txt 2>&1
if cmp -s mh_def.txt mh_all.txt; then echo "PASS harness RAM identical"; else echo "FAIL harness RAM differs"; fail=1; fi
env -i PATH=$PATH HOME=$HOME $B --adf $ADF --out o_h --frames 900 --music-test 2 --script $MIX --reglog rl_def.txt > /dev/null 2>&1
env -i PATH=$PATH HOME=$HOME PLATOON_ENH=$ALL $B --adf $ADF --out o_h --frames 900 --music-test 2 --script $MIX --reglog rl_all.txt > /dev/null 2>&1
if cmp -s rl_def.txt rl_all.txt; then echo "PASS register log identical ($(wc -l < rl_def.txt | tr -d ' ') writes)"; else echo "FAIL register log differs"; fail=1; fi

mt() { # name enh args...
  local n=$1 e=$2; shift 2
  env -i PATH=$PATH HOME=$HOME PLATOON_ENH=$e $B --adf $ADF --out o_m --wav $n.wav "$@" > $n.log 2>&1
}
echo "== 2. mixer path with neutral settings ~ legacy (sfxVolume=0.999999): expect corr ~1"
mt legacy_mt2 "" --frames 900 --music-test 2 --script $MIX
mt neutral_mt2 "audio.sfxVolume=0.999999" --frames 900 --music-test 2 --script $MIX
python3 $S legacy_mt2.wav neutral_mt2.wav | tail -3
echo "== 3. ghost voices: music-only reference vs the same run with sfx (sfx muted), without / with ghosts"
echo "   (frames that differ from the music-only reference; with ghosts expect ~100 % identical samples: the ghost"
echo "    plays while the effect owns the channel and until the music next retriggers the voice)"
mt ref_mt2 "" --frames 900 --music-test 2 --script $NOSFX
mt hole_mt2 "audio.sfxVolume=0" --frames 900 --music-test 2 --script $MIX
mt ghost_mt2 "audio.sfxVolume=0,audio.ghostVoices=1" --frames 900 --music-test 2 --script $MIX
echo "-- without ghosts:"; python3 $S ref_mt2.wav hole_mt2.wav --from 2 --to 16 --runs | tail -4
echo "-- with ghosts:";    python3 $S ref_mt2.wav ghost_mt2.wav --from 2 --to 16 --runs | tail -4
mt ghostsfx_mt2 "audio.ghostVoices=1" --frames 900 --music-test 2 --script $MIX
echo "-- ghosts + sfx (normal use) vs legacy:"; python3 $S legacy_mt2.wav ghostsfx_mt2.wav --from 2 --to 16 | tail -3
echo "== 4. BLEP vs legacy (no A500 filter): high band share (lower = less aliasing)"
mt leg_mt6 "" --frames 600 --music-test 6 --no-filter --script $NOSFX
mt blep_mt6 "audio.synthesis=blep" --frames 600 --music-test 6 --no-filter --script $NOSFX
python3 $S leg_mt6.wav blep_mt6.wav | tail -5
mt leg_mt0 "" --frames 600 --music-test 0 --no-filter --script $NOSFX
mt blep_mt0 "audio.synthesis=blep" --frames 600 --music-test 0 --no-filter --script $NOSFX
python3 $S leg_mt0.wav blep_mt0.wav | tail -5
echo "== 5. ambience auto in a real run: identical to the default until the section is played"
env -i PATH=$PATH HOME=$HOME PLATOON_EVENTS=/dev/null PLATOON_ENH=originalCredits=0,audio.ambience=auto $B --adf $ADF --out o_a --frames 3600 --script $R/port/verify/section1/scripts/combat.txt --wav amb_auto_s1.wav > /dev/null 2>&1
python3 $S h_def_s1combat.wav amb_auto_s1.wav --runs | tail -1 | cut -c1-120
echo "== 6. fixed tunnels ambience on sfx: wet energy (music-only run must stay identical: music is dry)"
mt amb_tun_mt2 "audio.ambience=tunnels" --frames 900 --music-test 2 --script $MIX
python3 $S legacy_mt2.wav amb_tun_mt2.wav | tail -3
mt amb_tun_nosfx "audio.ambience=tunnels" --frames 900 --music-test 2 --script $NOSFX
python3 $S ref_mt2.wav amb_tun_nosfx.wav | grep diff
echo "== 7. stereo pan: voices 1+2 hard left (pan1=-1,pan2=-1): expect R rms 0"
mt pan_mt2 "audio.pan1=-1,audio.pan2=-1" --frames 900 --music-test 2 --script $NOSFX
python3 $S pan_mt2.wav | tail -1
echo "== 8. volumes: music 0 leaves only sfx (silent between effects); sfx 0 on a music-only run = reference"
mt nomusic_mt2 "audio.musicVolume=0" --frames 900 --music-test 2 --script $MIX
python3 $S nomusic_mt2.wav | tail -1
python3 $S nomusic_mt2.wav --from 1 --to 1.9 | tail -1
mt nosfx_vol0 "audio.sfxVolume=0" --frames 900 --music-test 2 --script $NOSFX
python3 $S ref_mt2.wav nosfx_vol0.wav | grep diff
[ $fail = 0 ] && echo "RESULT: PASS (checks 1/1b); read 2-8 for behaviour" || echo "RESULT: FAIL"
exit $fail
