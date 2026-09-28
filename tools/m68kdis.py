import sys, capstone
def dis(data, base, n=None):
    md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_BIG_ENDIAN | capstone.CS_MODE_M68K_000)
    md.skipdata = True
    out=[]
    for i in md.disasm(data, base):
        out.append(f"{i.address:08x}: {i.bytes.hex():<20} {i.mnemonic} {i.op_str}")
        if n and len(out)>=n: break
    return out
if __name__=='__main__':
    f=sys.argv[1]; off=int(sys.argv[2],0); ln=int(sys.argv[3],0); base=int(sys.argv[4],0) if len(sys.argv)>4 else off
    d=open(f,'rb').read()[off:off+ln]
    print("\n".join(dis(d,base)))
