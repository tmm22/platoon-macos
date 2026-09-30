#!/bin/zsh
# Input layer self-test ([input] agent): S2 S3 S13 S15 S18 M7 M13 M14 L2.
#   port/verify/input/run.sh [APP_BINARY] [OUTDIR]
# APP_BINARY defaults to /tmp/pbuild-input/release/Platoon (copy it first if you rebuild meanwhile).
# Optional: PLATOON_INPUT_ONLY=s2jungle,m14,trapdoor,s15,m13toggle,m13auto,l2 runs only those game tests.
# Runs the Platoon app with PLATOON_INPUT_TEST: unit tests of the binding / pipeline layer, renders of the
# Controls window and the controller hint (PNG), then game tests on private Machines (the translated game,
# --deterministic, driven through an InputManager exactly like the app). Prints PASS/FAIL lines, writes
# OUTDIR/report.txt, exit 0 = all pass. Takes ~2-3 min; run it in the background.
root=${0:A:h:h:h:h}
bin=${1:-/tmp/pbuild-input/release/Platoon}
out=${2:-/tmp/enh-input/selftest}
rm -rf "$out"; mkdir -p "$out"
env PLATOON_INPUT_TEST="$out" PLATOON_ADF="$root/re/platoon_port.adf" PLATOON_DEBUG_FRESH_PREFS=1 PLATOON_REPO="$root" \
    "$bin" > "$out/stdout.txt" 2>&1 &
pid=$!
( sleep 600; kill $pid 2>/dev/null ) &
wait $pid; rc=$?
grep '^\[input-test\]' "$out/stdout.txt"
echo "EXIT $rc"
exit $rc
