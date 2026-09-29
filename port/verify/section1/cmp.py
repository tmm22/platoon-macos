#!/usr/bin/env python3
"""compare tickdumps and screenshots of a vr.py run. usage: cmp.py NAME [--max N] [--ignore spec]"""
import sys, os, struct, argparse
ap=argparse.ArgumentParser(); ap.add_argument('name'); ap.add_argument('--max',type=int,default=3); ap.add_argument('--ignore',default='')
ap.add_argument('--noshots',action='store_true')
o=ap.parse_args()
out='/tmp/verify-section1/'+o.name
ign=set()
for part in filter(None,o.ignore.split(',')):
    lo,_,hi=part.partition('-'); lo=int(lo,16); hi=int(hi,16) if hi else lo; ign.update(range(lo,hi+1))
def recs(p,L):
    d=open(p,'rb').read(); n=len(d)//(4+L)
    return [(struct.unpack('<I',d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]
for f in sorted(os.listdir(out+'/emu')):
    if not f.endswith('.td'): continue
    pc,lo=f[:-3].split('_'); base=int(lo,16)
    pe=out+'/emu/'+f; pp=out+'/port/'+f
    if not os.path.exists(pp): continue
    import json; L=dict(json.load(open(out+'/meta.json'))['regs'])[lo]
    A=recs(pe,L); B=recs(pp,L)
    nd=0; first=None; fr=[]
    for i,((fa,da),(fb,db)) in enumerate(zip(A,B)):
        diff=[k for k in range(L) if da[k]!=db[k] and base+k not in ign]
        fr.append(fb-fa)
        if diff:
            nd+=1
            if nd<=o.max:
                print(f'  {f} tick {i}: frame E{fa} P{fb}: '+' '.join(f'${base+k:05x}:{da[k]:02x}/{db[k]:02x}' for k in diff[:16]))
    offs=sorted(set(fr))
    print(f'{f}: emu {len(A)} port {len(B)} ticks, {nd} differ; frame offsets P-E: {offs[:8]}{"..." if len(offs)>8 else ""}')
if not o.noshots:
    try:
        from PIL import Image, ImageChops
        es=sorted(x for x in os.listdir(out+'/emu') if x.endswith('.png'))
        same=0; diffs=[]
        for x in es:
            if not os.path.exists(out+'/port/'+x): continue
            a=Image.open(out+'/emu/'+x).convert('RGB'); b=Image.open(out+'/port/'+x).convert('RGB')
            if a.size!=b.size: diffs.append((x,'size')); continue
            bb=ImageChops.difference(a,b).getbbox()
            if bb is None: same+=1
            else:
                n=sum(1 for p in ImageChops.difference(a,b).getdata() if p!=(0,0,0))
                diffs.append((x,n,bb))
        print(f'screens: {same}/{len(es)} identical'); 
        for d in diffs[:12]: print('  ',d)
    except Exception as e: print('pil',e)
