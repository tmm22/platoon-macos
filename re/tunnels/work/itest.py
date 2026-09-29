from run import *
import struct
l=[]
f=5
def P(a,v,s): l.append(f'{f} poke {a} {v:x} {s}')
def at(x,y,d):
    global f
    P('1a0b0',x*256+y,2); P('12e08',d,2); f+=12
    l.append(f'{f} up 1'); f+=10; l.append(f'{f} up 0'); f+=30
def click(x,y,name):
    global f
    P('19d34',x,2); P('19d36',y,2); f+=2
    l.append(f'{f} fire 1'); f+=8; l.append(f'{f} fire 0'); f+=6
    l.append(f'{f} shot {name}'); l.append(f'{f} dumpr 12dde 80 {name}.bin'); f+=100
for i in range(0,6000,300): l.append(f'{i+1} poke 3b237 ff 1')
P('12de2',1,2); P('12de0',100,2)
at(31,7,0); click(27,18,'map'); f+=100; click(16,84,'compass'); click(110,70,'medic'); click(130,123,'exit1')
at(19,7,0); click(4,88,'ammo'); click(110,10,'blocked'); click(130,123,'exit2')
at(7,11,0); click(31,73,'food'); click(31,73,'food2'); click(130,123,'exit3')
at(23,19,3); click(18,63,'roman'); click(130,123,'exit4')
P('1a0b0',21*256+3,2); P('12e08',0,2); f+=12; l.append(f'{f} up 1'); f+=20; l.append(f'{f} up 0'); f+=10; l.append(f'{f} dumpr 1a0b0 2 wall.bin'); l.append(f'{f} shot wall')
l.sort(key=lambda s:int(s.split()[0]))
print(run(l,f+10,'o17',extra=['--pchist','17000','19374','o17/h.txt'])[-200:])
for n in ['map','compass','medic','exit1','ammo','blocked','exit2','food','food2','exit3','roman','exit4']:
    a=open(f'o17/{n}.bin','rb').read()
    g=lambda o: struct.unpack('>H',a[o:o+2])[0]
    print(n,'ammo',g(2),'hits',g(4),'map',g(0x24),'compass',g(0x26),'flares',g(0x2c),'mor %04x'%g(0x2e),'score',a[0x4e:0x52].hex(),'dir',g(0x2a))
print(open('o17/wall.bin','rb').read().hex())
