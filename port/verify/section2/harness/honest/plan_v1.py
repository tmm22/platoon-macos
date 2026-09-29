# Movement planner for section 2 rooms (exact pl_move rules + static-object boxes, inflated by a margin).
import collections
ADF='/Users/deborahmangan/Projects/Platoon/re/platoon_port.adf'
adf=open(ADF,'rb').read()
def r8(a): return adf[a+0x81a00]
def r16(a): return r8(a)<<8|r8(a+1)
def r32(a): return r16(a)<<16|r16(a+2)
MAP=[r8(0x18ea4+i) for i in range(120)]
EXITS=[r8(0x18f2e+t) for t in range(17)]
DIMS={0:(0x14,7,4),1:(0x10,5,4),2:(0xa,5,4),3:(0xa,4,4),4:(6,4,3),5:(6,4,3),6:(0x32,6,3),7:(0x28,4,3),8:(0x28,4,3),9:(0x46,0xa,4),10:(0x32,8,4),11:(0x28,6,4)}
def objects(t):
    p=r32(0x18866+4*t); l=[]
    while True:
        ty=r16(p)
        if ty>=0x8000: break
        l.append((ty,r16(p+2),r16(p+4))); p+=6
    return l
U,D,L,R=4,1,8,2
ACTS=[0,U,D,L,R,U|L,U|R,D|L,D|R]
def step(x,y,w,j,exits):
    if j&1:
        w+=1; y-=2
        if y<0: w-=1; y=0
    if j&4:
        y+=2; w-=1
        if y>=0x60: w+=1; y=0x5f
    d6=exits if y>=0x5a else 0
    if j&8: x-=4
    if j&2: x+=4
    lo=0x64-w; hi=0xbe+w
    ex=None
    if lo>x:
        if d6&1: ex='L'
        x=lo
    if hi<x:
        if d6&2: ex='R'
        x=hi
    return x,y,w,ex
def overlap(t,x,y,mx=6,my=3):
    for ty,ox,oy in objects(t):
        W,Dd,pdy=DIMS[ty]
        if ox+W+mx>=x and ox-mx<=x+0xe and oy-my<=y+pdy and oy+Dd+my>=y: return True
    return False
def plan(t,x,y,w,want,mx=6,my=3):
    """BFS: list of joystick values (one per tick) from (x,y,w) to leaving by exit `want` ('L'/'R');
    for the bunker room (want='B', x,y target) plans to the target state."""
    exits=EXITS[t]
    start=(x,y,w); prev={start:None}; q=collections.deque([start])
    while q:
        s=q.popleft()
        for j in ACTS:
            nx,ny,nw,ex=step(*s,j,exits)
            if ex==want:
                path=[j]; c=s
                while prev[c] is not None: c,jj=prev[c]; path.append(jj)
                return path[::-1]
            if ex: continue
            n=(nx,ny,nw)
            if n in prev or overlap(t,nx,ny,mx,my): continue
            prev[n]=(s,j); q.append(n)
    return None
ROUTE='LRLRLRLRRLRLRL'
def walk_route():
    room=0x69; dirs=[1,10,-1,-10]
    out=[room]
    for c in ROUTE:
        if c=='R': room+=dirs[0]; dirs=dirs[1:]+dirs[:1]
        else: room+=dirs[2]; dirs=dirs[-1:]+dirs[:-1]
        out.append(room)
    return out
if __name__=='__main__':
    rooms=walk_route(); print(rooms,[MAP[r] for r in rooms])
    for r,c in zip(rooms,ROUTE):
        p=plan(MAP[r],0xa0,0,0x32,c); print(r,MAP[r],c,len(p) if p else None)
