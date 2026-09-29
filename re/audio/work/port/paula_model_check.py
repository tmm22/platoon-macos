#!/usr/bin/env python3
"""Render song N with replayer.Driver + replayer.Paula (emulator-identical mixer) with all writes at line 0
(the port's vblank timing) and compare with the port's --wav (44100, --no-filter). Isolates Paula-model differences.
usage: paula_model_check.py SONG FRAMES PORTWAV"""
import sys, os, numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '../..'))
from replayer import Driver, Paula, load_ram_from_adf
song, N, pw = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
p = Paula(load_ram_from_adf(os.path.join(HERE, '../../../platoon_port.adf'))); d = Driver(p.m)
d.k_music(song, 3)
for f in range(N):
    d.play()
    for (_, r, v) in d.log: p.write(r, v)
    d.log = []
    for ln in range(313): p.line()
a = np.frombuffer(bytes(p.out), dtype='<i2').astype(np.float64)
b = open(pw, 'rb').read(); b = np.frombuffer(b[44:44 + (len(b) - 44) // 2 * 2], dtype='<i2').astype(np.float64)
m = min(len(a), len(b)); a = a[:m]; b = b[:m]
sig = np.round(b / 2 * 32768 / 32767); b3 = ((sig * 3 + 32768) % 65536) - 32768
err = a - b3
print('song %d: %d samples, correlation %.6f, exactly equal %.3f%%, |err|<=3*64: %.3f%%, max |err| %d, rms err %.1f (signal rms %.1f)' % (
    song, m // 2, (a * b3).sum() / np.sqrt((a * a).sum() * (b3 * b3).sum()), 100 * (err == 0).mean(), 100 * (np.abs(err) <= 192).mean(),
    np.abs(err).max(), np.sqrt((err * err).mean()), np.sqrt((a * a).mean())))
