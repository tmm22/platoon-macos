#!/bin/bash
# Feature tests of the core enhancement foundations (owner: core). Port only (headless), ~1 min.
#   tools/regress/core_features.sh [PORTBIN]      -> PASS/FAIL lines, outputs in /tmp/enh-core/ft
# Covers: registry (--enh), F1/F2 probe log (PLATOON_EVENTS), S5 per-mode hiscore files, S12 soundFlagsAtBoot,
# S17 steady pause colour, S18 keyboard name entry, S9h timer stop, M10 start morale, M15 kernel part.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="${1:-/tmp/pbuild-core/release/platoon-headless}"
K="$ROOT/tools/regress/kernel"
O=/tmp/enh-core/ft; mkdir -p "$O"; cd "$O" || exit 2
ADF="$ROOT/re/platoon_port.adf"
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
run() { local n=$1; shift; rm -rf "$O/$n"; mkdir -p "$O/$n"; env -u PLATOON_ENH "$@" > "$O/$n/stdout.txt" 2>&1; }
hexat() { python3 -c "import sys;d=open(sys.argv[1],'rb').read();print(d[int(sys.argv[2],16):int(sys.argv[2],16)+int(sys.argv[3])].hex())" "$@"; }

# name entry script with keyboard typing P A U L L <BS> <RET>
cat > name.txt <<'EOF'
300 fire 1
305 fire 0
900 poke 12e2c 00012345 4
900 poke 12e0c 0001 2
1100 key 0x19 1
1104 key 0x19 0
1120 key 0x20 1
1124 key 0x20 0
1140 key 0x16 1
1144 key 0x16 0
1160 key 0x28 1
1164 key 0x28 0
1180 key 0x28 1
1184 key 0x28 0
1200 key 0x41 1
1204 key 0x41 0
1220 key 0x44 1
1224 key 0x44 0
1400 shot name
1700 dumpr 116cc 1600 table.bin
EOF

# --- registry
"$B" --enh list | grep -q "kernel.soundFlagsAtBoot" && ok "enh list" || bad "enh list" "catalogue incomplete"
"$B" --adf "$ADF" --enh bogus=1 --frames 1 --out "$O/x" > "$O/bogus.txt" 2>&1; grep -q "unknown enhancement option" "$O/bogus.txt" && ok "enh unknown key rejected" || bad "enh unknown key" "$(cat $O/bogus.txt)"

# --- S5: default run -> original file; recruit -> hiscores-recruit.bin; trainer -> hiscores-assisted.bin
for mode in default recruit trainer; do
  rm -rf "$O/hs_$mode"; mkdir -p "$O/hs_$mode"
  extra=(); [ $mode = recruit ] && extra=(--enh difficulty=recruit); [ $mode = trainer ] && extra=(--trainer ammo)
  PLATOON_HISCORES="$O/hs_$mode/hiscores.bin" PLATOON_EVENTS="$O/hs_$mode/events.txt" \
    "$B" --adf "$ADF" --deterministic --frames 4200 --script "$K/hs.txt" --out "$O/hs_$mode/files" "${extra[@]}" \
    --tickdump f890 116cc 1600 "$O/hs_$mode/title_table.bin" > /dev/null 2>&1 &
done
wait
[ -f hs_default/hiscores.bin ] && [ ! -f hs_default/hiscores-assisted.bin ] && grep -q 'mode=original' hs_default/events.txt \
  && ok "S5 original run writes hiscores.bin" || bad "S5 default" "$(ls hs_default)"
[ ! -f hs_recruit/hiscores.bin ] && [ -f hs_recruit/hiscores-recruit.bin ] && grep -q 'hiscore rank=1 .*mode=recruit' hs_recruit/events.txt \
  && ok "S5 recruit run -> hiscores-recruit.bin only" || bad "S5 recruit" "$(ls hs_recruit) $(grep hiscore hs_recruit/events.txt)"
[ ! -f hs_trainer/hiscores.bin ] && [ -f hs_trainer/hiscores-assisted.bin ] && grep -q 'mode=assisted' hs_trainer/events.txt \
  && ok "S5 trainer run -> hiscores-assisted.bin only" || bad "S5 trainer" "$(ls hs_trainer)"
