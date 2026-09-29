#!/usr/bin/env python3
"""Explain port-vs-emulator WAV differences. replayer.Driver replays the port script's API calls (its register stream
is identical write-for-write to both the port's and the emulator's) and its writes are mixed by replayer.Paula (the
emulator-identical mixer, reading the RAM the driver modifies, e.g. the PWM waveform) with two timings:
  A) every write at the emulator's raster line of the matching emulator write   -> should equal the emulator --wav
  B) the port's timing: play() and its writes before line 0 (the port runs the level-3 handler at VERTB, before line 0's
     audio); script API calls before line 0
Comparisons: A vs emu (model check), B vs emu (pure sub-frame write-timing effect), B vs port (Paula-model
differences), port vs emu.
usage: paula_timing.py EMUREG EMUWAV PORTSCRIPT PORTWAV FRAMES [FROM]"""
import sys, os, re, numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '../..'))
from replayer import Paula, Driver, load_ram_from_adf
emureg, emuwav, script, portwav, N = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
F0 = int(sys.argv[6]) if len(sys.argv) > 6 else 0
rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
EL = []   # emulator line of every driver write, in order
for l in open(emureg):
    m = rx.match(l)
    if not m: continue
    f, v, reg, pc = int(m[1]), int(m[2]), int(m[3], 16), int(m[5], 16)
    if 0x2800 <= pc < 0x4100 and (reg in (0x96, 0x9e) or 0xa0 <= reg < 0xe0): EL.append((f, v, 0x2990 <= pc < 0x2d80 or 0x3eb4 <= pc < 0x4000))
ev = {}
for l in open(script):
    p = l.split()
    if len(p) >= 2: ev.setdefault(int(p[0]), []).append(p[1:])
class SwiftPaula(Paula):
    """Python model of port/Sources/PlatoonCore/Platform/Paula.swift (no filter, 44100 Hz): DMA on/off seen at the
    start of each line (settleDMA), voice start latches LC/LEN and outputs the first byte at once, byte position
    reset on start, one DMA word fetch per 2 bytes (the low byte comes from the fetched word), output int16(trunc(sum(sample*vol)/16384*32767)); *1.5 applied by the caller for comparison."""
    def settle(self):
        for c in range(4):
            a = self.ch[c]; base = 0xa0 + c * 16
            en = (self.dmacon & 0x200) and (self.dmacon & (1 << c))
            if en and not a['active']:
                a['lc'] = self.ptr(base); a['ptr'] = a['lc']; ln = self.regs[(base + 4) >> 1]
                a['cnt'] = 0x10000 if ln == 0 else ln; a['active'] = 1; a['phase'] = 0.0; self.bytepos[c] = 0
                a['word'] = bytes(self.m[a['ptr'] & 0x7fffe:(a['ptr'] & 0x7fffe) + 2]); b = a['word'][0]; a['cur'] = b - 256 if b & 0x80 else b
            if not en and a['active']: a['active'] = 0
    def line(self):
        import struct
        self.settle()
        self.acc += 44100.0 / (50.0 * self.LINES)
        while self.acc >= 1.0:
            self.acc -= 1.0
            l = r = 0
            for c in range(4):
                a = self.ch[c]; base = 0xa0 + c * 16
                if not a['active']: continue
                per = self.regs[(base + 6) >> 1]
                if per < 64: per = 64
                a['phase'] += 3546895.0 / per / 44100.0
                while a['phase'] >= 1.0:
                    a['phase'] -= 1.0
                    if self.bytepos[c] == 0: self.bytepos[c] = 1
                    else:
                        self.bytepos[c] = 0; a['cnt'] -= 1
                        if a['cnt'] <= 0:
                            a['ptr'] = self.ptr(base); ln = self.regs[(base + 4) >> 1]; a['cnt'] = 0x10000 if ln == 0 else ln
                        else: a['ptr'] += 2
                        a['word'] = bytes(self.m[a['ptr'] & 0x7fffe:(a['ptr'] & 0x7fffe) + 2])   # word DMA fetch
                    b = a['word'][self.bytepos[c]]; a['cur'] = b - 256 if b & 0x80 else b
                vol = min(64, self.regs[(base + 8) >> 1] & 0x7f)
                if c == 0 or c == 3: l += a['cur'] * vol
                else: r += a['cur'] * vol
            q = lambda x: int(x / 16384 * 32767) & 0xffff
            self.out += struct.pack('<HH', q(l), q(r))
