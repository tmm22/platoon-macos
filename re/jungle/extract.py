#!/usr/bin/env python3
"""Asset extractor for Platoon (Amiga) section 0 (JUNGLE & VILLAGE) -- re/jungle module.

Reads the section data straight from the ADF (re/platoon_darc.adf): section 0 is stored
UNCOMPRESSED on tracks $15..$4c (56 tracks) and loaded 1:1 to RAM $17000..$64000, so
RAM address A  <->  ADF offset A - $17000 + $15*$1600.

Writes into re/jungle/assets/:
  palettes.json / palettes.png      playfield palette ($19ff8, with colour 6 per level),
                                    HUD palette ($1a018), message-fade table ($19fd8)
  tiles.png                         all 152 64x48 background tiles ($1c000 + n*$600)
  tile_attr.png                     8x6 collision/attribute cells of every tile ($5dc00 + n*$30)
  map_full.png                      the complete section-0 map: 6 "levels" x 3 tile rows x 90 tiles
  map_level<N>.png                  one PNG per level (5760x144)
  map_attr_full.png                 the collision cells of the whole map (solid cells highlighted)
  bobs.png / bobs.json              all 101 bobs ($55000 directory, $55400 data) with mask
  frames.png / frames.json          the 128 composite animation frames ($1a1c6 lists + $1a536 offsets)
  map.json                          raw map bytes per level
  messages.json                     message table $1a6de (25 messages)
  tables.json                       misc tables (jump arc, grenade arc, village item table, ...)

Optionally:  extract.py --render RAMDUMP OUT.png  re-implements the in-game renderer
(tile blits of $18cf4 + bob blits of $1920a incl. the foreground-priority mask) from a RAM dump
and writes the 320x144 back buffer so it can be compared with the emulator's screen.
"""
import os, sys, json, struct
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')
OUT = os.path.join(HERE, 'assets')

SEC_BASE = 0x17000
SEC_ADF = 0x15 * 0x1600
SEC_LEN = 0x38 * 0x1600


def load_section(adf_path=ADF):
    adf = open(adf_path, 'rb').read()
    mem = bytearray(0x80000)
    mem[SEC_BASE:SEC_BASE + SEC_LEN] = adf[SEC_ADF:SEC_ADF + SEC_LEN]
    return mem


def w(m, a):
    return struct.unpack('>H', m[a:a + 2])[0]


def sw(m, a):
    return struct.unpack('>h', m[a:a + 2])[0]


def l(m, a):
    return struct.unpack('>I', m[a:a + 4])[0]


