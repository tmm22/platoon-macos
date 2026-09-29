#!/usr/bin/env python3
"""Extract FLARE-section assets (Platoon, Amiga) from re/platoon_darc.adf.

Load section 1 ("THE TUNNEL & FLARE SECTIONS") = ADF tracks $54.. (27 tracks) loaded to RAM $17000.
RAM address A (in $17000..$3c2a0) <-> ADF offset $73800 + (A - $17000).  (Verified identical to the RAM dump
re/dumps/ram_section1.bin for all data used here.)

Outputs in re/flare/assets/:
  bg_pal{0..3}.png      flare-section background ($36242 RLE -> 320x144x4 planes) in the 4 night/flare palettes
  bg_sequence.png       the 7-step flare palette sequence side by side
  bobs/frame_XX.png     every bob frame of the section-1 bob bank (anim table $1e020), RGBA (mask = alpha),
                        rendered with the brightest flare palette ($19ff2)
  bobs_flare_used.png   contact sheet of the frames the flare section uses (crosshair/flare/muzzle/enemy)
  recolored_color4.png  crosshair + muzzle frames as recoloured by L_0189c0 (solid colour 4)
  palettes.json, tables.json, messages.json
  compare_bg.png        (if --compare SHOT.png given) extracted bg vs emulator screenshot crop
"""
import sys, os, json, struct
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ADF = os.path.join(ROOT, 're', 'platoon_darc.adf')
OUT = os.path.join(ROOT, 're', 'flare', 'assets')
adf = open(ADF, 'rb').read()
SEC_BASE = 0x54 * 0x1600          # ADF offset of RAM $17000

def ram(addr, n):
    o = SEC_BASE + addr - 0x17000
    return adf[o:o + n]
def w(addr): return struct.unpack('>H', ram(addr, 2))[0]
def l(addr): return struct.unpack('>I', ram(addr, 4))[0]

