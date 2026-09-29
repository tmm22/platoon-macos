#!/bin/sh
# linecmp.sh SCRIPT FRAMES : per-iteration flare head/crosshair line comparison
S=$1; N=$2
PLATOON_ENH=originalCredits=0 S1DBG=1 /tmp/pbuild-section1/release/platoon-headless --adf /Users/deborahmangan/Projects/Platoon/re/platoon_port.adf --script $S --frames $N --out /tmp/verify-section1/lc_p --deterministic 2>&1 | grep -E "fl cross|fl head" > /tmp/verify-section1/port_fl.txt
mkdir -p /tmp/verify-section1/lc_e; /Users/deborahmangan/Projects/Platoon/tools/amiga/emu --adf /Users/deborahmangan/Projects/Platoon/re/platoon_port.adf --script $S --frames $N --out /tmp/verify-section1/lc_e --deterministic --events /tmp/verify-section1/lc_e/ev.txt --bp 18bd8 --bp 19048 --bp 1920c --bp 19212 --bp 191be --bp 191c4 >/dev/null 2>&1
grep BP /tmp/verify-section1/lc_e/ev.txt | awk '{print $4, $1,$2}' | sed 's/\[f//; s/\]//; s/v//' > /tmp/verify-section1/emu_fl.txt
python3 - <<'PY'
e=[l.split() for l in open('/tmp/verify-section1/emu_fl.txt')]
p=[]
for l in open('/tmp/verify-section1/port_fl.txt'):
    t=l.split(); kind='018bd8' if t[1]=='head' else '019048'
    p.append((kind,int(t[2][1:]),int(t[3][1:])))
E=[(k,int(f),int(v)) for k,f,v in e]
import collections
for kind in ('018bd8','019048'):
    A=[x for x in E if x[0]==kind]; B=[x for x in p if x[0]==kind]
    c=collections.Counter(); out=[]
    for i,(a,b) in enumerate(zip(A,B)):
        d=(b[1]-a[1])*313+b[2]-a[2]; c[d]+=1
        if b[1]!=a[1]: out.append((i,a[1:],b[1:]))
    print(kind,len(A),len(B),sorted(c.items())); print('  frame mismatches',out[:15])
PY
