#!/usr/bin/env python3
"""Reference re-implementation of the section-0 playfield renderer, blit by blit.

  draw_tiles()  == $18cf4   (clear back buffer, blit 3 rows of 64x48 tiles with coarse scroll)
  draw_bob()    == $1920a   (bob with 5-plane data, foreground-priority mask below line $60cba)

A tiny Amiga blitter model (ascending mode, A/B/C/D, shifts, modulos, minterms, FWM=LWM=$ffff)
executes exactly the register values the 68000 code writes, so this doubles as a spec for the
Swift port.  Validation:  render_sim.py PRE.bin POST.bin EVENTS.txt
  PRE.bin   = chip RAM at pc=$172f8 (just before 'bsr draw_tiles' in the main loop)
  POST.bin  = chip RAM at pc=$17328 (just before 'jsr $f84c' buffer swap)
  EVENTS    = emu --bp 1920a event log for that frame (d0/d1 of every draw_bob call)
The simulated back buffer is compared byte-for-byte with POST.
"""
import sys, struct, re


def L(m, a):
    return struct.unpack('>I', bytes(m[a:a + 4]))[0]


def W(m, a):
    return struct.unpack('>H', bytes(m[a:a + 2]))[0]


class Blitter:
    def __init__(self, mem):
        self.m = mem
        self.con0 = 0
        self.con1 = 0
        self.mod = {'a': 0, 'b': 0, 'c': 0, 'd': 0}
        self.pt = {'a': 0, 'b': 0, 'c': 0, 'd': 0}
        self.fwm = 0xffff
        self.lwm = 0xffff

    def rw(self, a):
        return (self.m[a] << 8) | self.m[a + 1]

    def ww(self, a, v):
        self.m[a] = (v >> 8) & 0xff
        self.m[a + 1] = v & 0xff

    def start(self, size):
        """BLTSIZE write: size = (rows << 6) | words (0 = 1024 rows / 64 words)."""
        rows = size >> 6 or 1024
        words = size & 0x3f or 64
        c0 = self.con0
        usea, useb, usec, used = c0 & 0x800, c0 & 0x400, c0 & 0x200, c0 & 0x100
        ash = c0 >> 12
        bsh = self.con1 >> 12
        mint = c0 & 0xff
        olda = 0
        oldb = 0
        adat = bdat = cdat = 0
        for r in range(rows):
            for wd in range(words):
                if usea:
                    adat = self.rw(self.pt['a']); self.pt['a'] += 2
                if useb:
                    bdat = self.rw(self.pt['b']); self.pt['b'] += 2
                if usec:
                    cdat = self.rw(self.pt['c']); self.pt['c'] += 2
                am = adat
                if wd == 0:
                    am &= self.fwm
                if wd == words - 1:
                    am &= self.lwm
                a_s = (((olda << 16) | am) >> ash) & 0xffff
                olda = am
                b_s = (((oldb << 16) | bdat) >> bsh) & 0xffff
                oldb = bdat
                d = 0
                for i in range(8):
                    if mint & (1 << i):
                        t = 0xffff
                        t &= a_s if i & 4 else (~a_s & 0xffff)
                        t &= b_s if i & 2 else (~b_s & 0xffff)
                        t &= cdat if i & 1 else (~cdat & 0xffff)
                        d |= t
                if used:
                    self.ww(self.pt['d'], d); self.pt['d'] += 2
            if usea: self.pt['a'] += self.mod['a']
            if useb: self.pt['b'] += self.mod['b']
            if usec: self.pt['c'] += self.mod['c']
            if used: self.pt['d'] += self.mod['d']


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


A6 = 0x12dde


