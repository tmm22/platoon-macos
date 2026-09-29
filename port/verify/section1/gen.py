"""script generator for section-1 routes (same script for emu and port)."""
import json, collections
M=json.load(open('/Users/deborahmangan/Projects/Platoon/re/tunnels/assets/maze.json'))['cells']
DX=[(0,-1),(1,0),(0,1),(-1,0)]
ROOMS={0:((8,3),1),1:((36,3),1),2:((7,10),0),3:((19,6),0),4:((31,6),0),5:((39,10),0),6:((22,19),3),7:((31,26),0),8:((14,35),3),9:((39,30),0)}
BOOT=['300 fire 1','305 fire 0','350 poke 12e4c 1 2','600 fire 1','605 fire 0','900 fire 1','905 fire 0']
class S:
    def __init__(s,f=906,lines=None,suppress=True):
        s.f=f; s.l=list(BOOT if lines is None else lines); s.x,s.y,s.d=21,3,3; s.sup=suppress; s.lastpoke=-10000
        if suppress: s.poke('3b237','ff',1)
    def add(s,c,f=None): s.l.append(f'{s.f if f is None else f} {c}')
    def keep(s):
        if s.sup and s.f-s.lastpoke>600: s.poke('3b237','ff',1)
    def poke(s,a,v,n):
        if a=='3b237':
            f=s.f
            while f%4!=2: f+=1
            s.add(f'poke {a} {v} {n}',f); s.lastpoke=s.f
        else: s.add(f'poke {a} {v} {n}')
    def hold(s,d,n,idle=6):
        s.keep(); s.add(f'{d} 1'); s.f+=n; s.add(f'{d} 0'); s.f+=idle
    def wait(s,n):
        while n>0:
            k=min(n,300); s.f+=k; n-=k; s.keep()
    def shot(s,name): s.add(f'shot {name}')
    def key(s,code,n=6,idle=6): s.add(f'key {code} 1'); s.f+=n; s.add(f'key {code} 0'); s.f+=idle
    def F(s): s.hold('up',8); s.x+=DX[s.d][0]; s.y+=DX[s.d][1]
    def L(s): s.hold('left',6); s.d=(s.d-1)%4
    def R(s): s.hold('right',6); s.d=(s.d+1)%4
    def face(s,d):
        diff=(d-s.d)%4
        if diff==1: s.R()
        elif diff==3: s.L()
        elif diff==2: s.R(); s.R()
    def path(s,tx,ty):
        start=(s.x,s.y); prev={start:None}; q=collections.deque([start])
        while q:
            c=q.popleft()
            if c==(tx,ty): break
            for d,(dx,dy) in enumerate(DX):
                n=(c[0]+dx,c[1]+dy)
                if n not in prev and (M[n[1]][n[0]]==2 or n==(tx,ty)): prev[n]=c; q.append(n)
        p=[]; c=(tx,ty)
        while c!=start: p.append(c); c=prev[c]
        return p[::-1]
    def go(s,tx,ty,shots=None):
        for (nx,ny) in s.path(tx,ty):
            d=DX.index((nx-s.x,ny-s.y)); s.face(d); s.F()
            if shots: s.shot(f'{shots}_{s.x}_{s.y}_{s.d}')
    def enter(s,k):
        (rx,ry),d=ROOMS[k]; bx,by=rx-DX[d][0],ry-DX[d][1]
        s.go(bx,by); s.face(d); s.F(); s.bx,s.by=bx,by; s.wait(12)
    def cross(s,x,y): s.poke('19d34','%x'%x,2); s.poke('19d36','%x'%y,2); s.f+=5
    def click(s,x,y,after=40):
        s.cross(x,y); s.hold('fire',6,after)
    def leave(s):
        s.click(126,123,20); s.x,s.y=s.bx,s.by; s.d=(s.d+2)%4
    def text(s):
        return '\n'.join(sorted(s.l,key=lambda l:int(l.split()[0])))+'\n'
    def save(s,p): open(p,'w').write(s.text())
