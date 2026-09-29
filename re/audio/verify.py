#!/usr/bin/env python3
"""Verify the Python replayer against the emulator (register stream + WAV).

usage: verify.py NAME FRAMES [--state STATEFILE] [--script SCRIPTFILE] [--wav]

Runs tools/amiga/emu with --reglog/--events (breakpoints on the kernel/driver entry points) and
optionally --wav, reconstructs the call sequence (music inits, stops, fades, sfx triggers) from the
breakpoint log, drives replayer.Driver with it frame by frame and compares every Paula write
(order + value) made by the driver code ($2800-$40ff).  With --wav it also mixes the Python
register stream (using the emulator's line position of each write) through replayer.Paula and
compares the result sample-by-sample with the emulator's --wav capture.
For --state runs the Python driver starts from a RAM dump taken at frame 0 of the loaded state.
"""
import sys, os, re, subprocess, argparse, struct
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
from replayer import Driver, Paula, load_ram_from_adf

ap = argparse.ArgumentParser()
ap.add_argument('name'); ap.add_argument('frames', type=int)
ap.add_argument('--state'); ap.add_argument('--script'); ap.add_argument('--wav', action='store_true')
ap.add_argument('--quiet', action='store_true')
a = ap.parse_args()

out = os.path.join(HERE, 'work', a.name)
os.makedirs(out, exist_ok=True)
script = os.path.join(out, 'script.txt')
lines = open(a.script).read().splitlines() if a.script else []
if a.state:
    lines = ['0 dump ram0.bin'] + lines
open(script, 'w').write('\n'.join(lines) + '\n')
cmd = [os.path.join(ROOT, 'tools/amiga/emu'), '--adf', os.path.join(ROOT, 're/platoon_darc.adf'),
       '--frames', str(a.frames), '--out', out, '--script', script,
       '--reglog', os.path.join(out, 'reg.log'), '--events', os.path.join(out, 'ev.log')]
for bp in ('3d6c', '3e78', '2990', '29c6', '29de', '10c00', '10c3a', 'fed6', '2854', '28e8', '3c90', '2942', '2960'):
    cmd += ['--bp', bp]
if a.state: cmd += ['--load-state', a.state]
if a.wav: cmd += ['--wav', os.path.join(out, 'emu.wav')]
subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

# ---- parse breakpoints into driver-level calls ----
bprx = re.compile(r'^\[f(\d+) v(\d+)\] BP ([0-9a-f]{6}) d0=([0-9a-f]{8}).* sp=([0-9a-f]{8})')
bps = []
base = 0
for l in open(os.path.join(out, 'ev.log')):
    mb = re.match(r'^\[f(\d+) v\d+\] chip ram dumped', l)
    if mb: base = int(mb[1])
    mm = bprx.match(l)
    if mm: bps.append((int(mm[1]) - base, int(mm[2]), int(mm[3], 16), int(mm[4], 16)))
calls = {}   # frame -> list of (kind, arg)
pwmline = {}
i = 0
while i < len(bps):
    f, v, pc, d0 = bps[i]
    nxt = bps[i + 1] if i + 1 < len(bps) else None
    if pc == 0x10c00:
        if nxt and nxt[2] == 0x2854 and nxt[0] == f:
            calls.setdefault(f, []).append(('kmusic', d0 & 0xffff, v)); i += 3 if (i + 2 < len(bps) and bps[i + 2][2] == 0x28e8) else 2
        else:
            calls.setdefault(f, []).append(('kmusicstop', 0, v)); i += 2 if (nxt and nxt[2] == 0x28e8) else 1
        continue
    if pc == 0x10c3a:
        calls.setdefault(f, []).append(('koff', 0, v)); i += 2 if (nxt and nxt[2] == 0x28e8) else 1; continue
    if pc == 0xfed6:
        calls.setdefault(f, []).append(('fade', 0, v)); i += 1; continue
    if pc == 0x2990:
        pwmline.setdefault(f, v); i += 1; continue
    if pc in (0x29c6, 0x29de):
        pwmline[f] = v; i += 1; continue
    if pc == 0x3c90:
        # a trigger interrupted by the vblank: the emulator's play of the next frame runs before the sfx becomes
        # active ($3d6c synth / $3e78 sample 'st.b $18(a1)'); model that by running the whole trigger after that play
        fa, va = f, v
        for j in range(i + 1, len(bps)):
            if bps[j][2] == 0x3c90: break
            if bps[j][2] in (0x3d6c, 0x3e78):
                if bps[j][0] != f: fa, va = bps[j][0], 312
                break
        calls.setdefault(f, []).append(('sfx', d0 & 0xffff, v))
        if fa != f:
            calls[f][-1] = ('sfxdefer', d0 & 0xffff, v)
            calls.setdefault(fa, []).insert(0, ('activate', d0 & 0xffff, 20))
        i += 1; continue
    if pc in (0x3d6c, 0x3e78):
        i += 1; continue
    if pc == 0x2854:
        calls.setdefault(f, []).append(('init', d0 & 0xffff, v)); i += 2 if (nxt and nxt[2] == 0x28e8) else 1; continue
    if pc == 0x2942:
        calls.setdefault(f, []).append(('sfxstop', 0, v)); i += 1; continue
    if pc == 0x2960:
        calls.setdefault(f, []).append(('resume', 0, v)); i += 1; continue
    # 28e8 on its own: stop from pattern command $84 inside play (handled by the replayer itself)
    i += 1

