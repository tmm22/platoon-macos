import sys,struct
# print slots of tick dump t1 (57e22 len 270) for ticks given
p=sys.argv[1]; L=0x270
d=open(p,'rb').read(); n=len(d)//(4+L)
for t in map(int,sys.argv[2:]):
    fr=struct.unpack('<I',d[t*(4+L):t*(4+L)+4])[0]; b=d[t*(4+L)+4:(t+1)*(4+L)]
    s=[]
    for k in range(16):
        o=k*0x12; x=b[o:o+0x12]
        if x[0]: s.append(f"{k}:{x[0]:02x} a{x[1]} x{struct.unpack('>h',x[2:4])[0]} y{struct.unpack('>h',x[4:6])[0]} h{struct.unpack('>I',x[10:14])[0]:x} e{struct.unpack('>H',x[14:16])[0]:x} f{x[16]}")
    v=b[0x120:0x150]
    print(t,fr,' | '.join(s),' vars',v.hex())
