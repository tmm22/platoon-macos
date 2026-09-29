import struct,subprocess,sys
base=open('/tmp/verify-section1/cheatboot.txt').read().splitlines()+['1200 key 0x5f 1','1210 key 0x5f 0','1401 poke 12e0a 0 2']
pokes=[]
def run(n):
    L=sorted(base+pokes,key=lambda l:int(l.split()[0]))
    open('/tmp/verify-section1/flq1.txt','w').write('\n'.join(L)+'\n')
    subprocess.run(['python3','/tmp/verify-section1/vr.py','flq1','/tmp/verify-section1/flq1.txt',str(n),'--pcs','171d8,18bd8','--only','emu'],capture_output=True)
    d=open('/tmp/verify-section1/flq1/emu/18bd8_12dde.td','rb').read(); L=0x78
    return [(struct.unpack('<I',d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(len(d)//(4+L))]
for it in range(12):
    G=run(4200)
    # find hit transitions (hits word changes)
    hitsf=[G[i][0] for i in range(1,len(G)) if G[i][1][4:6]!=G[i-1][1][4:6]]
    last=G[-1][0]; print(it,'hits at',hitsf,'last iter',last, flush=True)
    new=[f for f in hitsf if f'{f-12} poke 12de2 0 2' not in pokes]
    if not new: break
    pokes.append(f'{new[0]-12} poke 12de2 0 2')
