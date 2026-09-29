import sys,struct; sys.path.insert(0,'..')
from run import *
def go(name, extra_lines, frames=300, state=ROOT+'/re/states/tunnels_start.state'):
    l=['5 poke 3b237 1 1']+extra_lines
    for f in range(8,frames,4):
        l.append(f'{f} dumpr 19d32 5a d{f:04d}.bin')
        l.append(f'{f} dumpr 12dde 80 a{f:04d}.bin')
    l.sort(key=lambda s:int(s.split()[0]))
    run(l,frames,name,state)
    rows=[]
    for f in range(8,frames,4):
        o=open(f'{name}/d{f:04d}.bin','rb').read(); a=open(f'{name}/a{f:04d}.bin','rb').read()
        objs=[]
        for i in range(5):
            b=o[i*18:i*18+18]
            if b[0]: objs.append(f'{i}:f{b[1]} ({struct.unpack(">h",b[2:4])[0]},{struct.unpack(">h",b[4:6])[0]}) h{struct.unpack(">I",b[10:14])[0]:x} e{struct.unpack(">h",b[14:16])[0]} c{struct.unpack(">h",b[16:18])[0]}')
        ammo=struct.unpack('>H',a[2:4])[0]; hits=struct.unpack('>H',a[4:6])[0]; mor=struct.unpack('>H',a[0x2e:0x30])[0]
        score=a[0x4e:0x52].hex()
        rows.append(f'{f:4d} ammo{ammo} hits{hits} mor{mor:04x} sc{score} '+' | '.join(objs))
    return rows
if __name__=='__main__':
    for r in go('o8',[]): print(r)
