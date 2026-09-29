#!/bin/bash
# usage: render_test.sh NAME SCRIPTFILE FRAME [STATE]  (script drives the game from STATE; at FRAME the pre-render state is taken)
cd "$(dirname "$0")"; mkdir -p tmp/rt; E=../../tools/amiga/emu; A=../platoon_darc.adf; N=$1
cp $2 tmp/rt/rt_$N.txt; echo "$3 breaksave 172f8 tmp/rt/rt_$N.pre.state" >> tmp/rt/rt_$N.txt
$E --adf $A --load-state ${4:-../states/jungle_start.state} --frames $(( $3 + 50 )) --script tmp/rt/rt_$N.txt --out tmp/rt >/dev/null
printf "0 dump rt_$N.pre.bin\n0 breaksave 17328 tmp/rt/rt_$N.post.state\n" > tmp/rt/rt_$N.b.txt
$E --adf $A --load-state tmp/rt/rt_$N.pre.state --frames 5 --script tmp/rt/rt_$N.b.txt --bp 1920a --bp 17328 --events tmp/rt/rt_$N.ev --out tmp/rt >/dev/null
echo "0 dump rt_$N.post.bin" > tmp/rt/rt_$N.c.txt
$E --adf $A --load-state tmp/rt/rt_$N.post.state --frames 1 --script tmp/rt/rt_$N.c.txt --out tmp/rt >/dev/null
python3 render_sim.py tmp/rt/rt_$N.pre.bin tmp/rt/rt_$N.post.bin tmp/rt/rt_$N.ev tmp/rt/rt_$N.png
python3 -c "
import struct;m=open('tmp/rt/rt_$N.pre.bin','rb').read()
print('  c24=%d c26=%d c34=%d cb0=%d cba=%x' % tuple([struct.unpack('>h',m[a:a+2])[0] for a in (0x60c24,0x60c26,0x60c34,0x60cb0,0x60cba)]))"
