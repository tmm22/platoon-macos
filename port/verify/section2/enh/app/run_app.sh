#!/bin/bash
# App-level test of the M25 room slide and the M5 navigator panel (owner: section2).
# usage: run_app.sh PLATOON_APP PLATOON_HEADLESS [OUT]   (~5 min; run in the background)
# Makes two final-jungle savestates with the headless runner (a left exit from the start room, a right exit on the
# honest route), plays each exit in the app with navigator level 3 + room slide on, dumps every slide frame
# (PLATOON_S2SLIDE_DUMP) and checks them (check_slide.py); navigator captures (room3/hidden/inside/level1.png) are
# written for a visual check. The app binary is copied under another name so its UserDefaults domain is private
# (PLATOON_DEBUG_FRESH_PREFS of concurrent app runs would otherwise reset the prefs mid-test).
set -u
APP=$1; HL=$2; OUT=${3:-/tmp/enh-section2/apptest}
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/../../../../.." && pwd)
ADF=$ROOT/re/platoon_port.adf
rm -rf "$OUT"; mkdir -p "$OUT/saves" "$OUT/bin"
cp "$APP" "$OUT/bin/PlatoonS2Test"
"$HL" --adf "$ADF" --deterministic --script "$H/pre_left.txt" --frames 1030 --snapshot-save 1025 "$OUT/saves/slot1.pltsnap" --out "$OUT/hl1" | tail -1
"$HL" --adf "$ADF" --deterministic --script "$ROOT/port/verify/section2/honest1.txt" --frames 1090 --snapshot-save 1084 "$OUT/saves/slot2.pltsnap" --out "$OUT/hl2" | tail -1
run() {  # run NAME SCRIPT SLOT
    local o=$OUT/$1; mkdir -p "$o"; echo "60 load $3" > "$OUT/ss_$1.txt"
    env PLATOON_ADF="$ADF" PLATOON_DEBUG_FRESH_PREFS=1 PLATOON_SAVES_DIR="$OUT/saves" \
        PLATOON_DEBUG_SAVESTATES="$OUT/ss_$1.txt" PLATOON_S2NAV_DEBUG=1 PLATOON_SUPPORT_DIR="$OUT/support" \
        PLATOON_S2SLIDE_DUMP="$o/dump" PLATOON_DEBUG_SCRIPT="$2" PLATOON_DEBUG_CAPTURE="$o" \
        "$OUT/bin/PlatoonS2Test" > "$o/stdout.txt" 2>&1 &
    local pid=$!; ( sleep 150; kill $pid 2>/dev/null ) & wait $pid
}
run left "$H/left.txt" 0
run right "$H/right.txt" 1
rc=0
python3 "$H/check_slide.py" "$OUT/left/dump" || rc=1
python3 "$H/check_slide.py" "$OUT/right/dump" || rc=1
grep -q "Final-jungle route guide" "$OUT/right/stdout.txt" && echo "PASS route guide marks the run assisted" || { echo "FAIL assisted mark"; rc=1; }
grep -q "heading without the compass" "$OUT/right/stdout.txt" && echo "PASS heading without compass marks the run assisted" || { echo "FAIL heading mark"; rc=1; }
for f in room3 hidden inside level1; do [ -f "$OUT/right/$f.png" ] || { echo "FAIL missing capture $f"; rc=1; }; done
[ $rc = 0 ] && echo "APP TEST PASS" || echo "APP TEST FAIL"
exit $rc
