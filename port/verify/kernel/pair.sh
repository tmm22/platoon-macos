#!/bin/bash
# usage: pair.sh NAME SCRIPT FRAMES SHOTEVERY [extra args for both tools...]
# Runs tools/amiga/emu and platoon-headless with the same script; outputs in /tmp/verify-kernel/NAME/{emu,port}
# then compares all PNGs (cmpshots.py). Extra args are passed to both tools (e.g. --deterministic,
# --tickdump PC LO LEN FILE with FILE containing @ which is replaced by emu/port).
R=/Users/deborahmangan/Projects/Platoon
N=$1; S=$2; F=$3; K=$4; shift 4
O=/tmp/verify-kernel/$N; rm -rf $O; mkdir -p $O/emu $O/port
EA=(); PA=()
for a in "$@"; do EA+=("${a//@/emu}"); PA+=("${a//@/port}"); done
( cd $R && ./tools/amiga/emu --adf re/platoon_port.adf --frames $F --script $S --out $O/emu --shot-every $K "${EA[@]}" > $O/emu.log 2>&1 ) &
( cd $R/port && PLATOON_ENH=${PLATOON_ENH:-originalCredits=0} ${PORTBIN:-/tmp/pbuild-kernel/release/platoon-headless} --adf ../re/platoon_port.adf --frames $F --script $S --out $O/port --shot-every $K "${PA[@]}" > $O/port.log 2>&1 ) &
wait
python3 $R/port/verify/kernel/cmpshots.py $O/emu $O/port
