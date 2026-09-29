#!/usr/bin/env python3
"""Turn an emulator --events log with breakpoints at the driver API ($2800, $281c, $2838) and kernel $10c3a into a
platoon-headless --audio-test script that replays the same calls (emulator frame F, called after F's vblank play ->
port frame F+1). usage: bp2script.py EVENTS > script.txt"""
import sys, re
rx = re.compile(r'^\[f(\d+) v(\d+)\] BP ([0-9a-f]{6}) d0=([0-9a-f]{8})')
bps = [(int(m[1]), int(m[2]), int(m[3], 16), int(m[4], 16)) for m in map(rx.match, open(sys.argv[1])) if m]
skip = 0
for i, (f, v, pc, d0) in enumerate(bps):
    if skip: skip -= 1; continue
    if pc == 0x2800:
        print('%d music %d' % (f + 1, d0 & 0xff))
        if i + 1 < len(bps) and bps[i + 1][2] == 0x281c: skip = 1          # init_song's own bsr api_stop
    elif pc == 0x10c3a:
        print('%d musicoff' % (f + 1)); skip = 1                               # its jsr $281c
    elif pc == 0x281c: print('%d stop' % (f + 1))
    elif pc == 0x2838: print('%d rawsfx %x' % (f + 1, d0 & 0xffff))