# ---- parse emulator register log ----
rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4}) pc=([0-9a-f]{6})')
emu = {}
other_dma = {}
for l in open(os.path.join(out, 'reg.log')):
    mm = rx.match(l)
    if not mm: continue
    f, v, reg, val, pc = int(mm[1]) - base, int(mm[2]), int(mm[3], 16), int(mm[4], 16), int(mm[5], 16)
    if not (reg in (0x96, 0x9e) or 0xa0 <= reg < 0xe0): continue
    if 0x2800 <= pc < 0x4100:
        emu.setdefault(f, []).append((reg, val, v, pc))
    else:
        other_dma.setdefault(f, []).append((reg, val, v))

# ---- run python ----
if a.state:
    ram = bytearray(open(os.path.join(out, 'ram0.bin'), 'rb').read())
else:
    ram = load_ram_from_adf(os.path.join(ROOT, 're/platoon_darc.adf'))
d = Driver(ram)
opts_music = 3
bad = 0; total = 0; allw = {}
d.tagged = []
for f in range(a.frames):
    d.frame = f; d.log = []
    d.play()
    d.tagged += [(f, 'play', r, v) for (_, r, v) in d.log if r >= 0]
    n0 = len(d.log)
    for kind, arg, _v in calls.get(f, []):
        if kind == 'kmusic': d.k_music(arg, 3)
        elif kind == 'kmusicstop': d.k_music(arg, 0)
        elif kind == 'koff': d.k_music_off()
        elif kind == 'fade': d.k_fade()
        elif kind == 'sfx': d.sfx(arg)
        elif kind == 'sfxdefer':
            d.sfx(arg); ch = (arg >> 8) & 3; d.pending_act = getattr(d, 'pending_act', {}); d.pending_act[ch] = d.r8(d.SFXCH + ch * 0x22 + 0x18); d.w8(d.SFXCH + ch * 0x22 + 0x18, 0)
        elif kind == 'activate':
            ch = (arg >> 8) & 3; d.w8(d.SFXCH + ch * 0x22 + 0x18, d.pending_act.pop(ch, 0))
        elif kind == 'init': d.init_song(arg)
        elif kind == 'sfxstop': d.sfx_stop_all()
        elif kind == 'resume': d.resume()
    d.tagged += [(f, 'call', r, v) for (_, r, v) in d.log[n0:] if r >= 0]
    allw[f] = [(r, v) for (_, r, v) in d.log if r >= 0]
    total += len(emu.get(f, []))
# global ordered comparison: python stream vs emulator stream
PY = [(f, r, v) for f in range(a.frames) for (r, v) in allw[f]]
EM = [(f, r, v) for f in range(a.frames) for (r, v, _, _) in emu.get(f, [])]
def emtag(f, v, pc):
    if 0x2990 <= pc < 0x2d80 or 0x3eb4 <= pc < 0x3ffa: return 'play'
    if 0x28e8 <= pc < 0x2942:
        return 'call' if any(k in ('kmusic', 'kmusicstop', 'koff', 'init') and cv <= v for (k, x, cv) in calls.get(f, [])) else 'play'
    return 'call'
EMT = {'play': [], 'call': []}
for f in range(a.frames):
    for (r, val, v, pc) in emu.get(f, []): EMT[emtag(f, v, pc)].append((f, r, val))
PYT = {'play': [], 'call': []}
for (f, tg, r, v) in d.tagged: PYT[tg].append((f, r, v))
split_equal = all([(r, v) for (_, r, v) in PYT[k]] == [(r, v) for (_, r, v) in EMT[k]] for k in ('play', 'call'))

