import sys, struct
W = sys.argv[1]; pc = sys.argv[2]; L = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x78
def recs(p):
    d = open(p, 'rb').read(); n = len(d) // (4 + L)
    return [(struct.unpack('<I', d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]
A = recs(f'{W}/e_w{pc}.bin'); B = recs(f'{W}/p_w{pc}.bin')
if not B: print('no port records'); sys.exit()
f0 = B[0][0] + 114 - 30
A = [r for r in A if r[0] >= f0]
bad = [i for i, (a, b) in enumerate(zip(A, B)) if a[1] != b[1]]
fd = [(i, a[0], b[0] + 114) for i, (a, b) in enumerate(zip(A, B)) if a[0] != b[0] + 114]
print(f'pc {pc}: emu {len(A)} port {len(B)} records (from f{f0}); RAM differs in {len(bad)} {bad[:5]}; frame differs in {len(fd)} {fd[:5]}')
for i in bad[:2]:
    print('  ', i, [(hex(0x12dde + k), A[i][1][k], B[i][1][k]) for k in range(L) if A[i][1][k] != B[i][1][k]][:10])
