import sys,os,glob
from PIL import Image, ImageChops
d=sys.argv[1]; bad=[]; n=0
for pe in sorted(glob.glob(d+'/e/f*.png')):
    pp=d+'/p/'+os.path.basename(pe)
    if not os.path.exists(pp): continue
    a=Image.open(pe).convert('RGB'); b=Image.open(pp).convert('RGB'); n+=1
    if a.size!=b.size: bad.append((os.path.basename(pe),'size')); continue
    df=ImageChops.difference(a,b); bb=df.getbbox()
    if bb:
        cnt=sum(1 for p in df.getdata() if p!=(0,0,0)); bad.append((os.path.basename(pe),cnt,bb))
print(n,'compared,',len(bad),'differ')
for x in bad[:int(sys.argv[2]) if len(sys.argv)>2 else 30]: print(x)
