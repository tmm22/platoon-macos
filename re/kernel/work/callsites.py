import struct,sys,capstone
md=capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_BIG_ENDIAN|capstone.CS_MODE_M68K_000)
def dis(m,a,n):
    out=[];
    for i in md.disasm(m[a:a+n],a):
        out.append((i.address,i.mnemonic+' '+i.op_str))
    return out
tgt=int(sys.argv[1],16)
for s in range(3):
    m=open('re/dumps/ram_section%d.bin'%s,'rb').read()
    for a in range(0x17000,0x70000,2):
        w=struct.unpack('>H',m[a:a+2])[0]
        if w in (0x4eb9,0x4ef9) and struct.unpack('>I',m[a+2:a+6])[0]==tgt:
            # find preceding instructions: try decoding from a-24 aligned so that it ends at a
            best=None
            for back in range(30,0,-2):
                ins=dis(m,a-back,back+6)
                addrs=[x[0] for x in ins]
                if a in addrs: best=ins; break
            print('S%d %06x:'%(s,a),' | '.join('%s'%(x[1]) for x in (best or [])[-6:]))
