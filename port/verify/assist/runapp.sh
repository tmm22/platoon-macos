#!/bin/bash
# [assist] app-level tests of the assists. Usage: runapp.sh NAME OUTDIR [PLATOON_BINARY]
#   NAME = overlays | practice   (NAME.debug.txt = PLATOON_DEBUG_SCRIPT, NAME.assist.txt = PLATOON_DEBUG_ASSIST)
# Fresh prefs, support dir and saves dir inside OUTDIR; speech muted; the app is killed after 170 s.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../.." && pwd)
out=$2; bin=${3:-/tmp/pbuild-assist/release/Platoon}
rm -rf "$out"; mkdir -p "$out/support"
sed "s#VERIFY/#$here/#g" "$here/$1.assist.txt" > "$out/assist.txt"
env PLATOON_ADF=$root/re/platoon_port.adf PLATOON_DEBUG_FRESH_PREFS=1 \
    PLATOON_SUPPORT_DIR=$out/support PLATOON_SAVES_DIR=$out/saves PLATOON_ASSIST_SILENT=1 \
    PLATOON_DEBUG_SCRIPT=$here/$1.debug.txt PLATOON_DEBUG_ASSIST=$out/assist.txt PLATOON_DEBUG_CAPTURE=$out "$bin" > "$out/stdout.txt" 2>&1 &
pid=$!
( sleep 170; kill $pid 2>/dev/null ) &
wait $pid; echo "EXIT $?" >> "$out/stdout.txt"
