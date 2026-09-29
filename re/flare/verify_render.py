#!/usr/bin/env python3
"""Verify the flare-section object rendering model against emulator RAM.
usage: verify_render.py PRE.bin POST.bin
PRE = chip RAM dumped at $18ca8 (before flare_update_draw_objects), POST = dumped at $18cac (after).
Simulates: list1 ($19e0a) entries 7..0 with blit_bob_night (mask &= ~(screen==15)), then list2 ($19eac) entries
7..0 with blit_bob_normal, on the PRE back buffer using POST object states; compares with POST back buffer."""
import sys, struct
pre = bytearray(open(sys.argv[1], 'rb').read()); post = open(sys.argv[2], 'rb').read()
W = lambda m, a: struct.unpack('>H', m[a:a + 2])[0]
L = lambda m, a: struct.unpack('>I', m[a:a + 4])[0]
S = lambda m, a: struct.unpack('>h', m[a:a + 2])[0]
back = L(pre, 0x12dde + 0x62)
def getpix(buf, x, y):
    v = 0
    for p in range(4):
        b = buf[back + p * 0x2000 + y * 40 + (x >> 3)]
        if b & (0x80 >> (x & 7)): v |= 1 << p
    return v
def setpix(buf, x, y, v):
    for p in range(4):
        a = back + p * 0x2000 + y * 40 + (x >> 3); bit = 0x80 >> (x & 7)
        buf[a] = (buf[a] | bit) if v & (1 << p) else (buf[a] & ~bit)
def draw(buf, obj, night):
    x = W(post, obj + 2); y = W(post, obj + 4)
    anim = L(post, obj + 6); fr = post[obj + 1]
    bob = 0x1e220 + L(post, anim + fr * 8)
    hdr = L(pre, bob); ww = (hdr >> 16) + 1; h = (hdr & 0xffff) + 1; psz = ww * 2 * h
    d = bob + 4
    # destination is word aligned: x0 = (x>>3)&~1 bytes; bob drawn (w+1) words wide with shift x&15
    xb = ((x >> 3) & 0xfe) * 8; sh = x & 15
    # colour-15 test uses the screen as it is at the moment of this blit (so after earlier objects)
    todo = []
    for yy in range(h):
        for xx in range(ww * 16):
            m = pre[d + yy * ww * 2 + (xx >> 3)] & (0x80 >> (xx & 7))
            if not m: continue
            v = 0
            for p in range(4):
                if pre[d + psz * (p + 1) + yy * ww * 2 + (xx >> 3)] & (0x80 >> (xx & 7)): v |= 1 << p
            px = xb + sh + xx; py = y + yy
            if px >= 320 + 16 or py >= 256: continue   # clipping is not done by the game; ignore off-buffer
            todo.append((px, py, v))
    if night:
        todo = [(px, py, v) for (px, py, v) in todo if getpix(buf, px, py) != 15]
    for px, py, v in todo:
        setpix(buf, px, py, v)
for obj in [0x19e0a + 0x12 * i for i in range(7, -1, -1)]:
    if post[obj]: draw(pre, obj, True)
for obj in [0x19eac + 0x12 * i for i in range(7, -1, -1)]:
    if post[obj]: draw(pre, obj, False)
diff = sum(1 for p in range(4) for a in range(back + p * 0x2000, back + p * 0x2000 + 144 * 40) if pre[a] != post[a])
act = [(hex(o), post[o + 1], W(post, o + 2), W(post, o + 4)) for o in [0x19e0a + 0x12 * i for i in range(8)] + [0x19eac + 0x12 * i for i in range(8)] if post[o]]
print('back buffer %05x  active objects (addr,frame,x,y): %s' % (back, act))
print('differing bytes after simulation:', diff)
