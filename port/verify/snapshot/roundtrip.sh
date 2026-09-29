#!/bin/sh
# Savestate regression (roadmap F5/L1, M8, M9): every scenario is run uninterrupted ("base") and with snapshot
# modes; the per-frame FNV hash of ALL chip RAM, the tick dumps at the four loop heads, the screenshots and the WAV
# output must be byte-identical.
#   roundtrip.sh [SCENARIO...]     scenarios: s0 s1t s1f s2 (default all)
# env: BIN (headless binary), OUT (work dir), BASEBIN (binary for the base run, default BIN)
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BIN=${BIN:-/tmp/pbuild-snapshot/release/platoon-headless}
BASEBIN=${BASEBIN:-$BIN}
OUT=${OUT:-/tmp/enh-snapshot/rt}
ADF=$ROOT/re/platoon_port.adf
V=$ROOT/port/verify
export PLATOON_ENH=originalCredits=0
mkdir -p "$OUT"

scen() {   # name -> "frames|script|extra args"
  case $1 in
    s0)  echo "13000|$V/section0/harness/sc/honest_village_dj.port.txt|--start-section 0" ;;
    s1t) echo "3400|$V/section1/scripts/combat.txt|" ;;
    s1f) echo "3200|$V/section1/scripts/fl_lit.txt|" ;;
    s2)  echo "3800|$V/section2/honest1.txt|" ;;
  esac
}

run() {   # bin name mode args...
  b=$1; n=$2; m=$3; shift 3
  IFS='|' read fr sc ex <<EOT
$(scen $n)
EOT
  d=$OUT/$n.$m; rm -rf "$d"; mkdir -p "$d"
  td=""
  for pc in 17186 171c6 18bd8 17118; do td="$td --tickdump $pc 12dde 78 $d/t$pc.bin --tickdump $pc 5f880 40 $d/v$pc.bin"; done
  $b --adf "$ADF" --deterministic --frames $fr --script "$sc" $ex --out "$d" --shot-every 97 --hash 0 80000 \
     --wav "$d/a.wav" $td "$@" > "$d/log.txt" 2>&1
  grep '^frame ' "$d/log.txt" > "$d/hash.txt"
}

same() {   # name modeA modeB -> prints verdict
  a=$OUT/$1.$2; b=$OUT/$1.$3; bad=0
  for f in hash.txt a.wav $(cd "$a" && ls t*.bin v*.bin *.png 2>/dev/null); do
    if ! cmp -s "$a/$f" "$b/$f"; then echo "   DIFF $f"; bad=1; fi
  done
  nt=$(cat "$a"/t*.bin | wc -c | tr -d ' '); nh=$(wc -l < "$a/hash.txt" | tr -d ' ')
  rt=$(grep -c 'round trip\|rewind\|retry' "$b/log.txt")
  if [ $bad = 0 ]; then echo "OK   $1 $3: identical to $2 ($nh frame hashes, $nt tick-dump bytes, $rt snapshot ops)"; else echo "FAIL $1 $3 vs $2"; fi
}

PHASES=${PHASES:-"rt travel file"}
for n in ${@:-s0 s1t s1f s2}; do
  [ -f "$OUT/$n.base/hash.txt" ] && [ "$REUSE_BASE" = 1 ] || run "$BASEBIN" $n base
  case " $PHASES " in *" rt "*) ;; *) continue ;; esac
  run "$BIN" $n plain
  run "$BIN" $n rtevery --roundtrip-every 211
  run "$BIN" $n rtinplace --roundtrip-every 307 --roundtrip-inplace
  run "$BIN" $n capture --rewind-ring --checkpoints
  same $n base plain
  same $n base rtevery
  same $n base rtinplace
  same $n base capture
done

# M9 rewind and M8 checkpoint retry: travel back and replay the same script; every frame must equal the base run.
travel() {   # name mode args...
  n=$1; m=$2; shift 2
  run "$BIN" $n $m "$@"
  r=$(python3 "$ROOT/port/verify/snapshot/travelcheck.py" "$OUT/$n.base" "$OUT/$n.$m" | tail -1)
  j=$(grep -E 'rewind|retry' "$OUT/$n.$m/log.txt" | head -3 | sed 's/^snapshot: //' | tr '\n' ';')
  echo "$r  $n $m: $j"
}
case " $PHASES " in *" travel "*) T=1 ;; *) T=0 ;; esac
[ $T = 1 ] && for n in ${@:-s0 s1t s1f s2}; do
  case $n in
    s0)  travel s0 rewind --rewind-at 4000 10 --rewind-at 9000 25; travel s0 retry --retry-at 8500,12600 ;;
    s1t) travel s1t rewind --rewind-at 2000 7 --rewind-at 3000 3; travel s1t retry --retry-at 2500 ;;
    s1f) travel s1f rewind --rewind-at 2900 12; travel s1f retry --retry-at 3000 ;;
    s2)  travel s2 rewind --rewind-at 1500 5 --rewind-at 2500 20; travel s2 retry --retry-at 2000,3500 ;;
  esac
done

# Snapshot FILES across processes: save at frame N in one run, load in a new process, run on; must equal the base.
case " $PHASES " in *" file "*) F=1 ;; *) F=0 ;; esac
[ $F = 1 ] && for n in ${@:-s0 s1t s1f s2}; do
  case $n in s0) at=6000 ;; s1t) at=2000 ;; s1f) at=2200 ;; s2) at=1600 ;; esac
  run "$BIN" $n filesave --snapshot-save $at "$OUT/$n.pltsnap"
  run "$BIN" $n fileload --snapshot-load "$OUT/$n.pltsnap"
  r=$(python3 "$ROOT/port/verify/snapshot/travelcheck.py" "$OUT/$n.base" "$OUT/$n.fileload" | tail -1)
  echo "$r  $n file: $(grep -h 'saved\|loaded' "$OUT/$n.filesave/log.txt" "$OUT/$n.fileload/log.txt" | sed 's/^snapshot: //' | tr '\n' ';')"
done
