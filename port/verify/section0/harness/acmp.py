import re, sys
rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
OFF=114
def load(p, emu):
    out = []
    for l in open(p):
        m = rx.match(l)
        if not m: continue
        f, reg, val, pc = int(m[1]), int(m[3], 16), int(m[4], 16), int(m[5], 16)
        if emu:
            if not (0x2800 <= pc < 0x4100): continue
            f -= OFF
        if not (reg in (0x96, 0x9e) or 0xa0 <= reg < 0xe0): continue
        if f >= 705: out.append((f, int(m[2]), reg, val, pc))
    return out
W=sys.argv[1]; k=int(sys.argv[2]) if len(sys.argv)>2 else 0
E=load(W+'/erl.txt',1); P=load(W+'/prl.txt',0)
n=min(len(E),len(P))
bad=[i for i in range(n) if E[i][2:4]!=P[i][2:4] or E[i][0]!=P[i][0]]
print(len(E),len(P),'mismatching entries',len(bad))
if bad:
    i=bad[k] if k < len(bad) else bad[-1]
    f0=E[i][0]
    for x in E:
        if f0-1<=x[0]<=f0+1: print('E f%d v%d %03x=%04x pc=%x'%x)
    for x in P:
        if f0-1<=x[0]<=f0+1: print('P f%d v%d %03x=%04x pc=%x'%x)