def amiga_rgb(c):
    return (((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17)
def palette(addr, n=16): return [w(addr + 2 * i) & 0xfff for i in range(n)]

# ---------------------------------------------------------------- palettes
PAL_TABLE = 0x19f76                      # 7 longword pointers, indexed by $3b222 (0,4,..,$18)
PAL_SEQ = [l(PAL_TABLE + 4 * i) for i in range(7)]
DUR_TABLE = 0x19f6e                      # 8 bytes: iterations until the next palette step
DUR = list(ram(DUR_TABLE, 8))
NIGHT = {0x19f92: 'night0_dark', 0x19fb2: 'night1', 0x19fd2: 'night2', 0x19ff2: 'night3_brightest'}

# ---------------------------------------------------------------- background (L_018e92)
def decode_bg(src=0x36242):
    """RLE: b>=0: copy b+1 literal bytes; b==$80: no-op; b<0: repeat next byte (-b)+1 times.
    Output stream order: row0 plane0 (40 bytes), row0 plane1, row0 plane2, row0 plane3, row1 plane0 ...
    stops after 144 rows (5760 bytes/plane), even in the middle of a run."""
    planes = [bytearray(40 * 144) for _ in range(4)]
    total = 40 * 4 * 144
    out = bytearray()
    p = src
    while len(out) < total:
        b = ram(p, 1)[0]; p += 1
        if b < 0x80:
            n = b + 1
            out += ram(p, n); p += n
        elif b == 0x80:
            continue
        else:
            n = ((-b) & 0x7f) + 1        # neg.b then and #$7f, dbra count -> n = that+1
            out += ram(p, 1) * n; p += 1
    out = out[:total]
    for row in range(144):
        for pl in range(4):
            o = (row * 4 + pl) * 40
            planes[pl][row * 40:row * 40 + 40] = out[o:o + 40]
    return planes, p - src

def planar_to_idx(planes, wbytes, h):
    W = wbytes * 8
    idx = [[0] * W for _ in range(h)]
    for y in range(h):
        for xb in range(wbytes):
            bs = [planes[pl][y * wbytes + xb] for pl in range(len(planes))]
            for bit in range(8):
                v = 0
                for pl in range(len(planes)):
                    if bs[pl] & (0x80 >> bit): v |= 1 << pl
                idx[y][xb * 8 + bit] = v
    return idx

def render(idx, pal, alpha=None):
    h = len(idx); W = len(idx[0])
    im = Image.new('RGBA' if alpha else 'RGB', (W, h))
    px = im.load()
    for y in range(h):
        for x in range(W):
            c = amiga_rgb(pal[idx[y][x]])
            if alpha: px[x, y] = c + ((255 if alpha[y][x] else 0),)
            else: px[x, y] = c
    return im

# ---------------------------------------------------------------- bobs
BOB_BASE = 0x1e220
ANIM_TABLE = 0x1e020
def bob_frames():
    fr = []
    a = ANIM_TABLE
    while True:
        off = l(a)
        hdr2 = l(a + 4)
        if off == 0 and a != ANIM_TABLE: break
        fr.append((a, off, hdr2)); a += 8
    return fr

def decode_bob(off):
    hdr = l(BOB_BASE + off)
    wwords = (hdr >> 16) + 1; h = (hdr & 0xffff) + 1
    psz = wwords * 2 * h
    d = ram(BOB_BASE + off + 4, psz * 5)
    mask = d[:psz]; planes = [d[psz * (i + 1):psz * (i + 2)] for i in range(4)]
    return wwords, h, mask, planes

def main():
    os.makedirs(OUT, exist_ok=True); os.makedirs(os.path.join(OUT, 'bobs'), exist_ok=True)
    planes, used = decode_bg()
    idx = planar_to_idx(planes, 40, 144)
    for i, a in enumerate(sorted(NIGHT)):
        render(idx, palette(a)).save(os.path.join(OUT, 'bg_pal%d.png' % i))
    seq = Image.new('RGB', (320, 144 * 7 + 6 * 4))
    for i, a in enumerate(PAL_SEQ):
        seq.paste(render(idx, palette(a)), (0, i * 148))
    seq.save(os.path.join(OUT, 'bg_sequence.png'))

    frames = bob_frames()
    lit = palette(0x19ff2)
    meta = []
    for n, (a, off, hdr2) in enumerate(frames):
        wwords, h, mask, pls = decode_bob(off)
        idxb = planar_to_idx(pls, wwords * 2, h)
        al = planar_to_idx([mask], wwords * 2, h)
        render(idxb, lit, al).save(os.path.join(OUT, 'bobs', 'frame_%02d.png' % n))
        meta.append({'index': n, 'table_entry': '%05x' % a, 'offset': '%04x' % off, 'addr': '%05x' % (BOB_BASE + off),
                     'width_words': wwords, 'height': h, 'hdr_copy': '%08x' % hdr2})
    used_sets = [('crosshair', [0]), ('flare', [1, 2, 3, 4]), ('muzzle', [5, 6]), ('enemy', list(range(12, 20)))]
    sheet = Image.new('RGBA', (8 * 40 * 3, 4 * 60 * 3), (40, 40, 40, 255))
    for r, (name, lst) in enumerate(used_sets):
        for c, n in enumerate(lst):
            im = Image.open(os.path.join(OUT, 'bobs', 'frame_%02d.png' % n))
            sheet.alpha_composite(im.resize((im.width * 3, im.height * 3), Image.NEAREST), (c * 120, r * 180))
    sheet.save(os.path.join(OUT, 'bobs_flare_used.png'))
    # L_0189c0 recolour: plane0=0, plane1=0, plane2=mask, plane3=0  => colour 4 ($777 in all night palettes)
    rc = Image.new('RGBA', (3 * 40, 24), (0, 0, 0, 255))
    for c, n in enumerate([0, 5, 6]):
        wwords, h, mask, pls = decode_bob(frames[n][1])
        al = planar_to_idx([mask], wwords * 2, h)
        idxb = [[4 if v else 0 for v in row] for row in al]
        rc.alpha_composite(render(idxb, palette(0x19f92), al), (c * 40, 0))
    rc.save(os.path.join(OUT, 'recolored_color4.png'))

    pals = {'%05x' % a: {'name': NIGHT.get(a, ''), 'colors': ['%03x' % c for c in palette(a)]}
            for a in sorted(set(PAL_SEQ))}
    pals['1a012'] = {'name': 'tunnel working palette (used by red-flash fade L_017e60)', 'colors': ['%03x' % c for c in palette(0x1a012)]}
    pals['1a032'] = {'name': 'tunnel palette master copy', 'colors': ['%03x' % c for c in palette(0x1a032)]}
    pals['1a06e'] = {'name': 'HUD palette (colours via second copper block, $f87c)', 'colors': ['%03x' % c for c in palette(0x1a06e)]}
    json.dump(pals, open(os.path.join(OUT, 'palettes.json'), 'w'), indent=1)

    tables = {
        'palette_sequence_19f76': ['%05x' % a for a in PAL_SEQ],
        'palette_step_duration_19f6e': DUR,
        'spawn_slots_19f4e': [{'used': ram(0x19f4e + 4 * i, 1)[0], 'x': w(0x19f50 + 4 * i)} for i in range(8)],
        'score_per_kill_1a0a0_bcd': ram(0x1a0a0, 4).hex(),
        'bg_rle_src': '36242', 'bg_rle_bytes_consumed': used,
        'bob_frames': meta,
    }
    json.dump(tables, open(os.path.join(OUT, 'tables.json'), 'w'), indent=1)

    msgs = {}
    for i in range(0x2a):
        p = l(0x19374 + 4 * i)
        e = ram(p, 80).index(b'\xff')
        s = ram(p, e)
        msgs['%02x' % i] = {'addr': '%05x' % p, 'x_col': s[0], 'y_row': s[1], 'text': s[2:].decode('latin1')}
    json.dump(msgs, open(os.path.join(OUT, 'messages.json'), 'w'), indent=1)

    if len(sys.argv) > 2 and sys.argv[1] == '--compare':
        shot = Image.open(sys.argv[2]).convert('RGB')
        ox, oy = int(sys.argv[3]) if len(sys.argv) > 3 else 17, int(sys.argv[4]) if len(sys.argv) > 4 else 36
        crop = shot.crop((ox, oy, ox + 320, oy + 144))
        ref = render(idx, palette(int(sys.argv[5], 16) if len(sys.argv) > 5 else 0x19f92))
        if len(sys.argv) > 7:   # composite the recoloured crosshair (colour 4) at playfield x,y like blit_bob_normal
            cx, cy = int(sys.argv[6], 16), int(sys.argv[7], 16)
            wwords, h, mask, pls = decode_bob(frames[0][1])
            al = planar_to_idx([mask], wwords * 2, h)
            pal = palette(int(sys.argv[5], 16))
            for yy in range(h):
                for xx in range(wwords * 16):
                    if al[yy][xx] and 0 <= cx + xx < 320: ref.putpixel((cx + xx, cy + yy), amiga_rgb(pal[4]))
        diff = sum(1 for a, b in zip(crop.getdata(), ref.getdata()) if a != b)
        cmpim = Image.new('RGB', (320, 288)); cmpim.paste(ref, (0, 0)); cmpim.paste(crop, (0, 144))
        cmpim.save(os.path.join(OUT, 'compare_bg.png'))
        print('pixels differing from screenshot crop:', diff)
    print('frames:', len(frames), 'bg rle bytes:', used)

if __name__ == '__main__':
    main()
