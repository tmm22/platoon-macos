#!/usr/bin/env python3
"""Compare an emulator --wav capture with a port --wav capture (platoon-headless --wav-rate 44100 --no-filter) of the
same run (same frame numbering, e.g. --audio-test with a script from bp2script.py).
Scaling: emu = int16(3*sum(sample*vol)) (wrapping!), port = trunc(sum*32767/16384). The port is converted to the emulator
scale; the emulator's int16 wrap-arounds are undone using the port signal as reference (choose the 65536 multiple
closest to it), so that the correlation measures the sound and not the emulator's overflow artefact.
usage: cmp_wav.py EMUWAV PORTWAV FROMFRAME TOFRAME"""
import sys, numpy as np
ew, pw, f0, f1 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def rd(p):
    b = open(p, 'rb').read()
    return np.frombuffer(b[44:44 + (len(b) - 44) // 4 * 4], dtype='<i2').astype(np.float64).reshape(-1, 2)
e, p = rd(ew), rd(pw)
e = e[f0 * 882:f1 * 882]; p = p[f0 * 882:f1 * 882]
m = min(len(e), len(p)) // 882 * 882; e, p = e[:m], p[:m]
p3 = np.round(p / 2 * 32768 / 32767) * 3                     # port on the emulator's scale, no wrap
eu = e + 65536 * np.round((p3 - e) / 65536)                   # undo the emulator's int16 wrap
def corr(a, b): return float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-9))
best = max((corr(eu[max(0, L):m + min(0, L)], p3[max(0, -L):m - max(0, L)]), L) for L in range(-60, 61))
L = best[1]; a = eu[max(0, L):m + min(0, L)]; b = p3[max(0, -L):m - max(0, L)]
err = a - b
mono_a, mono_b = eu.mean(axis=1), p3.mean(axis=1)
nf = m // 882
ra = np.sqrt((mono_a.reshape(nf, 882) ** 2).mean(axis=1)); rb = np.sqrt((mono_b.reshape(nf, 882) ** 2).mean(axis=1))
def spec(x):
    w, h = 2048, 1024; k = (len(x) - w) // h
    return np.log1p(np.abs(np.fft.rfft(np.stack([x[i * h:i * h + w] * np.hanning(w) for i in range(k)]), axis=1)))
print('frames %d-%d (%d samples): corr lag0 %.5f | best lag %+d samples (%.2f ms) corr %.5f, rms err %.0f of emu rms %.0f (%.1f%%), '
      'max|err| %.0f | frame-RMS corr %.5f | log-spectrogram corr %.5f | samples exactly equal (lag0) %.1f%%' % (
      f0, f1, m, corr(eu, p3), L, L / 44.1, best[0], np.sqrt((err ** 2).mean()), np.sqrt((a ** 2).mean()),
      100 * np.sqrt((err ** 2).mean()) / np.sqrt((a ** 2).mean()), np.abs(err).max(), np.corrcoef(ra, rb)[0, 1],
      np.corrcoef(spec(mono_a).ravel(), spec(mono_b).ravel())[0, 1], 100 * ((e - (((p3 + 32768) % 65536) - 32768)) == 0).all(axis=1).mean()))
