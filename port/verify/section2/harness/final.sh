#!/bin/bash
cd /tmp/verify-section2
run() { SHOT=$3 ./run.sh F_$1 /tmp/verify-section2/$1.txt $2 > F_$1.out 2>&1; }
run napalm 7300 50 & run fox1 1400 2 & run fox2 1800 4 & wait
run fox4 1400 4 & run morale 1500 4 & run caps 2500 4 & wait
run mines 1300 4 & run wire 1300 4 & run rocks 1300 4 & wait
run combat 1900 4 & run log11 1200 4 & run rock0 1200 4 & wait
run mine5 1200 4 & run wire78 1200 4 & run tele 2900 10 & wait
run tele_wrong 3800 10 & run s1to2 3300 4 & run honest1 3900 4 & wait
run honest2 3400 4
echo done > final.done
