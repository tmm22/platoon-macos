import sys,os
from PIL import Image, ImageChops
o='/tmp/verify-section1/'+sys.argv[1]; mn=int(sys.argv[2]) if len(sys.argv)>2 else 600
bad=[]
for x in sorted(os.listdir(o+'/emu')):
    if not x.endswith('.png') or not os.path.exists(o+'/port/'+x): continue
    if x.startswith('f') and x[1:7].isdigit() and int(x[1:7])<mn: continue
    a=Image.open(o+'/emu/'+x).convert('RGB'); b=Image.open(o+'/port/'+x).convert('RGB')
    bb=ImageChops.difference(a,b).getbbox()
    if bb: bad.append((x,bb))
print(len(bad),'differ (>= frame %d):'%mn, bad[:30])
