#!/usr/bin/env python3
"""wavstat.py A.wav [B.wav] [--from S --to S] [--runs]: RMS/peak per channel, high-band energy; with B: diff and correlation."""
import sys, struct, numpy as np
def load(p):
    d = open(p, 'rb').read()
    # find fmt and data
    i = 12; fmt = None; data = None
    while i < len(d):
        cid = d[i:i+4]; n = struct.unpack('<I', d[i+4:i+8])[0]
        if cid == b'fmt ': fmt = struct.unpack('<HHIIHH', d[i+8:i+24])
        if cid == b'data': data = d[i+8:i+8+n]
        i += 8 + n + (n & 1)
    tag, ch, rate, _, _, bits = fmt
    if tag == 3 or (tag == 0xfffe and bits == 32): a = np.frombuffer(data, dtype='<f4')   # float (plain or extensible)
    elif bits == 16: a = np.frombuffer(data, dtype='<i2').astype(np.float32) / 32768
    else: raise SystemExit(f'fmt {fmt}')
    return a.reshape(-1, ch), rate
args = [a for a in sys.argv[1:] if not a.startswith('--') and not a.replace('.','',1).isdigit()]
opt = {sys.argv[i][2:]: float(sys.argv[i+1]) for i in range(1, len(sys.argv)-1) if sys.argv[i].startswith('--') and sys.argv[i+1].replace('.','',1).isdigit()}
A, rate = load(args[0])
s0 = int(opt.get('from', 0) * rate); s1 = int(opt.get('to', 1e9) * rate)
A = A[s0:s1]
def stats(X, name):
    rms = np.sqrt((X.astype(np.float64)**2).mean(axis=0)); pk = np.abs(X).max(axis=0)
    sp = np.abs(np.fft.rfft(X[:, 0].astype(np.float64) * np.hanning(len(X)))) ** 2
    f = np.fft.rfftfreq(len(X), 1 / rate)
    hb = sp[f > 16000].sum() / max(1e-30, sp.sum())
    print(f'{name}: {len(X)/rate:.2f}s rms L={rms[0]:.5f} R={rms[1]:.5f} peak={pk.max():.4f} hf(>16k) share={hb:.2e}')
stats(A, args[0])
if len(args) > 1:
    B, _ = load(args[1]); B = B[s0:s1]
    n = min(len(A), len(B)); A2, B2 = A[:n], B[:n]
    stats(B2, args[1])
    d = A2 - B2
    print(f'diff rms={np.sqrt((d.astype(np.float64)**2).mean()):.6f} max={np.abs(d).max():.6f} identical_samples={(d == 0).all(axis=1).mean()*100:.2f}%')
    for c in range(2):
        a, b = A2[:, c].astype(np.float64), B2[:, c].astype(np.float64)
        if a.std() > 0 and b.std() > 0: print(f'corr ch{c}: {np.corrcoef(a, b)[0,1]:.4f}')
    if 'runs' in opt or '--runs' in sys.argv:
        # 50 Hz frames in which A and B differ, as runs (first, last)
        fr = rate // 50
        dd = np.abs(A2 - B2).max(axis=1)
        bad = [i for i in range(n // fr) if dd[i * fr:(i + 1) * fr].max() > 1e-6]
        runs = []
        for i in bad:
            if runs and runs[-1][1] == i - 1: runs[-1][1] = i
            else: runs.append([i, i])
        print('differing frames: %d, runs: %s' % (len(bad), ' '.join('%d-%d' % tuple(r) for r in runs[:60])))