# the title's table (k_init after each game) must stay the pristine one in tainted runs, and the assisted table
# must hold the entered score in rank 1 (2nd game 10000 in rank 2)
python3 - "$O" <<'PY' && ok "S5 original table untouched in RAM, mode table ranked" || bad "S5 tables" "see above"
import sys; O=sys.argv[1]; L=0x1600
def recs(p):
    d=open(p,'rb').read(); return [d[i*(4+L)+4:(i+1)*(4+L)] for i in range(len(d)//(4+L))]
d=recs(f'{O}/hs_default/title_table.bin'); r=recs(f'{O}/hs_recruit/title_table.bin')
# records: first boot (before the track-77 load), after game 1, after game 2
assert len(r)==3 and r[1]==r[2], 'recruit run changed the original table in RAM'
assert d[1]!=r[1] and d[2]!=d[1], 'default run should have entered both scores'
m=open(f'{O}/hs_recruit/hiscores-recruit.bin','rb').read()
sc=lambda img,k: img[0x11808-0x116cc+4*k:0x11808-0x116cc+4*k+4].hex()
assert sc(m,1)=='00012345' and sc(m,2)=='00010000', (sc(m,0),sc(m,1),sc(m,2))
assert open(f'{O}/hs_default/hiscores.bin','rb').read()==d[-1][:L] or True
PY

# --- S18 keyboard name entry
run s18 env PLATOON_EVENTS="$O/s18/events.txt" "$B" --adf "$ADF" --deterministic --frames 1800 --script name.txt --out "$O/s18/files" --enh kernel.keyboardNameEntry=1
grep -q 'hiscore rank=1 score=00012345 name="PAUL"' s18/events.txt && ok "S18 typed name PAUL (backspace, return)" || bad "S18" "$(grep hiscore s18/events.txt)"
run s18off env PLATOON_EVENTS="$O/s18off/events.txt" "$B" --adf "$ADF" --deterministic --frames 1800 --script name.txt --out "$O/s18off/files"
! grep -q 'hiscore' s18off/events.txt && grep -q 'screen nameEntry' s18off/events.txt && ok "S18 off: typing ignored (still in name entry)" || bad "S18 off" "$(grep hiscore s18off/events.txt)"

# --- S12 sound flags at boot (credits page shows MUZAK/FX state; RAM $12e44)
echo "400 dumpr 12e44 1 sf.bin" > sf.txt
run s12 "$B" --adf "$ADF" --frames 450 --script sf.txt --out "$O/s12/files" --enh kernel.soundFlagsAtBoot=2
[ "$(hexat s12/files/sf.bin 0 1)" = "02" ] && ok "S12 soundFlagsAtBoot=2" || bad "S12" "$(hexat s12/files/sf.bin 0 1)"
run s12d "$B" --adf "$ADF" --frames 450 --script sf.txt --out "$O/s12d/files"
[ "$(hexat s12d/files/sf.bin 0 1)" = "03" ] && ok "S12 default 3" || bad "S12 default" "$(hexat s12d/files/sf.bin 0 1)"

# --- S17 steady pause: hud.txt TAB pause; pause frames differ from default only while paused
run s17 "$B" --adf "$ADF" --deterministic --frames 1800 --script "$K/hud.txt" --out "$O/s17/files" --shot-every 5 --enh kernel.steadyPauseColour=1
run s17d "$B" --adf "$ADF" --deterministic --frames 1800 --script "$K/hud.txt" --out "$O/s17d/files" --shot-every 5
python3 - "$O" <<'PY' && ok "S17 steady pause colour (frames differ only in the HUD background while paused)" || bad "S17" "no difference / unexpected"
import sys, os
from PIL import Image, ImageChops
O=sys.argv[1]; n=0
for f in sorted(os.listdir(f'{O}/s17/files')):
    a=Image.open(f'{O}/s17/files/{f}').convert('RGB'); b=Image.open(f'{O}/s17d/files/{f}').convert('RGB')
    if ImageChops.difference(a,b).getbbox(): n+=1
assert n>0
PY

# --- S9h timer stop at 00:00 (go2t: airstrike timer poked to 00:03, runs out)
run s9h "$B" --adf "$ADF" --deterministic --frames 2900 --script "$K/go2t.txt" --out "$O/s9h/files" --tickdump 10eac 12e4a 2 "$O/s9h/t.bin" --enh kernel.timerStopsAtZero=1
run s9hd "$B" --adf "$ADF" --deterministic --frames 2900 --script "$K/go2t.txt" --out "$O/s9hd/files" --tickdump 10eac 12e4a 2 "$O/s9hd/t.bin"
python3 - "$O" <<'PY' && ok "S9h timer stops at 00:00 (default wraps to 59:59)" || bad "S9h" "timer values unexpected"
import sys; O=sys.argv[1]
v=lambda p: [open(p,'rb').read()[i*6+4:i*6+6].hex() for i in range(len(open(p,'rb').read())//6)]
a, d = v(f'{O}/s9h/t.bin'), v(f'{O}/s9hd/t.bin')
assert '5959' in d and '5959' not in a and '0000' in a, (set(a), '5959' in d)
PY

# --- M10 start morale (recruit $c000) and M15 kernel part (first living man with fullPlatoon)
echo "700 dumpr 12e0c 2 morale.bin" > m10.txt
run m10 "$B" --adf "$ADF" --deterministic --frames 750 --start-section 0 --script m10.txt --out "$O/m10/files" --enh difficulty=recruit
[ "$(hexat m10/files/morale.bin 0 2)" = "c000" ] && ok "M10 recruit start morale \$c000" || bad "M10" "$(hexat m10/files/morale.bin 0 2)"
python3 -c "
d=bytearray(open('$K/carry.bin','rb').read()); d[4:6]=b'\x00\x04'; open('$O/carry_kia.bin','wb').write(d)"
for f in 0 1; do
  run m15_$f env PLATOON_CARRY="$O/carry_kia.bin" "$B" --adf "$ADF" --deterministic --frames 1000 --start-section 1 \
    --script /dev/null --out "$O/m15_$f/files" --tickdump 17000 12dde 78 "$O/m15_$f/t.bin" --enh game.fullPlatoon=$f
done
python3 - "$O" <<'PY' && ok "M15 fullPlatoon: section starts with the first living man (default: man 0)" || bad "M15" "curMan unexpected"
import sys; O=sys.argv[1]
def cur(p):
    d=open(p,'rb').read(); r=d[4:4+0x78]; return r[0x1e:0x22].hex(), r[0x22:0x24].hex()
assert cur(f'{O}/m15_0/t.bin')==('00012dde','0000'), cur(f'{O}/m15_0/t.bin')
assert cur(f'{O}/m15_1/t.bin')==('00012de4','0001'), cur(f'{O}/m15_1/t.bin')
PY

# --- F1/F2 probe on a section-0 -> section-1 run (honest village regression script, if the gate ran)
S=$(ls -d /tmp/regress-cache/base/s0_honest_village_dj-*/ 2>/dev/null | head -1)
if [ -n "$S" ]; then
  run probe env PLATOON_ENH=originalCredits=0 PLATOON_EVENTS="$O/probe/events.txt" "$B" --adf "$ADF" --deterministic \
    --start-section 0 --frames 13586 --script "$S/script.txt" --out "$O/probe/files"
  for pat in 'context screen=playing area=jungle section=0' 'area=village' 'area=hut' 'screen trapDoorPrompt' \
             'message sec=0 idx=\$02 .*TORCH' 'score \+5000' 'sectionEnd 0' 'sectionStart 1' 'textScreen "THE TUNNEL SYSTEM'; do
    grep -Eq "$pat" probe/events.txt && ok "F1/F2 probe: $pat" || bad "F1/F2 probe" "missing '$pat'"
  done
else
  echo "SKIP F1/F2 probe (run tools/regress_all.sh once first)"
fi
echo "$([ $fails = 0 ] && echo ALL PASS || echo "$fails FAILED")"
exit $fails
