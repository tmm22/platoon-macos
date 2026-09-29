import struct,sys
def recs(p,L):
    d=open(p,'rb').read(); n=len(d)//(4+L)
    return [(struct.unpack('<I',d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]
d=sys.argv[1]
A=recs(d+'/e/t1.bin',0x270); G=recs(d+'/e/t2.bin',0x78); R=recs(d+'/e/t3.bin',0xfc)
prev=None
for (f,a),(_,g),(_,r) in zip(A,G,R):
    man=struct.unpack('>I',g[0x1e:0x22])[0]-0x12dde
    hits=g[man+5]; gren=g[man+1]; ammo=g[man+3]; morale=struct.unpack('>H',g[0x2e:0x30])[0]
    hs=set(); 
    for k in range(16):
        o=k*0x12
        if a[o]: hs.add(struct.unpack('>I',a[o+10:o+14])[0])
    ex=0x18706 in hs; ph=struct.unpack('>I',a[10:14])[0]
    score=g[0x4e:0x52].hex()
    st=(r[0],man,hits,ammo,ex,ph,score,struct.unpack('>H',g[0x2a:0x2c])[0])
    if st!=prev: print(f'f{f} room {r[0]} man {man//6} hits {hits} gren {gren} ammo {ammo} morale {morale:x} expl {ex} phand {ph:x} score {score} compass {st[7]}'); prev=st
