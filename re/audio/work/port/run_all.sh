#!/bin/bash
# Re-runs the audio-port verification: port (platoon-headless) vs replayer.py and vs tools/amiga/emu.
# usage: run_all.sh PLATOON_HEADLESS [WORKDIR]
set -e
B=$1; W=${2:-/tmp/audio-verify}; R=$(cd "$(dirname "$0")/../../../.." && pwd); T=$R/re/audio/work/port
ADF=$R/re/platoon_port.adf; E=$R/tools/amiga/emu
mkdir -p $W && cd $W
if [ -z "$SKIP_LOOPS" ]; then
echo "== songs 0-6, one full loop + 300 frames: register stream + order vs replayer.py"
L=(5633 4481 13825 7169 7681 3073 5569)
for s in 0 1 2 3 4 5 6; do N=$(( ${L[$s]} + 300 ))
  $B --adf $ADF --music-test $s --frames $N --reglog loop$s.reg --out o >/dev/null
  echo "song $s: $(python3 $T/cmp_replayer.py loop$s.reg $N --song $s | tail -1)"; done
fi
echo "== emulator runs (title = song 0 + sample sfx \$80; songs 1-6 via the F10 trick; sfx tests)"
for s in 1 2 3 4 5 6; do printf "400 poke 12cce $s 2\n402 key 0x59 1\n408 key 0x59 0\n422 key 0x59 1\n428 key 0x59 0\n" > emu_song$s.txt; done
run() { $E --adf $ADF --frames $2 ${3:+--script $3} --reglog emu_$1.reg --wav emu_$1.wav --bp 2800 --bp 281c --bp 2838 --bp 10c3a --events emu_$1.ev --out $W/eo_$1 >/dev/null 2>&1; }
run song0 4500; for s in 1 2 3 4 5 6; do run song$s 4500 emu_song$s.txt; done
run sfx 5600 $R/re/audio/work/sfxtest.txt; run sfx3 2600 $R/re/audio/work/sfxtest3.txt
for n in song0 song1 song2 song3 song4 song5 song6 sfx sfx3; do
  F=4500; [ $n = sfx ] && F=5600; [ $n = sfx3 ] && F=2600
  python3 $T/bp2script.py emu_$n.ev > p_$n.txt
  $B --adf $ADF --audio-test --script p_$n.txt --frames $F --reglog p_$n.reg --wav p_$n.wav --wav-rate 44100 --no-filter --out o >/dev/null
  echo "$n registers: $(python3 $T/cmp_emu_reg.py emu_$n.reg p_$n.reg $F | tail -2 | tr '\n' ' ')"
  echo "$n wav: $(python3 $T/cmp_wav.py emu_$n.wav p_$n.wav 126 $F)"
done
echo "== Paula model check (port wav == Python model of Paula.swift; emulator == emu-Paula model at emulator write lines)"
python3 $T/paula_timing.py emu_sfx3.reg emu_sfx3.wav p_sfx3.txt p_sfx3.wav 2600 126
