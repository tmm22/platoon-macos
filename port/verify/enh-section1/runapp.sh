#!/bin/bash
# App-level test of the section-1 overlays (M3 tunnel map, M25 turn slide) through the app's debug script driver.
# usage: runapp.sh PLATOON_APP_BINARY [SCRIPT] [OUTDIR]
# Captures (<name>.png = game + overlay composited, <name>_game.png, <name>_overlay.png) and log.txt go to OUTDIR;
# look at map1/map2 (fog of war), reveal/corner (spoiler + placement), hidden (M key), turn_* (slide frames).
# The app runs in real time: on a busy machine it can take several minutes (killed after KILL_AFTER s, default 480).
BIN=$1; S=${2:-$(dirname $0)/app_tunnelmap.txt}; out=${3:-/tmp/enh-section1/app/run}
rm -rf "$out"; mkdir -p "$out"
env PLATOON_ADF=$(cd $(dirname $0)/../../.. && pwd)/re/platoon_port.adf PLATOON_DEBUG_FRESH_PREFS=1 \
    PLATOON_SUPPORT_DIR=$out/support PLATOON_PREFS="section1.tunnelMap=1,section1.turnSlide=1" \
    PLATOON_DEBUG_SCRIPT=$S PLATOON_DEBUG_CAPTURE=$out "$BIN" > $out/stdout.txt 2>&1 &
pid=$!
( sleep ${KILL_AFTER:-480}; kill $pid 2>/dev/null ) &
wait $pid; echo "EXIT $?" >> $out/stdout.txt
ls $out/*.png 2>/dev/null | wc -l | xargs echo "captures:"
