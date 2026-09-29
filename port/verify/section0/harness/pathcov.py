import sys, struct, os, glob
w = lambda d, o: struct.unpack('>H', d[o:o+2])[0]
L=0xa0
tr=set()
for d in glob.glob('run/*/e_b.bin'):
    dd=open(d,'rb').read(); n=len(dd)//(4+L); prev=None
    for i in range(n):
        b=dd[i*(4+L)+4:(i+1)*(4+L)]
        lv=w(b,2); col=w(b,4)
        if prev and prev[0]!=lv: tr.add((prev[0],lv,prev[1],col))
        prev=(lv,col)
T={0:[4,17,21,31,33,37,40,84,88],1:[1,3,13,26,39,42,45,48,51,53,56,59,66,68,82],2:[4,9,16,19,23,30,33,37,40,43,52,63,73,80,86,88],3:[3,6,26,31,34,46,48,55,60,65,68,75,77,83]}
seen={}
for a,b,c1,c2 in sorted(tr):
    print(a,'->',b,'col',c1,c2)
for L_ in T:
    for c in T[L_]:
        dn=any(a==L_ and b==L_+1 and abs(c1-c)<=1 for a,b,c1,c2 in tr)
        up=any(a==L_+1 and b==L_ and abs(c1-c)<=1 for a,b,c1,c2 in tr)
        print(f'L{L_}<->L{L_+1} col {c}: down {dn} up {up}')
