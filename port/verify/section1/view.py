import json
M=json.load(open('/Users/deborahmangan/Projects/Platoon/re/tunnels/assets/maze.json'))['cells']
OFF={0:(-1,1,-43),1:(-43,43,1),2:(1,-1,43),3:(43,-43,-1)}
flat=[v for row in M for v in row]
def codes(x,y,d):
    lo,ro,fo=OFF[d]; b=y*43+x
    c=lambda o: flat[b+o]
    F=0;o=fo
    for d4 in (3,2,1,0):
        if c(o)==3: F=0x10|d4;break
        if c(o)!=2: F=0x08|d4;break
        o+=fo
    d6=F;o=lo
    for d4 in (3,2,1,0):
        if c(o)==2: d6|=4|d4;break
        o+=fo
    d7=F;o=ro
    for d4 in (3,2,1,0):
        if c(o)==2: d7=((d7|4)&0xfc)|d4;break
        o+=fo
    if d6==0 and d7==0: d6=d7=(x if d&1 else y)&3
    elif d6==0: d6=d7&3
    elif d7==0: d7=d6&3
    return d6,d7