seq_equal = [(r, v) for (_, r, v) in PY] == [(r, v) for (_, r, v) in EM]
interleave = 0
for f in range(a.frames):
    th = [(r, v) for (r, v, _, _) in emu.get(f, [])]
    if allw[f] != th:
        bad += 1
        if bad <= 3 and not a.quiet and not seq_equal:
            print('frame', f, 'MISMATCH')
            print('  py :', ' '.join('%03x=%04x' % x for x in allw[f]))
            print('  emu:', ' '.join('%03x=%04x' % x for x in th))
print('%s: global write sequence identical: %s; interrupt-side (play) and main-side (call) sub-streams identical: %s; '
      'frames with differing per-frame split: %d' % (a.name, seq_equal, split_equal, bad))
if not split_equal:
    for k in ('play', 'call'):
        A_ = PYT[k]; B_ = EMT[k]
        for j in range(min(len(A_), len(B_))):
            if A_[j][1:] != B_[j][1:]:
                print('  first %s difference at index %d: py %s emu %s' % (k, j, A_[j], B_[j])); break
        else:
            if len(A_) != len(B_): print('  %s length differs %d vs %d' % (k, len(A_), len(B_)))
print('%s: frames 0..%d, %d emulator driver writes, %d python writes, %d mismatching frames; calls: %s' % (
    a.name, a.frames - 1, total, sum(len(x) for x in allw.values()), bad,
    ', '.join('f%d:%s' % (f, ','.join('%s(%x)' % c[:2] for c in cl)) for f, cl in sorted(calls.items()))[:600]))

if a.wav and not a.state:
    # mix python writes with emulator line positions
    p = Paula(load_ram_from_adf(os.path.join(ROOT, 're/platoon_darc.adf')))
    d2 = Driver(p.m)            # replay again, this time the mixer reads the RAM the driver modifies
    dispatch = {'kmusic': lambda x: d2.k_music(x, 3), 'kmusicstop': lambda x: d2.k_music(x, 0),
             'koff': lambda x: d2.k_music_off(), 'fade': lambda x: d2.k_fade(), 'sfx': d2.sfx,
             'init': d2.init_song, 'sfxstop': lambda x: d2.sfx_stop_all(), 'resume': lambda x: d2.resume()}
    d2.pending_act = {}
    def _defer(x):
        d2.sfx(x); ch = (x >> 8) & 3; d2.pending_act[ch] = d2.r8(d2.SFXCH + ch * 0x22 + 0x18); d2.w8(d2.SFXCH + ch * 0x22 + 0x18, 0)
    def _act(x):
        ch = (x >> 8) & 3; d2.w8(d2.SFXCH + ch * 0x22 + 0x18, d2.pending_act.pop(ch, 0))
    dispatch['sfxdefer'] = _defer; dispatch['activate'] = _act
    for f in range(a.frames):
        d2.frame = f; d2.log = []
        ev = emu.get(f, [])
        playline = pwmline.get(f, ev[0][2] if ev and ev[0][2] < 40 else 3)
        pend = []   # python writes not yet applied, each with the emulator line of the matching write
        widx = 0
        cl = calls.get(f, [])
        for ln in range(313):
            todo = []
            if ln == playline: todo.append(('play', 0))
            todo += [(k, x) for (k, x, v) in cl if v == ln]
            for k, x in todo:
                d2.log = []
                if k == 'play': d2.play()
                else: dispatch[k](x)
                for (_, r, v) in d2.log:
                    if r < 0: continue
                    eln = ev[widx][2] if widx < len(ev) else ln
                    widx += 1
                    pend.append((max(eln, ln), r, v))
            for (r, v, l2) in other_dma.get(f, []):
                if l2 == ln: p.write(r, v)
            rest = []
            for (l2, r, v) in pend:
                if l2 <= ln: p.write(r, v)
                else: rest.append((l2, r, v))
            pend = rest
            p.line()
    pw = os.path.join(out, 'python.wav')
    def wavw(path, data):
        with open(path, 'wb') as fh:
            fh.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 2, 44100, 176400, 4, 16) + b'data' + struct.pack('<I', len(data)) + data)
    wavw(pw, bytes(p.out))
    e = open(os.path.join(out, 'emu.wav'), 'rb').read()[44:]
    n = min(len(e), len(p.out))
    import numpy as np
    A = np.frombuffer(e[:n], dtype='<i2').astype(np.int64); B = np.frombuffer(bytes(p.out[:n]), dtype='<i2').astype(np.int64)
    diff = np.nonzero(A != B)[0]
    print('WAV: %d samples compared, %d differ%s; emu rms %.1f' % (n // 4, len(diff), (' (first at sample %d)' % (diff[0] // 2)) if len(diff) else '', float(np.sqrt((A * A).mean()))))
