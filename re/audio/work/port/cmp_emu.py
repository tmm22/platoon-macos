#!/usr/bin/env python3
"""Compare the Swift port (platoon-headless --music-test N --reglog --wav --wav-rate 44100 --no-filter) with an
emulator run (tools/amiga/emu --reglog --wav) that starts song N at emulator frame F0 (F10 trick; init inside the
vblank of frame F0, so emulator frame F0+1+k == port frame k).
usage: cmp_emu.py EMUREG EMUWAV PORTREG PORTWAV F0 FRAMES"""
import sys, re, numpy as np
emureg, emuwav, portreg, portwav, F0, N = sys.argv[1:7]; F0 = int(F0); N = int(N)
rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
E = []
for l in open(emureg):
    m = rx.match(l)
    if not m: continue
    f, reg, val, pc = int(m[1]), int(m[3], 16), int(m[4], 16), int(m[5], 16)
    if f < F0 or f > F0 + N or not (0x2800 <= pc < 0x4100): continue
    if not (reg in (0x96, 0x9e) or 0xa0 <= reg < 0xe0): continue
    E.append((f, reg, val, pc))
# start at the stop() of the init (first write from $28e8-$2942 in frame F0)
s = next(i for i, e in enumerate(E) if e[0] == F0 and 0x28e8 <= e[3] < 0x2942)
E = [(f - F0 - 1, r, v) for (f, r, v, _) in E[s:]]
P = []
for l in open(portreg):
    m = rx.match(l)
    if m and int(m[1]) < N: P.append((int(m[1]), int(m[3], 16), int(m[4], 16)))
E = [e for e in E if e[0] < N]
n = min(len(E), len(P))
first = next((i for i in range(n) if E[i][1:] != P[i][1:]), None)
# frame alignment: init writes are in port frame 0 but emulator frame F0 (= -1 here)
fr_bad = sum(1 for i in range(n) if E[i][0] != P[i][0] and not (E[i][0] == -1 and P[i][0] == 0))
print('register stream: emu %d writes, port %d writes, first value difference: %s, writes in a different frame: %d'
      % (len(E), len(P), 'none' if first is None and len(E) == len(P) else first, fr_bad))
def rd(p):
    b = open(p, 'rb').read()
    return np.frombuffer(b[44:44 + (len(b) - 44) // 4 * 4], dtype='<i2').astype(np.float64).reshape(-1, 2)
e = rd(emuwav); pw = rd(portwav)
o = (F0 + 1) * 882
e = e[o:o + N * 882]; pw = pw[:N * 882]
m = min(len(e), len(pw)); e = e[:m]; pw = pw[:m]
best = None
for lag in range(-600, 601, 1):
    a = e[max(0, lag):m + min(0, lag)]; b = pw[max(0, -lag):m - max(0, lag)]
    a = a[:200000]; b = b[:200000]
    c = float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-9))
    if best is None or c > best[0]: best = (c, lag)
c, lag = best
a = e[max(0, lag):m + min(0, lag)]; b = pw[max(0, -lag):m - max(0, lag)]
corr = float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum()))
g = float((a * b).sum() / (b * b).sum())
sig = np.round(b / 2 * 32768 / 32767)        # port int16 = sum(sample*vol) * 2 (float mix, *32767 truncated)
b3 = ((sig * 3 + 32768) % 65536) - 32768      # emulator: int16(sum * 3), wrapping
err = a - b3
corr = float((a * b3).sum() / np.sqrt((a * a).sum() * (b3 * b3).sum()))
print('WAV: %d stereo samples, best lag %d samples (%.2f ms), correlation (vs wrapped x1.5) %.6f, fitted gain %.4f (expected 1.5), '
      'emu rms %.1f, residual rms vs port x1.5 (int16-wrapped like emu) %.2f, max |err| %.0f, samples with |err|>3: %.3f%%, exactly equal: %.2f%%'
      % (m, lag, lag / 44.1, corr, g, np.sqrt((a * a).mean()), np.sqrt((err * err).mean()), np.abs(err).max(),
         100 * (np.abs(err) > 3).mean(), 100 * (np.abs(err) == 0).mean()))
# envelope / spectral agreement (insensitive to sub-frame write timing and per-note phase)
mono_a = a.mean(axis=1); mono_b = b3.mean(axis=1)
nf = len(mono_a) // 882
ra = np.sqrt((mono_a[:nf * 882].reshape(nf, 882) ** 2).mean(axis=1)); rb = np.sqrt((mono_b[:nf * 882].reshape(nf, 882) ** 2).mean(axis=1))
def spec(x):
    w = 2048; h = 1024; k = (len(x) - w) // h
    fr = np.stack([x[i * h:i * h + w] * np.hanning(w) for i in range(k)])
    return np.log1p(np.abs(np.fft.rfft(fr, axis=1)))
sa, sb = spec(mono_a), spec(mono_b)
print('frame-RMS correlation %.5f; log-spectrogram correlation %.5f' % (np.corrcoef(ra, rb)[0, 1], np.corrcoef(sa.ravel(), sb.ravel())[0, 1]))
