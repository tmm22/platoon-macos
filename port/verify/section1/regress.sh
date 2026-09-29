#!/bin/sh
# final regression: all section-1 scenarios, emu vs port
cd /tmp/verify-section1
run() { n=$1; s=$2; fr=$3; pcs=$4; se=$5
  python3 vr.py R_$n $s $fr --pcs $pcs --shot-every $se >/dev/null 2>&1
  echo "=== $n ($s, $fr frames)"; python3 cmp.py R_$n --noshots | grep -v "emu 0 port 0"; python3 shotdiff.py R_$n 600 | cut -c1-400; }
run idle idle.txt 2200 171d8 20
run death death.txt 5600 171d8,170c4 25
run room0 room0.txt 2900 171d8 20
run combat combat.txt 3600 171d8,170c4 20
run misc misc.txt 4400 171d8,170c4 20
run exit exit.txt 3400 171d8,18bd8 20
run honest honest.txt 2300 171d8 20
run wrap wrap.txt 2300 171d8 20
run nohelp nohelp.txt 1300 171d8 20
run keys keys.txt 2000 171d8,170c4 10
run fl_help fl_help.txt 3400 171d8,18bd8 20
run fl_idle fl_idle.txt 5200 171d8,18bd8 20
run flmove flmove.txt 2800 171d8,18bd8 20
run fl_lit fl_lit.txt 3200 171d8,18bd8 20
run flq1 flq1.txt 4200 171d8,18bd8 25
run flp2 flp2.txt 7400 17118,18bd8 20
run tour tour.txt 21400 171d8,18bd8 8
echo ALLDONE
