import sys,glob
from PIL import Image, ImageDraw
# usage: sheet.py out.png cols files...
out=sys.argv[1]; cols=int(sys.argv[2]); fs=sys.argv[3:]
ims=[Image.open(f).convert('RGB') for f in fs]
w,h=ims[0].size; sc=0.5 if len(fs)>6 else 1.0
tw,th=int(w*sc),int(h*sc)
rows=(len(ims)+cols-1)//cols
S=Image.new('RGB',(cols*tw,rows*(th+10)),(40,40,40))
d=ImageDraw.Draw(S)
for i,(f,im) in enumerate(zip(fs,ims)):
    x=(i%cols)*tw; y=(i//cols)*(th+10)
    S.paste(im.resize((tw,th)),(x,y+10)); d.text((x+2,y),f.split('/')[-1],fill=(255,255,0))
S.save(out)
