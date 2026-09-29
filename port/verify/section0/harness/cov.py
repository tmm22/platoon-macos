import sys, struct, os
def recs(p, L):
    if not os.path.exists(p): return []
    d = open(p, 'rb').read(); n = len(d) // (4 + L)
    return [d[i*(4+L)+4:(i+1)*(4+L)] for i in range(n)]
w = lambda d, o: struct.unpack('>H', d[o:o+2])[0]
S = {k: set() for k in ['pstate', 'pframe', 'estate', 'eframe', 'villager', 'trap', 'bomb', 'crate', 'bridge', 'hut', 'level', 'torch',
                        'hutkilled', 'map', 'expl', 'msgq', 'grenade', 'explosion', 'invinc', 'man', 'runner', 'score']}
for d in sys.argv[1:]:
    for a, b, c in zip(recs(f'{d}/e_a.bin', 0x1c), recs(f'{d}/e_b.bin', 0xa0), recs(f'{d}/e_c.bin', 0x78)):
        S['pstate'].add(w(a, 0x1a)); S['pframe'].add(w(a, 4)); S['estate'].add(w(a, 8)); S['eframe'].add(w(a, 0xe))
        S['villager'].add(a[0x18]); S['trap'].add(w(b, 0x56)); S['bomb'].add(w(b, 0x58) != 0); S['crate'].add(w(b, 0x62) != 0)
        S['bridge'].add(w(b, 0x78)); S['hut'].add(w(b, 0x1c)); S['level'].add(w(b, 2)); S['torch'].add(b[0x99]); S['hutkilled'].add(w(b, 0x4c))
        S['map'].add(w(c, 0x24)); S['expl'].add(w(c, 0x28)); S['grenade'].add(w(b, 0x38) != 0); S['explosion'].add(w(b, 0x4a))
        S['invinc'].add(w(b, 0x7c)); S['man'].add(w(c, 0x22)); S['runner'].add(w(b, 0x80)); S['score'].add(c[0x4e:0x52].hex())
        for o in range(0x3c, 0x48, 2): S['msgq'].add(w(c, o))
for k, v in S.items():
    v = sorted(v)
    print(f'{k:10s}', ' '.join(f'{x:x}' if isinstance(x, int) else str(x) for x in v) if len(v) < 60 else f'{len(v)} values')
