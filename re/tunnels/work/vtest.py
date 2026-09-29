import sys, random; sys.path.insert(0,'..')
from run import *
from tlib import *
m=Mem()
cells=[(x,y) for y in range(43) for x in range(43) if m.b(MAP+y*43+x)==2]
random.seed(1)
tests=[(random.choice(cells),random.randrange(4)) for i in range(80)]
s=S()
f=5
for i,((x,y),d) in enumerate(tests):
    s.l.append(f'{f} poke 3b237 ff 1')
    s.l.append(f'{f} poke 1a0b0 {x*256+y:x} 2')
    s.l.append(f'{f} poke 12e08 {d:x} 2')
    s.l.append(f'{f+20} shot t{i:02d}')
    f+=24
run(s.l,f+5,'o6')
bad=0
for i,((x,y),d) in enumerate(tests):
    im,(a,b)=render_view(m,x,y,d)
    sc=Image.open(f'o6/t{i:02d}.png').crop((97,36,257,180))
    n=sum(1 for yy in range(144) for xx in range(160) if im.getpixel((xx,yy))!=sc.getpixel((xx,yy)))
    if n>150: bad+=1; print(i,x,y,d,a,b,n)
print('bad',bad)
