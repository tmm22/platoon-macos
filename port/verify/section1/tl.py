import struct,sys
n=sys.argv[1]; t=sys.argv[2] if len(sys.argv)>2 else 'emu'
d=open(f'{n}/{t}/171d8_19a60.td','rb').read();L=0x652
g=open(f'{n}/{t}/171d8_12dde.td','rb').read();LG=0x78
v=open(f'{n}/{t}/171d8_3b220.td','rb').read();LV=0x1dc
prev=None
for i in range(0,len(d)//(4+L)):
  r=d[i*(4+L):(i+1)*(4+L)]; f=struct.unpack('<I',r[:4])[0]; b=r[4:]
  o=lambda a: b[a-0x19a60:a-0x19a60+18].hex()
  gg=g[i*(4+LG)+4:(i+1)*(4+LG)]; vv=v[i*(4+LV)+4:(i+1)*(4+LV)]
  k=('o1',o(0x19d44)[:4],'o2',o(0x19d56)[:4],o(0x19d56)[-16:-8],'o3',o(0x19d68)[:4],'o4',o(0x19d7a)[:4],'room',vv[0x10:0x11].hex(),'pos',b[0x1a0b0-0x19a60:0x1a0b2-0x19a60].hex(),'sc',gg[0x4e:0x52].hex(),'man',gg[0x22:0x24].hex(),'hits',gg[4:6].hex(),gg[10:12].hex(),'mor',gg[0x2e:0x30].hex())
  if k!=prev: print(f,*k); prev=k
