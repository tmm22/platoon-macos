#!/usr/bin/env python3
"""move every poke to the next tunnel tick head frame T >= f (from an emu $171d8 tickdump of the same script),
so that the poke lands before that tick's logic in both tools (see verify note N1). Pokes at frames beyond the
last tunnel tick are left alone. usage: fixpokes.py SCRIPT TICKDUMP_171d8 LEN"""
import sys, struct, bisect
def frames(p,L):
    d=open(p,'rb').read(); return sorted({struct.unpack('<I',d[i*(4+L):i*(4+L)+4])[0] for i in range(len(d)//(4+L))})
sp=sys.argv[1]; T=frames(sys.argv[2],int(sys.argv[3],16))
out=[]; n=0
for l in open(sp).read().splitlines():
    p=l.split()
    if len(p)>1 and p[1]=='poke' and p[2]!='12e4c':
        f=int(p[0]); i=bisect.bisect_left(T,f)
        if i<len(T) and T[i]-f<40 and T[i]!=f: n+=1; l=' '.join([str(T[i])]+p[1:])
    out.append(l)
out.sort(key=lambda l:int(l.split()[0]))
open(sp,'w').write('\n'.join(out)+'\n'); print('moved',n)
