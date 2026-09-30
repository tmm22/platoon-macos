#!/bin/bash
# Presentation feature tests (owner: presentation). Usage:
#   port/verify/presentation/selftest.sh APP HEADLESS [OUTDIR]     (APP = the Platoon binary, HEADLESS = platoon-headless)
# 1. makes 8 test pictures with the headless runner (jungle, tunnels, tunnel hit, flare night / lit, final jungle,
#    napalm, title) and snapshots just before a tunnel hit, the flare light-up and the napalm strike;
# 2. PLATOON_VIDEO_TEST: offscreen renderer + recorder tests in the app -> OUTDIR/selftest/report.txt (PASS/FAIL),
#    look_*.png / zoom_*.png (every filter and CRT preset at 1080p/1440p/2160p) for visual review;
# 3. app runs from the snapshots with S13/S16/S17 on (and off for comparison) -> OUTDIR/<run>/*_game.png,
#    OUTDIR/<run>_fx.log (effect events), the final-jungle sniper cue on/off, and a recording run (M24) whose files are verified -> OUTDIR/rec/video.log.
# Takes about 8 minutes. Run it in the background.
set -u
APP=$1; HL=$2; OUT=${3:-/tmp/enh-presentation/verify}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ADF=$ROOT/re/platoon_port.adf; V=$ROOT/port/verify
rm -rf "$OUT"; mkdir -p "$OUT/in" "$OUT/h" "$OUT/saves"
cp "$APP" "$OUT/Platoon"; cp "$HL" "$OUT/platoon-headless"; APP=$OUT/Platoon; HL=$OUT/platoon-headless
hl() { "$HL" --adf "$ADF" --deterministic "$@"; }
printf '100 fire 1\n105 fire 0\n200 fire 1\n205 fire 0\n300 fire 1\n305 fire 0\n' > "$OUT/h/j.txt"
hl --frames 700 --start-section 0 --script "$OUT/h/j.txt" --out "$OUT/h/j" --shot-every 100 > "$OUT/h/j.log" 2>&1
hl --frames 2000 --out "$OUT/h/t" --shot-every 1000 > "$OUT/h/t.log" 2>&1
hl --frames 1130 --script "$V/section1/scripts/death.txt" --out "$OUT/h/d" --shot-every 25 --snapshot-save 1060 "$OUT/saves/slot1.pltsnap" > "$OUT/h/d.log" 2>&1
hl --frames 1830 --script "$V/section1/scripts/fl_lit.txt" --out "$OUT/h/f" --shot-every 20 --snapshot-save 1690 "$OUT/saves/slot2.pltsnap" > "$OUT/h/f.log" 2>&1
hl --frames 6960 --script "$V/section2/napalm.txt" --out "$OUT/h/n" --shot-every 50 --snapshot-save 6850 "$OUT/saves/slot3.pltsnap" > "$OUT/h/n.log" 2>&1
cp "$OUT/h/j/f000700.png" "$OUT/in/a_jungle.png"; cp "$OUT/h/d/f000925.png" "$OUT/in/b_tunnel.png"
cp "$OUT/h/d/f001125.png" "$OUT/in/c_tunnelhit.png"; cp "$OUT/h/f/f001460.png" "$OUT/in/d_flarenight.png"
cp "$OUT/h/f/f001820.png" "$OUT/in/e_flarelit.png"; cp "$OUT/h/n/f001250.png" "$OUT/in/f_final.png"
cp "$OUT/h/n/f006950.png" "$OUT/in/g_napalm.png"; cp "$OUT/h/t/f002000.png" "$OUT/in/h_title.png"

run() { # run NAME TIMEOUT ENV... : the app with a fresh preferences domain, killed after TIMEOUT s
  local n=$1 t=$2; shift 2; mkdir -p "$OUT/$n"
  env PLATOON_ADF="$ADF" PLATOON_DEBUG_FRESH_PREFS=1 PLATOON_DEBUG_CAPTURE="$OUT/$n" PLATOON_SAVES_DIR="$OUT/saves" "$@" \
      "$APP" > "$OUT/$n/stdout.txt" 2>&1 &
  local pid=$!; ( sleep "$t"; kill $pid 2>/dev/null ) & wait $pid
}
run selftest 240 PLATOON_VIDEO_TEST="$OUT/selftest" PLATOON_VIDEO_TEST_INPUT="$OUT/in"

