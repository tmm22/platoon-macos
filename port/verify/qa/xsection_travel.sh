#!/bin/bash
# rewind / retry across a section change (1->2), compared with the uninterrupted run
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); ADF=$ROOT/re/platoon_port.adf; B=${BIN:?set BIN=platoon-headless}
OUT=${OUT:-/tmp/qa-xsection}; mkdir -p $OUT
SC=${SC:-$ROOT/port/verify/section2/s1to2.txt}; FR=${FR:-3300}
run() { n=$1; shift; d=$OUT/$n; rm -rf $d; mkdir -p $d
  td=""; for pc in 17186 171c6 18bd8 17118; do td="$td --tickdump $pc 12dde 78 $d/t$pc.bin --tickdump $pc 5f880 40 $d/v$pc.bin"; done
  $B --adf $ADF --deterministic --frames $FR --script $SC --out $d --hash 0 80000 --wav $d/a.wav $td "$@" > $d/log.txt 2>&1
  grep '^frame ' $d/log.txt > $d/hash.txt; }
run base
for spec in "rw1|--rewind-at 2900 6" "rw2|--rewind-at 2900 12" "rw3|--rewind-at 2800 30" "rt1|--retry-at 2900" "rt2|--retry-at 2750,3000"; do
  IFS='|' read n a <<< "$spec"; run $n $a
  echo "$n ($a): $(python3 $ROOT/port/verify/snapshot/travelcheck.py $OUT/base $OUT/$n | tail -1) :: $(grep -E 'rewind|retry|checkpoint' $OUT/$n/log.txt | head -4 | tr '\n' ';')"
done