def draw_tiles(m, bl):
    """$18cf4"""
    back = L(m, A6 + 0x62)
    for i in range(0x5a0):                      # clear 4 planes x $1680 bytes
        for p in range(4):
            for k in range(4):
                m[back + p * 0x2000 + i * 4 + k] = 0
    c34_saved = W(m, 0x60c34)
    c34 = s16(c34_saved & 0xfffe)
    d5 = c34 >> 1                               # asr.w #1 (signed)
    level = W(m, 0x60c26)
    a0 = L(m, 0x5f89c + level * 4) + W(m, 0x60c24)
    if d5 >= 0:
        a0 += 1
    a1 = back
    bl.mod['a'] = 0; bl.mod['d'] = 0x20; bl.con0 = 0x9f0; bl.con1 = 0
    for row in range(3):
        row_a1 = a1
        n = 4
        if d5 != 0:
            n = 3                                # 4 full tiles (dbra from 3)
            t = m[a0]; a0 += 1
            a2 = L(m, 0x5f8b4 + t * 4)
            if d5 > 0:
                nxt = a1 + 8 - c34
                a2 += c34
                d3 = 0xc04 - d5
                d6 = 0x20 + c34
                d7 = c34
            else:
                nxt = a1 - c34
                d7 = 8 + c34
                a2 += d7
                d3 = 0xc00 - d5
                d6 = 0x28 + c34
            bl.mod['a'] = d7; bl.mod['d'] = d6
            bl.pt['a'] = a2
            for p in range(4):
                bl.pt['d'] = a1 + p * 0x2000
                bl.start(d3)
            a1 = nxt
        for k in range(n + 1):                  # full 64x48 tiles
            t = m[a0]; a0 += 1
            a2 = L(m, 0x5f8b4 + t * 4)
            bl.mod['a'] = 0; bl.mod['d'] = 0x20
            bl.pt['a'] = a2                      # A continues plane to plane
            for p in range(4):
                bl.pt['d'] = a1 + p * 0x2000
                bl.start(0xc04)
            a1 += 8                              # lea -$5ff8(a1) after 3x lea $2000
        if d5 != 0:
            t = m[a0]
            a2 = L(m, 0x5f8b4 + t * 4)
            skip = False
            if d5 > 0:
                d7 = 8 - c34
                d3 = d5 + 0xc00
                d6 = 0x28 - c34
            else:
                d7 = -c34
                d3 = 4 + d5 + 0xc00
                d6 = 8 + c34
                if d6 == 0:
                    skip = True
                d6 = 0x28 - d6
            if not skip:
                bl.mod['a'] = d7; bl.mod['d'] = d6
                bl.pt['a'] = a2
                for p in range(4):
                    bl.pt['d'] = a1 + p * 0x2000
                    bl.start(d3)
        a1 = row_a1 + 0x780
        a0 += 0x55
    # restore
    struct.pack_into('>H', m, 0x60c34, c34_saved)


