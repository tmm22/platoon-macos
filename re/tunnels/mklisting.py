#!/usr/bin/env python3
"""Regenerate tunnels.s: rdis with labels.txt, then append inline comments from icomments.txt."""
import subprocess, os
H=os.path.dirname(os.path.abspath(__file__))
R=os.path.join(H,'..','..')
cmd=['python3',R+'/tools/rdis.py',R+'/re/dumps/ram_section1.bin','17000','1a0b2','--cov',R+'/re/cov/section1.hist',
     '--labels',H+'/labels.txt','--labels',H+'/flare_entries.txt']
txt=subprocess.run(cmd,capture_output=True,text=True).stdout
cm={}
for l in open(H+'/icomments.txt'):
    if l.strip():
        a,c=l.rstrip('\n').split(' ',1); cm[a.lower()]=c
out=[]
for l in txt.split('\n'):
    k=l[:6]
    if k in cm and not l.startswith(' '):
        l=f'{l:<60} ; {cm.pop(k)}'
    out.append(l)
open(H+'/tunnels.s','w').write('\n'.join(out))
print('unplaced comments:',cm)