scr() { f=$OUT/$1; shift; printf '%s\n' "$@" > "$f"; }
caps() { local p=$1; shift; for f in "$@"; do echo "frame $f"; echo "capture $p$f"; done; echo quit; }
scr hit_ss.txt '+120 load 0'; caps t 1062 1090 1100 1110 1120 1130 1140 > "$OUT/hit_dbg.txt"
scr flare_ss.txt '+120 load 1'; { echo "frame 1757"; echo "capture f1757"; echo "frame 1785"; echo "key 31 tap"; caps f 1790 1800 1810 1830; } > "$OUT/flare_dbg.txt"
scr napalm_ss.txt '+120 load 2'; caps n 6860 6930 6960 6990 > "$OUT/napalm_dbg.txt"
ON=presentation.reduceFlashing=1,presentation.nightLift=1,presentation.shake=2,presentation.hitEdgeTint=1
for s in hit flare napalm; do
  run "$s" 90 PLATOON_DEBUG_SAVESTATES="$OUT/${s}_ss.txt" PLATOON_DEBUG_SCRIPT="$OUT/${s}_dbg.txt" PLATOON_VIDEO_LOG="$OUT/${s}_fx.log" PLATOON_PREFS=$ON
  run "${s}_off" 90 PLATOON_DEBUG_SAVESTATES="$OUT/${s}_ss.txt" PLATOON_DEBUG_SCRIPT="$OUT/${s}_dbg.txt"
done
# S13 sniper cue: section 2 from the start, fire through the intro text, stand still until the idle shot
{ echo "wait 30"; echo "reset 2"; echo "frame 800"; echo "key 31 tap"; echo "frame 900"; echo "key 31 tap"
  echo "frame 1195"; echo "capture s1195"; echo "frame 1300"; echo "capture s1300"; echo quit; } > "$OUT/sniper_dbg.txt"
run sniper 100 PLATOON_DEBUG_SCRIPT="$OUT/sniper_dbg.txt" PLATOON_VIDEO_LOG="$OUT/sniper_fx.log" PLATOON_PREFS=presentation.sniperCue=1
run sniper_off 100 PLATOON_DEBUG_SCRIPT="$OUT/sniper_dbg.txt" PLATOON_VIDEO_LOG="$OUT/sniper_off_fx.log"
scr rec_vid.txt '+200 record movie' '+250 stop' '+60 record gif' '+120 stop' '+60 copyshot' '+20 menushot'
scr rec_dbg.txt 'wait 800' 'quit'
run rec 60 PLATOON_RECORD_DIR="$OUT/rec/files" PLATOON_SCREENSHOT_DIR="$OUT/rec/shots" PLATOON_DEBUG_SCRIPT="$OUT/rec_dbg.txt" PLATOON_VIDEO_SCRIPT="$OUT/rec_vid.txt"

echo "== selftest"; cat "$OUT/selftest/report.txt"
for s in hit flare napalm; do echo "== $s: $(grep -c . "$OUT/${s}_fx.log" 2>/dev/null) effect events"; head -3 "$OUT/${s}_fx.log" 2>/dev/null; done
echo "== sniper cue: on $(grep -c 'sniper cue' "$OUT/sniper_fx.log" 2>/dev/null) / off $(grep -c 'sniper cue' "$OUT/sniper_off_fx.log" 2>/dev/null) events"
echo "== recording"; cat "$OUT/rec/video.log"
grep -q "ALL PASS" "$OUT/selftest/report.txt" && ! grep -q FAIL "$OUT/rec/video.log" && grep -q "menushot: ok" "$OUT/rec/video.log" && [ -s "$OUT/hit_fx.log" ] && [ -s "$OUT/napalm_fx.log" ] \
  && grep -q "sniper cue" "$OUT/sniper_fx.log" && ! grep -q "sniper cue" "$OUT/sniper_off_fx.log" \
  && echo "PRESENTATION SELFTEST PASS" || { echo "PRESENTATION SELFTEST FAIL"; exit 1; }
