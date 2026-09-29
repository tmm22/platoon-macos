import sys; sys.path.insert(0,'/tmp/verify-section1')
L=open('/tmp/verify-section1/cheatboot.txt').read().splitlines()+['1200 key 0x5f 1','1210 key 0x5f 0']
f=1770
def hold(dirs,n,idle=10):
    global f
    for d in dirs: L.append(f'{f} {d} 1')
    L.append(f'{f} shot m{f}')
    f+=n
    for d in dirs: L.append(f'{f} {d} 0')
    f+=idle
hold(['up','left'],20); hold(['up','right'],20); hold(['down','left'],20); hold(['down','right'],20)
hold(['left'],30); hold(['up'],30); hold(['right'],60); hold(['down'],60)
hold(['fire'],12)                        # shots into the dark (jitter, spawn base -2 per shot)
hold(['up','fire'],16)
L.append(f'{f} key 0x40 1'); L.append(f'{f+6} key 0x40 0'); f+=20   # SPACE: flare
L.append(f'{f} key 0x40 1'); L.append(f'{f+6} key 0x40 0'); f+=20   # SPACE again during the cycle: ignored
for k in range(0,400,20): L.append(f'{f+k} shot c{f+k}')
f+=400
open('/tmp/verify-section1/flmove.txt','w').write('\n'.join(sorted(L,key=lambda l:int(l.split()[0])))+'\n'); print(f)