def amiga_rgb(c):
    return (((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17)


# ---------------------------------------------------------------- constants (addresses)
PAL_PLAYFIELD = 0x19ff8     # 16 words; word 6 ($1a004) is patched per level by $17a48
PAL_HUD = 0x1a018           # 16 words, lower (HUD) copper palette
PAL_BLACK = 0x1a038
MSG_FADE = 0x19fd8          # 8 longs, $34(a6) table used by the kernel message fader
MAP = 0x1b000               # 6 levels * $10e bytes (3 rows * 90)
MAP_LEVEL_STRIDE = 0x10e
MAP_ROW = 90
TILE_GFX = 0x1c000          # 152 tiles * $600 bytes (4 planes * 48 rows * 8 bytes, plane-sequential)
TILE_ATTR = 0x5dc00         # 152 tiles * $30 bytes (6 rows * 8 cells)
NTILES = 0x98
BOB_DIR = 0x55000           # 8-byte entries: offset.l (from $55400), copy of header.l
BOB_DATA = 0x55400
NBOBS = 101
FRAME_TAB = 0x1a1c6         # 128 longs -> $ff-terminated bob-index lists
BOB_OFS = 0x1a536           # per bob index: x.w, y.w offset (added as one 32-bit long)
MSG_TAB = 0x1a6de           # 25 pointers to messages (x.b, y.b, text, $ff)


def level_palette(m, level):
    pal = [w(m, PAL_PLAYFIELD + 2 * i) for i in range(16)]
    # $17a48: colour 6 = $0ca2 when level is 0 or 5 (village levels), else $000d
    pal[6] = 0x0ca2 if level in (0, 5) else 0x000d
    return pal


def tile_image(m, idx, pal):
    a = TILE_GFX + idx * 0x600
    im = Image.new('RGB', (64, 48))
    px = im.load()
    P = [amiga_rgb(c) for c in pal]
    for y in range(48):
        for xb in range(8):
            bs = [m[a + p * 0x180 + y * 8 + xb] for p in range(4)]
            for b in range(8):
                c = 0
                for p in range(4):
                    c |= ((bs[p] >> (7 - b)) & 1) << p
                px[xb * 8 + b, y] = P[c]
    return im


def is_solid(v):
    # $19ed2: a cell is solid when its attribute byte is $b0, $da, or $c0..$d0
    return v == 0xb0 or v == 0xda or (0xc0 <= v < 0xd1)


def bob_info(m, i):
    off = l(m, BOB_DIR + 8 * i)
    b = BOB_DATA + off
    hdr = l(m, b)
    W = (hdr >> 16) + 1
    H = (hdr & 0xffff) + 1
    return b + 4, W, H


def bob_image(m, i, pal, with_mask=False):
    d, W, H = bob_info(m, i)
    P = [amiga_rgb(c) for c in pal]
    im = Image.new('RGBA', (W * 16, H), (0, 0, 0, 0))
    px = im.load()
    rowb = W * 2
    for r in range(H):
        for x in range(W * 16):
            byte = x >> 3
            bit = 7 - (x & 7)
            msk = (m[d + r * rowb + byte] >> bit) & 1
            c = 0
            for p in range(4):
                c |= ((m[d + ((p + 1) * H + r) * rowb + byte] >> bit) & 1) << p
            if msk:
                px[x, r] = P[c] + (255,)
            elif with_mask:
                px[x, r] = (255, 0, 255, 255)
    return im


def frame_list(m, f):
    p = l(m, FRAME_TAB + 4 * f)
    out = []
    while m[p] != 0xff:
        out.append(m[p])
        p += 1
    return p, out


def bob_offset(m, i):
    return sw(m, BOB_OFS + 4 * i), sw(m, BOB_OFS + 4 * i + 2)


def read_message(m, i):
    p = l(m, MSG_TAB + 4 * i)
    x, y = m[p], m[p + 1]
    s = bytearray()
    q = p + 2
    while m[q] != 0xff:
        s.append(m[q])
        q += 1
    return p, x, y, s.decode('latin1')


def save_sheet(images, cols, cell_w, cell_h, labels, path, bg=(40, 40, 40), scale=1):
    rows = (len(images) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * cell_w, rows * (cell_h + 10)), bg)
    dr = ImageDraw.Draw(sheet)
    for k, im in enumerate(images):
        cx, cy = (k % cols) * cell_w, (k // cols) * (cell_h + 10)
        if im.mode == 'RGBA':
            sheet.paste(im, (cx, cy + 10), im)
        else:
            sheet.paste(im, (cx, cy + 10))
        dr.text((cx + 1, cy), labels[k], fill=(255, 255, 0))
    if scale != 1:
        sheet = sheet.resize((sheet.width * scale, sheet.height * scale), Image.NEAREST)
    sheet.save(path)


def extract_all(m):
    os.makedirs(OUT, exist_ok=True)
    # ------------------------------------------------ palettes
    pals = {
        'playfield_jungle(levels1-4)': [w(m, PAL_PLAYFIELD + 2 * i) for i in range(16)],
        'hud': [w(m, PAL_HUD + 2 * i) for i in range(16)],
        'message_fade_$19fd8': [l(m, MSG_FADE + 4 * i) for i in range(8)],
    }
    pals['playfield_jungle(levels1-4)'][6] = 0x000d
    pals['playfield_village(levels0,5)'] = level_palette(m, 0)
    json.dump({k: ['%04x' % c if c < 0x10000 else '%08x' % c for c in v] for k, v in pals.items()},
              open(os.path.join(OUT, 'palettes.json'), 'w'), indent=1)
    pim = Image.new('RGB', (16 * 16, 3 * 16))
    dr = ImageDraw.Draw(pim)
    for r, key in enumerate(['playfield_jungle(levels1-4)', 'playfield_village(levels0,5)', 'hud']):
        for i, c in enumerate(pals[key]):
            dr.rectangle([i * 16, r * 16, i * 16 + 15, r * 16 + 15], fill=amiga_rgb(c))
    pim.resize((pim.width * 2, pim.height * 2), Image.NEAREST).save(os.path.join(OUT, 'palettes.png'))

    # ------------------------------------------------ tiles
    jpal = level_palette(m, 1)
    tiles = [tile_image(m, i, jpal) for i in range(NTILES)]
    save_sheet(tiles, 16, 68, 48, ['%02x' % i for i in range(NTILES)], os.path.join(OUT, 'tiles.png'))
    # attribute cells
    attr_imgs = []
    for i in range(NTILES):
        im = tiles[i].copy()
        dr = ImageDraw.Draw(im)
        for cy in range(6):
            for cx in range(8):
                v = m[TILE_ATTR + i * 0x30 + cy * 8 + cx]
                if is_solid(v):
                    dr.rectangle([cx * 8, cy * 8, cx * 8 + 7, cy * 8 + 7], outline=(255, 0, 0))
        attr_imgs.append(im)
    save_sheet(attr_imgs, 16, 68, 48, ['%02x' % i for i in range(NTILES)],
               os.path.join(OUT, 'tile_attr.png'))
    # ------------------------------------------------ map
    full = Image.new('RGB', (MAP_ROW * 64, 6 * 144 + 5 * 16), (60, 0, 60))
    fa = Image.new('RGB', (MAP_ROW * 64, 6 * 144 + 5 * 16), (60, 0, 60))
    mapj = {}
    for lv in range(6):
        pal = level_palette(m, lv)
        cache = {}
        img = Image.new('RGB', (MAP_ROW * 64, 144))
        rows = []
        for r in range(3):
            row = list(m[MAP + lv * MAP_LEVEL_STRIDE + r * MAP_ROW: MAP + lv * MAP_LEVEL_STRIDE + (r + 1) * MAP_ROW])
            rows.append(row)
            for c, t in enumerate(row):
                if t not in cache:
                    cache[t] = tile_image(m, t, pal)
                img.paste(cache[t], (c * 64, r * 48))
        mapj['level%d' % lv] = [' '.join('%02x' % t for t in row) for row in rows]
        dr = ImageDraw.Draw(img)
        for c in range(0, MAP_ROW, 5):
            dr.text((c * 64 + 2, 2), 'x=%d' % c, fill=(255, 255, 255))
        img.save(os.path.join(OUT, 'map_level%d.png' % lv))
        full.paste(img, (0, lv * 160))
        a = img.copy()
        dr = ImageDraw.Draw(a)
        for r in range(3):
            for c, t in enumerate(rows[r]):
                for cy in range(6):
                    for cx in range(8):
                        v = m[TILE_ATTR + t * 0x30 + cy * 8 + cx]
                        if is_solid(v):
                            X, Y = c * 64 + cx * 8, r * 48 + cy * 8
                            dr.rectangle([X, Y, X + 7, Y + 7], outline=(255, 0, 0))
        fa.paste(a, (0, lv * 160))
    full.save(os.path.join(OUT, 'map_full.png'))
    fa.save(os.path.join(OUT, 'map_attr_full.png'))
    json.dump(mapj, open(os.path.join(OUT, 'map.json'), 'w'), indent=1)

    # ------------------------------------------------ bobs
    bobs = []
    binfo = []
    for i in range(NBOBS):
        d, W, H = bob_info(m, i)
        bobs.append(bob_image(m, i, jpal))
        xo, yo = bob_offset(m, i)
        binfo.append({'index': i, 'data': '%05x' % d, 'width_words': W, 'height': H,
                      'draw_offset_x': xo, 'draw_offset_y': yo})
    save_sheet(bobs, 12, 40, 36, ['%d' % i for i in range(NBOBS)], os.path.join(OUT, 'bobs.png'), scale=2)
    json.dump(binfo, open(os.path.join(OUT, 'bobs.json'), 'w'), indent=1)

    # ------------------------------------------------ composite frames
    frames = []
    finfo = []
    for f in range(128):
        p, lst = frame_list(m, f)
        im = Image.new('RGBA', (80, 64), (0, 0, 0, 0))
        for bi in lst:
            if bi >= NBOBS:
                continue
            xo, yo = bob_offset(m, bi)
            b = bob_image(m, bi, jpal)
            im.paste(b, (24 + xo, 4 + yo), b)
        frames.append(im)
        finfo.append({'frame': f, 'list_addr': '%05x' % l(m, FRAME_TAB + 4 * f), 'bobs': lst})
    save_sheet(frames, 16, 80, 64, ['%d' % f for f in range(128)], os.path.join(OUT, 'frames.png'), scale=2)
    json.dump(finfo, open(os.path.join(OUT, 'frames.json'), 'w'), indent=1)

    # ------------------------------------------------ messages + tables
    msgs = []
    for i in range(25):
        p, x, y, s = read_message(m, i)
        msgs.append({'id': i, 'addr': '%05x' % p, 'x': x, 'y': y, 'text': s})
    json.dump(msgs, open(os.path.join(OUT, 'messages.json'), 'w'), indent=1)
    tables = {
        'jump_arc_$1a194': [sw(m, 0x1a194 + 2 * i) for i in range(16)],
        'grenade_arc_$1a1b4': [sw(m, 0x1a1b4 + 2 * i) for i in range(9)],
        'hut_door_columns_$1aaf4': list(m[0x1aaf4:0x1aafa]),
        'village_item_table_$1aafa(lo,hi,msg,msg_after)': [list(m[0x1aafa + 4 * i:0x1aafe + 4 * i]) for i in range(20)],
        'score_bcd_$1a6ce_300': m[0x1a6ce:0x1a6d2].hex(),
        'score_bcd_$1a6d2_500': m[0x1a6d2:0x1a6d6].hex(),
        'score_bcd_$1a6d6_10000': m[0x1a6d6:0x1a6da].hex(),
        'start_position_$1a6da(x_tile,level)': [w(m, 0x1a6da), w(m, 0x1a6dc)],
        'bridge_tiles_$1b209_$1b20a(intact,broken)': [[0x8c, 0x8d], [0x95, 0x96]],
    }
    json.dump(tables, open(os.path.join(OUT, 'tables.json'), 'w'), indent=1)


# ============================================================================ renderer check
def render_from_ram(ram, out_png):
    """Re-implement $18cf4 (tile redraw) + the bob list of the main loop from a RAM dump
    taken right after a frame was rendered (e.g. breakpoint at $17328, before the swap)
    and write the back-buffer ($62(a6)) as PNG. Pure planar model of the blits."""
    m = ram
    level = w(m, 0x60c26)
    pal = [w(m, 0x115fa + 4 * i) for i in range(16)]  # palette actually in the copper list
    buf = l(m, 0x12dde + 0x62)
    W_, H_ = 320, 144
    im = Image.new('RGB', (W_, H_))
    px = im.load()
    P = [amiga_rgb(c) for c in pal]
    for y in range(H_):
        for xb in range(40):
            bs = [m[buf + p * 0x2000 + y * 40 + xb] for p in range(4)]
            for b in range(8):
                c = 0
                for p in range(4):
                    c |= ((bs[p] >> (7 - b)) & 1) << p
                px[xb * 8 + b, y] = P[c]
    im.save(out_png)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--render':
        render_from_ram(bytearray(open(sys.argv[2], 'rb').read()), sys.argv[3])
    else:
        mem = load_section()
        extract_all(mem)
        print('assets written to', OUT)
