"""Shared helpers for the tunnels module (section 1 of Platoon, Amiga).

Loads section 1 exactly as the game does (ADF tracks $54.., $1b tracks -> RAM $17000) and implements
the original tunnel view / map algorithms so they can be checked against emulator screenshots.
"""
import os, struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')
BASE = 0x17000
TRACK = 0x1600


def load_section1(adf=ADF):
    d = open(adf, 'rb').read()
    return d[0x54 * TRACK:(0x54 + 0x1b) * TRACK]  # $25200 bytes -> $17000..$3c200


class Mem:
    """RAM view of the section image (addresses are absolute Amiga addresses)."""
    def __init__(self, data=None, base=BASE):
        self.d = bytearray(data if data is not None else load_section1())
        self.base = base

    def b(self, a):
        return self.d[a - self.base]

    def w(self, a):
        return struct.unpack('>H', self.d[a - self.base:a - self.base + 2])[0]

    def sw(self, a):
        return struct.unpack('>h', self.d[a - self.base:a - self.base + 2])[0]

    def l(self, a):
        return struct.unpack('>I', self.d[a - self.base:a - self.base + 4])[0]

    def blk(self, a, n):
        return bytes(self.d[a - self.base:a - self.base + n])


def amiga_rgb(c):
    return (((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17)


def palette(m, a, n=16):
    return [amiga_rgb(m.w(a + 2 * i)) for i in range(n)]


# ---------------------------------------------------------------- constants (addresses in section 1)
MAP = 0x29720          # 43x43 bytes maze map, row-major, cell = MAP + y*43 + x
MAPW = 43
TILES = 0x1a400        # 256 view tiles, 32 bytes each (8 rows x 4 planes, 1 byte per plane)
VIEWMAPS = 0x1c400     # 40 view tile maps (10 cols x 18 rows = 180 bytes each)
MAPTILES = 0x29220     # 40 map-display tiles, same 32 byte format, index = map cell value
PAL_VIEW = 0x1a032     # tunnel palette (16 words)
PAL_TEXT = 0x1a052     # palette used on text screens
PAL_HUD = 0x1a06e      # lower (HUD) palette, passed to kernel f87c
DIRDELTA = 0x19cc2     # 4 x (dx.b, dy.b)
DIROFS = 0x19cca       # 4 longs -> 3 words (left, right, forward) map offsets per direction
ROOMPOS = 0x19aec      # 10 words (x<<8|y) room entry cells
ROOMTYPE = 0x19a24     # 10 words: picture/hotspot type per room (0..3)
ROOMPICS = 0x19a14     # 4 longs: picture address per type
ROOMITEMS = 0x19a38    # 10 longs: pointer to item-code word list per room
HOTSPOTS = 0x19b00     # 4 longs: hotspot rectangle lists per room type
FRAMETAB = 0x1e020     # bob frame table (8 bytes: long offset from $1e220, long header copy)
BOBBASE = 0x1e220
MSGTAB = 0x19374       # 42 message pointers (kernel message system)


def planar_tile(m, a):
    """Decode one 8x8 tile (32 bytes: row r = 4 bytes plane0..3) -> 8x8 list of colour indices."""
    px = []
    for r in range(8):
        p = m.blk(a + r * 4, 4)
        px.append([sum(((p[k] >> (7 - x)) & 1) << k for k in range(4)) for x in range(8)])
    return px


def view_indices(m, x, y, d):
    """Exact port of $17406 (without the draw): returns (d6, d7) = left/right half view codes."""
    ofs = m.l(DIROFS + 4 * (d & 3))
    lft, rgt, fwd = m.sw(ofs), m.sw(ofs + 2), m.sw(ofs + 4)
    cell0 = MAP + y * MAPW + x

    def c(o):
        return m.b(cell0 + o)

    def side(off, right):
        v = 0
        d3 = fwd
        hit = False
        for d4 in (3, 2, 1, 0):
            if c(d3) == 3:
                v |= 0x10 | d4; hit = True; break
            if c(d3) != 2:
                v |= 0x08 | d4; hit = True; break
            d3 += fwd
        o = off
        for d4 in (3, 2, 1, 0):
            if c(o) == 2:
                if right:
                    v = (v | 4) & 0xfc | d4   # right side: bset #2, andi #$fc, or d4
                else:
                    v |= 4 | d4
                break
            o += fwd
        return v & 0xff

    d6 = side(lft, False)
    d7 = side(rgt, True)
    if d6 == 0 and d7 == 0:
        # long straight corridor: animate with position
        if d & 1:
            d6 = d7 = x & 3
        else:
            d6 = d7 = y & 3
    elif d6 == 0:
        d6 = d7 & 3
    elif d7 == 0:
        d7 = d6 & 3
    return d6, d7


def render_view(m, x, y, d, pal=None):
    """Render the 160x144 corridor view exactly as $17406/$1756c draw it."""
    pal = pal or palette(m, PAL_VIEW)
    d6, d7 = view_indices(m, x, y, d)
    im = Image.new('RGB', (160, 144))
    px = im.load()
    for half, idx in ((0, d6), (1, d7 + 0x14)):
        tm = VIEWMAPS + (idx & 0xff) * 180
        for row in range(18):
            for col in range(10):
                t = m.b(tm + row * 10 + col)
                tp = planar_tile(m, TILES + t * 32)
                for yy in range(8):
                    for xx in range(8):
                        px[half * 80 + col * 8 + xx, row * 8 + yy] = pal[tp[yy][xx]]
    return im, (d6, d7)


def render_tilemap(m, idx, pal=None):
    pal = pal or palette(m, PAL_VIEW)
    im = Image.new('RGB', (80, 144))
    px = im.load()
    tm = VIEWMAPS + idx * 180
    for row in range(18):
        for col in range(10):
            tp = planar_tile(m, TILES + m.b(tm + row * 10 + col) * 32)
            for yy in range(8):
                for xx in range(8):
                    px[col * 8 + xx, row * 8 + yy] = pal[tp[yy][xx]]
    return im


def decode_bob(m, off):
    """Bob at $1e220+off: long header ((w-1)<<16 | (h-1)), then 5 planes of h rows x w words:
    plane 0 = mask, planes 1..4 = bitplanes 0..3.  Returns (wpx, h, pixels[h][wpx] (None=transparent))."""
    a = BOBBASE + off
    hdr = m.l(a)
    ww = (hdr >> 16) + 1
    h = (hdr & 0xffff) + 1
    ps = ww * 2 * h
    data = m.blk(a + 4, ps * 5)
    out = []
    for r in range(h):
        row = []
        for x in range(ww * 16):
            byte = r * ww * 2 + x // 8
            bit = 7 - (x & 7)
            mask = (data[byte] >> bit) & 1
            col = 0
            for p in range(4):
                col |= ((data[ps * (p + 1) + byte] >> bit) & 1) << p
            row.append(col if mask else None)
        out.append(row)
    return ww * 16, h, out


def recolour_crosshair(m):
    """Port of $1897a: for bob 0 (crosshair): plane1 := mask, planes 2..4 := 0 (drawn in colour 1)."""
    a = BOBBASE
    hdr = m.l(a)
    ww = (hdr >> 16) + 1
    h = (hdr & 0xffff) + 1
    ps = ww * 2 * h
    o = a + 4 - m.base
    for i in range(ps):
        m.d[o + ps + i] = m.d[o + i]
        m.d[o + 2 * ps + i] = 0
        m.d[o + 3 * ps + i] = 0
        m.d[o + 4 * ps + i] = 0


def bob_image(m, off, pal):
    w, h, px = decode_bob(m, off)
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    p = im.load()
    for y in range(h):
        for x in range(w):
            if px[y][x] is not None:
                p[x, y] = pal[px[y][x]] + (255,)
    return im


def room_picture(m, a, pal):
    """Room picture: byte wbytes, byte hchars, then rows of (w/2) words, each word = 4 plane words interleaved."""
    wb, hc = m.b(a), m.b(a + 1)
    rows = hc * 8
    im = Image.new('RGB', (wb * 8, rows))
    px = im.load()
    p = a + 2
    for r in range(rows):
        for wi in range(wb // 2):
            ws = [m.w(p + 2 * k) for k in range(4)]
            p += 8
            for x in range(16):
                col = sum(((ws[k] >> (15 - x)) & 1) << k for k in range(4))
                px[wi * 16 + x, r] = pal[col]
    return im
