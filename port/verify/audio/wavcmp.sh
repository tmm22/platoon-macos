#!/bin/bash
# Audio default-output gate (OWNER: audio). Renders WAVs with the pinned pre-enhancement baseline binary and with
# NEWBIN (all options at their defaults, plus referenceEmulator=1: the emulator's Paula instead of the real-A500
# model, see port/verify/timing.md) and compares them byte for byte. Expect IDENTICAL for every scenario.
#   wavcmp.sh NEWBIN OUTDIR [EXTRA_ENH]
# With EXTRA_ENH (e.g. audio.ghostVoices=1) the new binary gets those options too (expect DIFFERENT then).
# BASEBIN defaults to the regression gate's cached baseline build (tools/regress_all.sh builds it once).
# Takes ~1-2 min; run it in the background.
NEW=$1; OUT=$2; EXTRA=${3:-}
[ -z "$NEW" ] || [ -z "$OUT" ] && { echo "usage: wavcmp.sh NEWBIN OUTDIR [EXTRA_ENH]"; exit 2; }
BASE=${BASEBIN:-/tmp/regress-cache/baseline-716172f/build/release/platoon-headless}
R=$(cd "$(dirname "$0")/../../.." && pwd)
H=$R/port/verify/audio
ADF=$R/re/platoon_port.adf
[ -x "$BASE" ] || { echo "no baseline binary $BASE (run tools/regress_all.sh once, or set BASEBIN)"; exit 2; }
mkdir -p "$OUT"
ENHN="originalCredits=0,referenceEmulator=1"; [ -n "$EXTRA" ] && ENHN="$ENHN,$EXTRA"
fail=0
run() { # name args...
  local n=$1; shift
  if [ ! -f "$OUT/base_$n.wav" ] || [ -n "$FORCEBASE" ]; then
    (cd "$OUT" && env -i HOME=$HOME PATH=$PATH PLATOON_ENH=originalCredits=0 $BASE --adf $ADF --out "$OUT/o_base_$n" --wav "$OUT/base_$n.wav" "$@" > "$OUT/base_$n.log" 2>&1)
  fi
  (cd "$OUT" && env -i HOME=$HOME PATH=$PATH PLATOON_ENH=$ENHN $NEW --adf $ADF --out "$OUT/o_new_$n" --wav "$OUT/new_$n.wav" "$@" > "$OUT/new_$n.log" 2>&1)
  if cmp -s "$OUT/base_$n.wav" "$OUT/new_$n.wav"; then echo "IDENTICAL $n $(stat -f %z "$OUT/new_$n.wav") bytes"; else echo "DIFFERENT $n"; fail=1; fi
}
run title   --frames 2600 --script $R/tools/regress/kernel/empty.txt
run f10     --frames 1400 --script $R/tools/regress/kernel/f10.txt
run s1combat --frames 3600 --script $R/port/verify/section1/scripts/combat.txt
run s2combat --frames 1900 --script $R/port/verify/section2/combat.txt
run s1flare --frames 3200 --script $R/port/verify/section1/scripts/fl_lit.txt
run mt2     --frames 900 --music-test 2 --script $H/sfxmix.txt
run mt6     --frames 600 --music-test 6 --script $H/sfxmix.txt
run mt0r    --frames 600 --music-test 0 --wav-rate 44100 --no-filter --script $H/sfxmix.txt
run mt4     --frames 700 --music-test 4 --script $H/sfxmix.txt
exit $fail
