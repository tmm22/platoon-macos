import sys,re
# compare BP event positions (frame, line) for a given pc between emu ev.txt and port log
d=sys.argv[1]; pc=sys.argv[2] if len(sys.argv)>2 else '017118'
def load(p):
    r=[]
    for l in open(p,errors='replace'):
        m=re.match(r'\[f(\d+) v(\d+)\] BP ([0-9a-f]+)',l)
        if m and m.group(3)==pc: r.append((int(m.group(1)),int(m.group(2))))
    return r
E=load(d+'/e/ev.txt'); P=load(d+'/p/log.txt')
print(len(E),len(P))
nd=0; maxd=0
for i,(a,b) in enumerate(zip(E,P)):
    da=(b[0]*313+b[1])-(a[0]*313+a[1])
    if a[0]!=b[0]:
        nd+=1
        if nd<=int(sys.argv[3] if len(sys.argv)>3 else 10): print('tick',i,'emu',a,'port',b,'dlines',da)
print('frame mismatches',nd)
import collections
c=collections.Counter()
for i,(a,b) in enumerate(zip(E,P)):
    c[(b[0]*313+b[1])-(a[0]*313+a[1])]+=1
print(sorted(c.items()))
if len(sys.argv)>4:
    for i,(a,b) in enumerate(zip(E,P)):
        dl=(b[0]*313+b[1])-(a[0]*313+a[1])
        if abs(dl)>int(sys.argv[4]): print(i,a,b,dl)