def render(timing, cls=Paula):
    p = cls(load_ram_from_adf(os.path.join(HERE, '../../../platoon_port.adf'))); d = Driver(p.m)
    wi = 0
    def run_calls(f):
        d.log = []
        for e in ev.get(f, []):
            if e[0] == 'music': d.k_music(int(e[1]), 3)
            elif e[0] == 'musicoff': d.k_music_off()
            elif e[0] == 'stop': d.stop(); d.w16(d.MVOL, 0x40)
            elif e[0] == 'fade': d.k_fade()
            elif e[0] == 'sfx': d.k_sfx(int(e[1], 16), 3)
            elif e[0] == 'rawsfx': d.sfx(int(e[1], 16))
        w = [x for x in d.log if x[1] >= 0 or x[1] == -2]; d.log = []
        return w
    for f in range(N):
        pend = []
        if timing == 'port':
            for (_, r, v) in run_calls(f):
                if r == -2:                     # driver busy-wait: the port calls paula.settleDMA()
                    if hasattr(p, 'settle'): p.settle()
                    continue
                p.write(r, v); wi += 1
        playline = 0
        if timing == 'emu' and wi < len(EL) and EL[wi][0] == f and EL[wi][2]: playline = max(0, EL[wi][1] - 2)
        callline = None
        for ln in range(313):
            if ln == playline:
                d.log = []; d.play()
                for (_, r, v) in d.log:
                    if r < 0: continue
                    pend.append((EL[wi][1] if timing == 'emu' else 0, r, v)); wi += 1
                if timing == 'emu' and ev.get(f + 1):
                    # the emulator makes the calls of port frame f+1 in frame f after the play, at the line of
                    # their first write
                    callline = EL[wi][1] if wi < len(EL) and EL[wi][0] == f else ln
            if timing == 'emu' and callline is not None and ln == max(callline, playline):
                for (_, r, v) in run_calls(f + 1):
                    if r == -2: continue
                    pend.append((EL[wi][1] if wi < len(EL) and EL[wi][0] == f else ln, r, v)); wi += 1
                callline = None
            rest = []
            for (l2, r, v) in pend:
                if l2 <= ln: p.write(r, v)
                else: rest.append((l2, r, v))
            pend = rest
            p.line()
    return np.frombuffer(bytes(p.out), dtype='<i2').astype(np.float64).reshape(-1, 2)
def rd(pth):
    b = open(pth, 'rb').read()
    return np.frombuffer(b[44:44 + (len(b) - 44) // 4 * 4], dtype='<i2').astype(np.float64).reshape(-1, 2)
def cmp(name, x, y):
    x = x[F0 * 882:N * 882]; y = y[F0 * 882:N * 882]; m = min(len(x), len(y)); x, y = x[:m], y[:m]
    e = x - y
    c = (x * y).sum() / (np.sqrt((x * x).sum() * (y * y).sum()) + 1e-9)
    print('%-34s corr %.6f  equal %6.2f%%  max|err| %6d  rms err %8.1f' % (name, c, 100 * (e == 0).all(axis=1).mean(), np.abs(e).max(), np.sqrt((e * e).mean())))
E = rd(emuwav); P = rd(portwav)
s = np.round(P / 2 * 32768 / 32767); P3 = ((s * 3 + 32768) % 65536) - 32768
A = render('emu'); B = render('port'); S = render('port', SwiftPaula)
cmp('Swift-Paula model vs port wav', S, P)
cmp('A (emu timing) vs emu wav', A, E)
AS = render('emu', SwiftPaula); s2 = np.round(AS / 2 * 32768 / 32767); AS3 = ((s2 * 3 + 32768) % 65536) - 32768
cmp('Swift-Paula model, emu timing vs emu', AS3, E)
cmp('B (port timing) vs emu wav', B, E)
cmp('B (port timing) vs port wav x1.5', B, P3)
cmp('port wav x1.5 vs emu wav', P3, E)
if os.environ.get('DBG'):
    d = np.nonzero((A[:len(E)] != E[:len(A)]).any(axis=1))[0]
    d = d[d >= F0 * 882]
    fr = d // 882
    import collections
    print('A!=E first samples', d[:10], 'frames', sorted(collections.Counter(fr).items())[:20])
    i = d[0]; print(A[i-3:i+8].T, E[i-3:i+8].T)
if os.environ.get('DBG2'):
    m = min(len(S), len(P)); d = np.nonzero((S[:m] != P[:m]).any(axis=1))[0]
    print('S!=P first', d[:12]);
    i = d[0]; print(S[i-3:i+10].T); print(P[i-3:i+10].T)
