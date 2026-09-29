#!/bin/bash
# usage: run.sh NAME SCRIPT FRAMES [extra-bp...]  -> /tmp/verify-section2/NAME/{e,p}
N=$1; S=$2; F=$3; shift 3
R=/Users/deborahmangan/Projects/Platoon
D=/tmp/verify-section2/$N
rm -rf $D; mkdir -p $D/e $D/p
TD="--tickdump 17118 57e22 270 X/t1.bin --tickdump 17118 12dde 78 X/t2.bin --tickdump 17118 18f1c fc X/t3.bin --tickdump 17118 17226 2 X/t4.bin --tickdump 17118 189d8 8 X/t5.bin --tickdump 170f4 12dde 78 X/t6.bin --tickdump 1770e 12dde 78 X/t7.bin"
BPS="--bp 179fa --bp 17118 --bp 170f4 --bp 17604 --bp 1764e --bp 1770e --bp 1771c --bp 1718a --bp 17c0a --bp 17e96 --bp 17f04 --bp 17f18 --bp 17000 --bp 17068"
for b in "$@"; do BPS="$BPS --bp $b"; done
( cd $R && ./tools/amiga/emu --adf re/platoon_port.adf --frames $F --script $S --out $D/e --deterministic ${TD//X/$D/e} $BPS --events $D/e/ev.txt --shot-every ${SHOT:-0} > $D/e/log.txt 2>&1 ) &
if [ -n "$PACE" ]; then wait; python3 /tmp/verify-section2/mkpace.py $D/e/ev.txt $D/pace.bin; python3 /tmp/verify-section2/mkpace.py $D/e/ev.txt $D/pacepl.bin 0179fa; export S2PACE=$D/pace.bin S2PACELEN=0 S2PACEPL=$D/pacepl.bin; fi
( cd $R && PLATOON_TRACE=1 /tmp/pbuild-section2/release/platoon-headless --adf re/platoon_port.adf --frames $F --script $S --out $D/p --deterministic ${TD//X/$D/p} --shot-every ${SHOT:-0} > $D/p/log.txt 2>&1 ) &
wait
cd $D
for t in 1 2 3 4 5 6 7; do
  case $t in 1) L=270 B=57e22;; 2) L=78 B=12dde;; 3) L=fc B=18f1c;; 4) L=2 B=17226;; 5) L=8 B=189d8;; 6) L=78 B=12dde;; 7) L=78 B=12dde;; esac
  echo "t$t: $(python3 /Users/deborahmangan/Projects/Platoon/tools/tickcmp.py e/t$t.bin p/t$t.bin $L --base $B --max 3 ${IGN:+--ignore $IGN} | tr '\n' '|' | cut -c1-600)"
done
grep -o 'BP [0-9a-f]*' e/ev.txt | sort | uniq -c > e/bpc.txt
grep -o 'BP [0-9a-f]*' p/log.txt | sort | uniq -c > p/bpc.txt
diff e/bpc.txt p/bpc.txt > /dev/null && echo "bp counts identical" || { echo "bp counts differ:"; paste e/bpc.txt p/bpc.txt; }
