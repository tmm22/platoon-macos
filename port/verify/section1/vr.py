#!/usr/bin/env python3
"""run emu and port with the same script; tickdumps + screenshots; compare.
usage: vr.py NAME SCRIPT FRAMES [--shot-every N] [--pcs 171d8,18bd8] [--only emu|port] [--state FILE]"""
import sys, os, subprocess, argparse, struct
ROOT='/Users/deborahmangan/Projects/Platoon'
EMU=ROOT+'/tools/amiga/emu'; PORT='/tmp/pbuild-section1/release/platoon-headless'
ADF=ROOT+'/re/platoon_port.adf'
REGIONS=[('12d70',0x4),('12dde',0x78),('19a60',0x652),('3b220',0x1dc)]
ap=argparse.ArgumentParser(); ap.add_argument('name'); ap.add_argument('script'); ap.add_argument('frames')
ap.add_argument('--shot-every',default='0'); ap.add_argument('--pcs',default='171d8,18bd8')
ap.add_argument('--only',default=''); ap.add_argument('--regions',default='')
o=ap.parse_args()
regs=REGIONS
if o.regions: regs=[(r.split(':')[0],int(r.split(':')[1],16)) for r in o.regions.split(',')]
out='/tmp/verify-section1/'+o.name
procs=[]
for tool in ('emu','port'):
    if o.only and o.only!=tool: continue
    d=f'{out}/{tool}'; os.makedirs(d,exist_ok=True)
    for f in os.listdir(d):
        if f.endswith('.png') or f.endswith('.td'): os.remove(f'{d}/{f}')
    cmd=[EMU if tool=='emu' else PORT,'--adf',ADF,'--script',os.path.abspath(o.script),'--frames',o.frames,'--out',d,'--deterministic']
    if o.shot_every!='0': cmd+=['--shot-every',o.shot_every]
    n=0
    for pc in o.pcs.split(','):
        for lo,ln in regs:
            if tool=='emu' and n>=8: break
            cmd+=['--tickdump',pc,lo,'%x'%ln,f'{d}/{pc}_{lo}.td']; n+=1
    env=dict(os.environ); env['PLATOON_ENH']='originalCredits=0'
    procs.append((tool,subprocess.Popen(cmd,stdout=open(d+'/log.txt','w'),stderr=subprocess.STDOUT,env=env)))
for t,p in procs: p.wait()
import json; json.dump({'regs':regs},open(out+'/meta.json','w'))
print('done', out)
