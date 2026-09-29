import sys, re, subprocess, os, collections
E='/Users/deborahmangan/Projects/Platoon/tools/amiga/emu'; P='/tmp/pbuild-section0/release/platoon-headless'; ADF='/Users/deborahmangan/Projects/Platoon/re/platoon_port.adf'
W=sys.argv[1]; F=int(sys.argv[2]); lo=int(sys.argv[3]) if len(sys.argv)>3 else 0; hi=int(sys.argv[4]) if len(sys.argv)>4 else 10**9
ST=['17186','19f3a','17276','172f8','172fc','17318','1731c','17324','17328']
cmd=[E,'--adf',ADF,'--frames',str(F),'--script',f'{W}/e.txt','--out','/tmp/verify-section0/w','--deterministic','--events','/tmp/verify-section0/w/stev.txt']
for s in ST: cmd+=['--bp',s]
subprocess.run(cmd,capture_output=True)
ev=[]
for l in open('/tmp/verify-section0/w/stev.txt'):
    m=re.match(r'\[f(\d+) v(\d+)\] BP 0([0-9a-f]+)',l)
    if m: ev.append((int(m[1])*313+int(m[2]),m[3]))
env=dict(os.environ); env['S0DEBUG']='1'; env['PLATOON_ENH']='originalCredits=0'
out=subprocess.run([P,'--adf',ADF,'--start-section','0','--deterministic','--frames',str(F-114),'--script',f'{W}/p.txt','--out','/tmp/verify-section0/w'],capture_output=True,text=True,env=env).stdout
pv=[]
for m in re.finditer(r'^0(17186|19f3e|17276|172f8|172fc|17318|1731c|17324|17328) f(\d+) v(\d+)',out,re.M):
    pv.append(((int(m[2])+114)*313+int(m[3]), '19f3a' if m[1]=='19f3e' else m[1]))
def ticks(evl):
    T=[];cur=None
    for t,n in evl:
        if n=='17186':
            if cur: T.append(cur)
            cur={'17186':t}
        elif cur is not None and n not in cur: cur[n]=t
    return T
A=ticks(ev); B=ticks(pv)
n=min(len(A),len(B)); print(len(A),len(B))
acc=collections.defaultdict(list)
for i in range(n):
    a,b=A[i],B[i]
    if not (lo<=a['17186']//313<=hi): continue
    for x,y in zip(ST,ST[1:]):
        if x in a and y in a and x in b and y in b:
            acc[(x,y)].append((a[y]-a[x])-(b[y]-b[x]))
    if i+1<n and '17328' in a and '17328' in b:
        acc[('17328','next')].append((A[i+1]['17186']-a['17328'])-(B[i+1]['17186']-b['17328']))
for k,v in acc.items():
    v2=sorted(v); print(k, 'n',len(v),'mean emu-port %.2f'%(sum(v)/len(v)), 'median', v2[len(v2)//2], 'min',v2[0],'max',v2[-1])
