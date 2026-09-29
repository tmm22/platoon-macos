import glob,collections,re
c=collections.Counter()
for f in glob.glob('sc/*.hist')+['rate/route.hist']:
    for line in open(f):
        p=line.split()
        if p: c[int(p[0],16)]+=int(p[1])
open('../cov_all.hist','w').write(''.join('%06x %d\n'%(a,n) for a,n in sorted(c.items())))
ins=[int(l[:6],16) for l in open('raw2.s') if re.match(r'^[0-9a-f]{6}  [0-9a-f]+ ',l) and 'dc.b' not in l]
unc=[a for a in ins if a not in c]
print(len(ins),len(unc))
st=None;pv=None;out=[]
for a in unc:
    if pv is None or a-pv>10:
        if st is not None: out.append((st,pv))
        st=a
    pv=a
out.append((st,pv)); print(' '.join('%x-%x'%x for x in out))
