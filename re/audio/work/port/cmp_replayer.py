#!/usr/bin/env python3
"""Compare the Swift port's music-driver register stream (platoon-headless --reglog) with re/audio/replayer.py.
usage: cmp_replayer.py PORTLOG FRAMES [--song N] [--events 'F:sfx:82,F:music:3,F:musicoff,F:fade']"""
import sys, re, argparse, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..'))
from replayer import Driver, load_ram_from_adf
ap = argparse.ArgumentParser(); ap.add_argument('log'); ap.add_argument('frames', type=int)
ap.add_argument('--song', type=int); ap.add_argument('--sfx'); ap.add_argument('--events', default=''); ap.add_argument('--ram'); ap.add_argument('--ramframe', type=int)
a = ap.parse_args()
ram = load_ram_from_adf(os.path.join(HERE, '../../../platoon_port.adf'))
d = Driver(ram)
ev = {}
for e in filter(None, a.events.split(',')):
    p = e.split(':'); ev.setdefault(int(p[0]), []).append(p[1:])
if a.song is not None: ev.setdefault(0, []).insert(0, ['music', str(a.song)])
if a.sfx is not None: ev.setdefault(0, []).append(['sfx', a.sfx])
py = []
snap = None
for f in range(a.frames):
    if f == a.ramframe: snap = bytes(d.m[0x2800:0x10000])
    d.frame = f
    for e in ev.get(f, []):
        if e[0] == 'music': d.k_music(int(e[1]), 3)
        elif e[0] == 'musicoff': d.k_music_off()
        elif e[0] == 'fade': d.k_fade()
        elif e[0] == 'sfx': d.k_sfx(int(e[1], 16), 3)
    d.play()
py = [(f, r, v) for (f, r, v) in d.log if r >= 0]
rx = re.compile(r'^W f(\d+) v(\d+) CPU ([0-9a-f]{3})=([0-9a-f]{4})')
po = []
for l in open(a.log):
    m = rx.match(l)
    if m and int(m[1]) < a.frames: po.append((int(m[1]), int(m[3], 16), int(m[4], 16)))
n = min(len(py), len(po))
first = next((i for i in range(n) if py[i] != po[i]), None)
print('python writes %d, port writes %d, identical (frame,reg,value) prefix %d%s' % (len(py), len(po), first if first is not None else n,
      '' if first is None else ' FIRST DIFF py=%s port=%s' % (py[first], po[first])))
print('RESULT', 'IDENTICAL' if first is None and len(py) == len(po) else 'DIFFERENT')
if a.ram:
    b = open(a.ram, 'rb').read()
    diffs = [0x2800 + i for i in range(len(b)) if b[i] != snap[i]]
    print('driver RAM $2800-$ffff after %d frames: %d differing bytes %s' % (a.ramframe, len(diffs), ' '.join('%x' % x for x in diffs[:20])))
