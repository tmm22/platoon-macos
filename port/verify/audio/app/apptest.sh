#!/bin/bash
# App-level audio tests (OWNER: audio). Runs the app (bare binary) with debug scripts and PLATOON_DEBUG_AUDIO_WAV,
# which records the app's final mix (Paula stream + replacement soundtrack after the main mixer).
#   apptest.sh PLATOON_BINARY OUTDIR        (~1.5 min; background it)
# st   replacement soundtrack: a generated 440 Hz song0.wav replaces the title tune (expect 440 Hz share ~1.0 while on,
#      Paula music after the pref is switched off at frame ~490), plus a Preferences › Audio screenshot.
# def / ad  default output timing vs Smooth (adaptive) - silent gaps (dropouts) counted by gaps.py.
BIN=$1; OUT=$2
[ -z "$BIN" ] || [ -z "$OUT" ] && { echo "usage: apptest.sh PLATOON_BINARY OUTDIR"; exit 2; }
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../../.." && pwd)
mkdir -p "$OUT/support/Soundtrack"
python3 - "$OUT/support/Soundtrack/song0.wav" <<'PY'
import numpy as np, struct, sys
r=48000; t=np.arange(r*40)/r; d=np.repeat((0.3*np.sin(2*np.pi*440*t)).astype('<f4'),2).tobytes()
open(sys.argv[1],'wb').write(b'RIFF'+struct.pack('<I',36+len(d))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,2,r,r*8,8,32)+b'data'+struct.pack('<I',len(d))+d)
PY
run() { # script outdir env...
  local s=$1 o=$2; shift 2; rm -rf "$o"; mkdir -p "$o"
  env PLATOON_ADF=$R/re/platoon_port.adf PLATOON_DEBUG_FRESH_PREFS=1 PLATOON_SUPPORT_DIR=$OUT/support \
      PLATOON_DEBUG_SCRIPT=$s PLATOON_DEBUG_CAPTURE=$o PLATOON_DEBUG_AUDIO_WAV=$o/app.wav "$@" $BIN > $o/stdout.txt 2>&1 &
  local pid=$!; ( sleep 120; kill $pid 2>/dev/null ) & wait $pid
}
run $H/st.txt $OUT/st "PLATOON_PREFS=audio.replacementSoundtrack=1,audio.debugLog=1"
run $H/def.txt $OUT/def "PLATOON_PREFS=audio.debugLog=1"
run $H/def.txt $OUT/ad "PLATOON_PREFS=audio.debugLog=1,audio.outputSync=1"
python3 - "$OUT/st/app.wav" "$H/../wavstat.py" <<'PY'
import numpy as np, sys
exec(open(sys.argv[2]).read().split('args = ')[0])
a, r = load(sys.argv[1]); x = a[:, 0].astype(np.float64); row = []
for s in range(int(len(x) / r)):
    seg = x[s * r:(s + 1) * r]; sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2; f = np.fft.rfftfreq(len(seg), 1 / r)
    row.append('%d:%.2f' % (s, sp[(f > 435) & (f < 445)].sum() / (sp.sum() + 1e-30)))
print('soundtrack: 440 Hz share per second:', ' '.join(row))
PY
grep -h "soundtrack=" $OUT/st/stdout.txt | sed 's/^.*soundtrack=/  status: /' | uniq
python3 $H/../gaps.py $OUT/def/app.wav $OUT/ad/app.wav