def draw_bob(m, bl, d0, idx):
    """$1920a  d0 = (x<<16)|y (screen x incl. +16 offset, before fine-scroll), idx = bob number"""
    idx &= 0xffff
    d0 = (d0 + L(m, 0x1a536 + idx * 4)) & 0xffffffff
    d6 = d0 & 0xffff
    x = ((d0 >> 16) - W(m, 0x60cb2)) & 0xffff
    d0 = (x << 16) | (d0 & 0xffff)
    if d0 >= 0x1400000:
        return
    y = d0 & 0xffff
    # clear the 160x6-word bob buffer at $604a4
    bl.con0 = 0x100; bl.con1 = 0
    bl.mod = {'a': 0, 'b': 0, 'c': 0, 'd': 0}
    bl.pt = {'a': 0, 'b': 0, 'c': 0, 'd': 0x604a4}
    bl.start(0x2806)
    a1 = 0x55400 + L(m, 0x55000 + idx * 8)
    hdr = L(m, a1); a1 += 4
    d1 = (hdr + 0x10001) & 0xffffffff
    H = d1 & 0xffff
    Wd = d1 >> 16
    d5 = H
    size5 = ((5 * H) << 6) | (Wd & 0x3f)
    bl.mod['d'] = 2; bl.con0 = 0x9f0
    bl.pt['a'] = a1; bl.pt['d'] = 0x604a4
    bl.start(size5 & 0xffff)
    back = L(m, A6 + 0x62)
    ys = s16(y)
    a0 = L(m, 0x60cc2 + ((ys * 4) & 0xffff if ys >= 0 else ys * 4)) + back  # movea.l (a0,d0.w)
    d7 = (x & 15) << 12
    a0 += (x >> 3) & 0xfe
    d1 = (hdr + 0x20001) & 0xffffffff
    W1 = (d1 >> 16) & 0xffff
    H1 = d1 & 0xffff
    d2 = (H1 * W1 * 2) & 0xffff
    size = ((H1 << 6) | (W1 & 0x3f)) & 0xffffffff
    d3 = (0x28 - 2 * (W1 & 0x3f)) & 0xffff
    d3s = s16(d3)
    scr = a0
    # background mask: OR of screen planes 1..3 into $60864
    bl.mod = {'a': d3s, 'b': bl.mod['b'], 'c': 0, 'd': 0}
    bl.con0 = 0x9f0
    bl.pt['a'] = scr + 0x2000; bl.pt['d'] = 0x60864
    bl.start(size)
    bl.con0 = 0xbfa
    bl.pt['a'] = scr + 0x4000; bl.pt['c'] = 0x60864; bl.pt['d'] = 0x60864
    bl.start(size)
    bl.pt['a'] = scr + 0x6000; bl.pt['c'] = 0x60864; bl.pt['d'] = 0x60864
    bl.start(size)
    cba = W(m, 0x60cba)
    a0b = 0x60864
    a1b = 0x604a4
    con_cookie = None
    lower_size = size
    if d6 >= cba:
        pass                                   # entirely below the line -> lower
    else:
        bottom = (d6 + d5) & 0xffff
        if bottom <= cba:
            con_cookie = d7 | 0xfca            # entirely above: plain cookie-cut, A shifted
        else:
            rows_above = cba - d6
            s_above = (rows_above << 6) | (W1 & 0x3f)
            bl.mod['a'] = 0; bl.mod['d'] = 0
            bl.pt['a'] = a1b; bl.pt['d'] = a0b; bl.con0 = d7 | 0x9f0
            bl.start(s_above)
            bl.con0 = 0x9f0
            bl.pt['a'] = a0b; bl.pt['d'] = a1b
            bl.start(s_above)
            rows_below = bottom - cba
            lower_size = (rows_below << 6) | (W1 & 0x3f)
            off = rows_above * 2 * (W1 & 0x3f)
            a0b += off; a1b += off
    if con_cookie is None:
        bl.mod['a'] = 0; bl.mod['d'] = 0; bl.mod['b'] = 0
        bl.pt['a'] = a1b; bl.pt['b'] = a0b; bl.pt['d'] = a1b
        bl.con0 = d7 | 0xd30
        bl.start(lower_size)
        con_cookie = 0xfca
    # cookie-cut the 4 colour planes onto the screen
    bl.mod['c'] = d3s; bl.mod['d'] = d3s; bl.mod['a'] = 0
    bl.con0 = con_cookie; bl.con1 = d7 & 0xf000
    bl.pt['b'] = 0x604a4 + d2
    for p in range(4):
        bl.pt['a'] = 0x604a4
        bl.pt['c'] = scr + p * 0x2000
        bl.pt['d'] = scr + p * 0x2000
        bl.start(size)


def main():
    pre = bytearray(open(sys.argv[1], 'rb').read())
    post = open(sys.argv[2], 'rb').read()
    calls = []
    for line in open(sys.argv[3]):
        mm = re.search(r'BP 01920a d0=([0-9a-f]+) d1=([0-9a-f]+)', line)
        if mm:
            calls.append((int(mm.group(1), 16), int(mm.group(2), 16) & 0xffff))
        if 'BP 017328' in line:
            break
    m = pre
    bl = Blitter(m)
    draw_tiles(m, bl)
    back = L(m, A6 + 0x62)
    t_ok = sum(1 for p in range(4) for i in range(0x1680) if m[back + p * 0x2000 + i] == post[back + p * 0x2000 + i])
    for d0, d1 in calls:
        draw_bob(m, bl, d0, d1)
    ok = 0
    bad = []
    for p in range(4):
        for i in range(0x1680):
            a = back + p * 0x2000 + i
            if m[a] == post[a]:
                ok += 1
            elif len(bad) < 10:
                bad.append((p, i // 40, i % 40, m[a], post[a]))
    print('back buffer %05x: %d/%d bytes match (%d bob calls); tiles-only match %d' % (back, ok, 4 * 0x1680, len(calls), t_ok))
    for b in bad:
        print('  mismatch plane %d line %d byte %d: sim %02x real %02x' % b)
    if len(sys.argv) > 4:
        from PIL import Image
        pal = [W(post, 0x115fa + 4 * i) for i in range(16)]
        im = Image.new('RGB', (320, 288))
        px = im.load()
        for half, src in enumerate((m, post)):
            for y in range(144):
                for xb in range(40):
                    bs = [src[back + p * 0x2000 + y * 40 + xb] for p in range(4)]
                    for b in range(8):
                        c = sum(((bs[p] >> (7 - b)) & 1) << p for p in range(4))
                        v = pal[c]
                        px[xb * 8 + b, y + 144 * half] = (((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17)
        im.save(sys.argv[4])


if __name__ == '__main__':
    main()
