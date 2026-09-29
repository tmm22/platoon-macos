import re,sys,difflib,collections
def load(p):
    out=[]
    for l in open(p):
        m=re.match(r'W f(\d+) v(\d+) (\w+) ([0-9a-f]{3})=([0-9a-f]{4})',l)
        if not m: continue
        f,v,src,reg,val=int(m[1]),int(m[2]),m[3],int(m[4],16),m[5]
        if (0xa0<=reg<=0xdf or reg==0x96) and src=='CPU': out.append((f,reg,val,v))
    return out
lo=int(sys.argv[3]) if len(sys.argv)>3 else 900
E=[x for x in load(sys.argv[1]) if x[0]>=lo]; P=[x for x in load(sys.argv[2]) if x[0]>=lo]
sm=difflib.SequenceMatcher(None,[x[1:3] for x in E],[x[1:3] for x in P],autojunk=False)
m=sum(b.size for b in sm.get_matching_blocks())
fr=collections.Counter()
for b in sm.get_matching_blocks():
    for k in range(b.size): fr[P[b.b+k][0]-E[b.a+k][0]]+=1
print(f'emu {len(E)} port {len(P)} writes; {m} matched in order; frame offset of matched writes: {sorted(fr.items())}')
bad=[op for op in sm.get_opcodes() if op[0]!='equal']
for op in bad[:8]: print(op, E[op[1]:op[2]][:3], P[op[3]:op[4]][:3])
