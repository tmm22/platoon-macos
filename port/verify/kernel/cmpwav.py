#!/usr/bin/env python3
"""cmpwav.py A.wav B.wav: 50 Hz RMS envelopes, correlation at lag 0 and best lag (+-10 frames); per-second silence map."""
import sys, wave, struct, math
def env(p):
    w = wave.open(p); n = w.getnframes(); ch = w.getnchannels(); r = w.getframerate(); sw = w.getsampwidth()
    d = w.readframes(n); fmt = '<%dh' % (len(d) // 2)
    s = struct.unpack(fmt, d); step = r // 50 * ch
    return [math.sqrt(sum(x * x for x in s[i:i + step]) / step) for i in range(0, len(s) - step, step)]
a, b = env(sys.argv[1]), env(sys.argv[2])
def corr(x, y):
    n = min(len(x), len(y)); x = x[:n]; y = y[:n]
    mx = sum(x) / n; my = sum(y) / n
    num = sum((p - mx) * (q - my) for p, q in zip(x, y))
    den = math.sqrt(sum((p - mx) ** 2 for p in x) * sum((q - my) ** 2 for q in y)) or 1
    return num / den
best = max(((corr(a[max(0,l):], b[max(0,-l):]), l) for l in range(-10, 11)))
print(f'frames {len(a)}/{len(b)} corr@0 {corr(a, b):.3f} best {best[0]:.3f} at lag {best[1]}')
if '-v' in sys.argv:
    for i in range(0, min(len(a), len(b)), 50):
        print(i, int(sum(a[i:i+50])/50), int(sum(b[i:i+50])/50))
