#!/usr/bin/env python3
"""adaptive flare-section script builder (emu feedback). usage: flbot.py BASE_SCRIPT OUT_SCRIPT START_FRAME END_FRAME [--noflares]"""
import sys, struct, subprocess, os
ROOT='/Users/deborahmangan/Projects/Platoon'
EMU=ROOT+'/tools/amiga/emu'; ADF=ROOT+'/re/platoon_port.adf'
base, outp, X, END = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
noflares='--noflares' in sys.argv
CH=int(os.environ.get('CHUNK','60'))
lines=open(base).read().splitlines()
W='/tmp/verify-section1/flbot'; os.makedirs(W,exist_ok=True)
def run(lines, frames):
    sp=W+'/s.txt'; open(sp,'w').write('\n'.join(sorted(lines,key=lambda l:int(l.split()[0])))+'\n')
    for f in os.listdir(W):
        if f.endswith('.td'): os.remove(W+'/'+f)
    subprocess.run([EMU,'--adf',ADF,'--script',sp,'--frames',str(frames),'--out',W,'--deterministic',
        '--tickdump','18bd8','12dde','78',W+'/g.td','--tickdump','18bd8','19e0a','208',W+'/o.td',
        '--tickdump','18bd8','3b220','20',W+'/v.td'],capture_output=True)
    def recs(p,L):
        d=open(p,'rb').read(); return [(struct.unpack('<I',d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(len(d)//(4+L))]
    return recs(W+'/g.td',0x78), recs(W+'/o.td',0x208), recs(W+'/v.td',0x20)
w16=lambda b,o: (b[o]<<8)|b[o+1]
while X<END:
    G,O,V=run(lines, X+2)
    heads=[f for f,_ in G]
    if not heads or heads[-1]<X-4: print('no flare iterations near',X, heads[-1:] ); break
    g=G[-1][1]; o=O[-1][1]; v=V[-1][1]
    flares=w16(g,0x2c); light=v[0x11]; hits=w16(g,4)
    en=[]
    for k in range(2,7):
        r=o[k*18:(k+1)*18]
        if r[0] and struct.unpack('>I',r[10:14])[0]!=0x1925a: en.append((w16(r,2),w16(r,4)))
    print(X,'flares',flares,'light',light,'hits',hits,'enemies',en, flush=True)
    # next safe frame: F-1 head, F not head; heads alternate with the parity of the last head
    par=heads[-1]%2
    def safe(f):
        while f%2!=(par+1)%2: f+=1
        return f
    f=safe(X)
    for (ex,ey) in en:
        lines.append(f'{f} poke 19eae {ex+6:x} 2'); lines.append(f'{f} poke 19eb0 {ey+3:x} 2')
        lines.append(f'{f} fire 1'); lines.append(f'{f+4} fire 0'); f=safe(f+8)
    if not noflares and light==0 and flares>0:
        lines.append(f'{f} key 0x40 1'); lines.append(f'{f+6} key 0x40 0')
    X+=CH
open(outp,'w').write('\n'.join(sorted(lines,key=lambda l:int(l.split()[0])))+'\n')
