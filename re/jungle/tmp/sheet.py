import sys,glob
from PIL import Image
d=sys.argv[1]; out=sys.argv[2]; y0=int(sys.argv[3]) if len(sys.argv)>3 else 20; y1=int(sys.argv[4]) if len(sys.argv)>4 else 240
fs=sorted(glob.glob(d+'/f*.png'))[:24]
W=384;H=y1-y0;cols=4
rows=(len(fs)+cols-1)//cols
im=Image.new('RGB',(W*cols,H*rows))
for i,f in enumerate(fs):
  im.paste(Image.open(f).crop((0,y0,384,y1)),((i%cols)*W,(i//cols)*H))
im.save(out)
