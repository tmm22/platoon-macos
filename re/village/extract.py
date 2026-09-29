#!/usr/bin/env python3
"""Village asset extractor for Platoon (Amiga, Ocean 1988) -- re/village module.

Reads everything from the Darc ADF (re/platoon_darc.adf).  Section 0 ("THE JUNGLE & VILLAGE
SECTIONS") is stored uncompressed on tracks $15..$4c and loaded 1:1 to RAM $17000..$63fff, so
    RAM address A  <->  ADF offset (A - $17000) + $15*$1600.

Outputs (re/village/assets/):
  village_level0.png        level 0 (outdoor village street), map columns $2a..$59 (48 tiles)
  village_level5.png        level 5 (hut interiors "overlay" level), same columns
  village_both.png          the two above stacked, with door columns / hut spans / item hot-spots marked
  hut<N>_interior.png       per hut (N=0..5): level-5 render of the hut span (+1 tile margin) with the
                            item search ranges drawn as coloured bars (player world position scale)
  village_frames.png        village-relevant animation frames (villager walk, hut VC, dead VC, dying,
                            player entering/leaving a hut, searching) and the trap-door prop bob $3b
  bridge_tiles.png          bridge tiles $8c,$8d (intact) and $95,$96 (blown) + the level-1 bridge area
  village.json              hut door table, hut spans, hut occupants, the 20-entry item table decoded
                            (with world positions), trap-door position, message texts, palettes,
                            constants used by the village code
  (optional) --validate SHOT.png COL FINE CB0  compare a render of level 0/5 with an emulator
                            screenshot (see NOTES.md section d.7)
"""
import os, sys, json, struct
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')
OUT = os.path.join(HERE, 'assets')

SEC_BASE, SEC_ADF, SEC_LEN = 0x17000, 0x15 * 0x1600, 0x38 * 0x1600

# ---- addresses (RAM) -------------------------------------------------------------------------
MAP_BASE = 0x1b000          # 6 levels x 3 rows x 90 bytes ($10e per level, $5a per row)
TILE_GFX = 0x1c000          # 152 tiles x $600: 4 planes x (48 rows x 8 bytes), plane-sequential
TILE_ATTR = 0x5dc00         # 152 tiles x $30: 6 rows x 8 attribute cells (8x8 px each)
PAL_PLAYFIELD = 0x19ff8     # 16 words; word 6 ($1a004) is patched: $0ca2 on level 0/5, $000d else
BOB_DIR = 0x55000           # 8 bytes per bob: long offset (from $55400), long (W-1)<<16|(H-1)
BOB_DATA = 0x55400
BOB_OFS = 0x1a536           # long per bob: (dx<<16 | dy) added to the frame position
FRAME_TAB = 0x1a1c6         # long per anim frame (0..$7f, +$40 = facing left): ptr to bob list, $ff end
MSG_TAB = 0x1a6de           # 25 long pointers: [x, y, text..., $ff]
DOOR_TAB = 0x1aaf4          # 6 bytes: hut door tile columns, index d1 = 5..0
ITEM_TAB = 0x1aafa          # 20 x 4 bytes: lo, hi, msg, msg_after
JUMP_ARC = 0x1a194


def load_section():
    adf = open(ADF, 'rb').read()
    mem = bytearray(0x80000)
    mem[SEC_BASE:SEC_BASE + SEC_LEN] = adf[SEC_ADF:SEC_ADF + SEC_LEN]
    return mem


M = load_section()


def w(a): return (M[a] << 8) | M[a + 1]
def l(a): return struct.unpack('>I', bytes(M[a:a + 4]))[0]
def sl16(v): return v - 0x10000 if v & 0x8000 else v


def amiga_rgb(c): return (((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17)


def palette(level):
    p = [w(PAL_PLAYFIELD + 2 * i) for i in range(16)]
    p[6] = 0x0ca2 if level in (0, 5) else 0x000d          # level_enter $17a48
    return p


def pal_array(level):
    return np.array([amiga_rgb(c) for c in palette(level)], np.uint8)


# ---- tiles --------------------------------------------------------------------------------------
_tile_cache = {}


def tile(t):
    """64x48 array of colour indices for background tile t."""
    if t in _tile_cache:
        return _tile_cache[t]
    base = TILE_GFX + t * 0x600
    img = np.zeros((48, 64), np.uint8)
    for p in range(4):
        raw = np.frombuffer(bytes(M[base + p * 0x180: base + (p + 1) * 0x180]), np.uint8).reshape(48, 8)
        bits = np.unpackbits(raw, axis=1)                   # 48 x 64, msb first
        img |= (bits.astype(np.uint8) << p)
    _tile_cache[t] = img
    return img


def tile_attr(t):
    return bytes(M[TILE_ATTR + t * 0x30: TILE_ATTR + t * 0x30 + 0x30])


def solid(v):                                              # solid_at $19ed2
    return v == 0xb0 or v == 0xda or 0xc0 <= v <= 0xd0


def map_byte(level, row, col):
    return M[MAP_BASE + level * 0x10e + row * 0x5a + col]


def render_level(level, c0, c1):
    img = np.zeros((144, 64 * (c1 - c0)), np.uint8)
    for r in range(3):
        for c in range(c0, c1):
            img[r * 48:(r + 1) * 48, (c - c0) * 64:(c - c0 + 1) * 64] = tile(map_byte(level, r, c))
    return img


# ---- bobs / frames ------------------------------------------------------------------------------
def bob(i):
    """returns (mask HxW*16 bool, colour index array) for bob i. Layout: header long
    (W-1)<<16|(H-1), then 5 blocks of H rows x W words: block0 = mask, blocks 1..4 = planes 0..3."""
    a = BOB_DATA + l(BOB_DIR + 8 * i)
    W = w(a) + 1
    H = w(a + 2) + 1
    d = a + 4
    blocks = []
    for k in range(5):
        raw = np.frombuffer(bytes(M[d + k * H * W * 2: d + (k + 1) * H * W * 2]), np.uint8).reshape(H, W * 2)
        blocks.append(np.unpackbits(raw, axis=1).astype(np.uint8))
    col = np.zeros((H, W * 16), np.uint8)
    for p in range(4):
        col |= blocks[1 + p] << p
    return blocks[0].astype(bool), col


def bob_ofs(i):
    v = l(BOB_OFS + 4 * i)
    return sl16(v >> 16), sl16(v & 0xffff)


def frame_bobs(f):
    p = l(FRAME_TAB + 4 * f)
    out = []
    while M[p] != 0xff and len(out) < 16:
        out.append(M[p])
        p += 1
    return out


def render_frame(f, level=0, bg=None):
    """compose animation frame f (0..$7f) the way draw_frame $191d4 does (all bobs at the same
    position, each shifted by its $1a536 offset). Returns RGBA image and the origin offset."""
    bl = frame_bobs(f)
    parts = []
    for b in bl:
        mk, col = bob(b)
        dx, dy = bob_ofs(b)
        parts.append((dx, dy, mk, col))
    if not parts:
        return None, (0, 0)
    x0 = min(p[0] for p in parts); y0 = min(p[1] for p in parts)
    x1 = max(p[0] + p[2].shape[1] for p in parts); y1 = max(p[1] + p[2].shape[0] for p in parts)
    pal = pal_array(level)
    img = np.zeros((y1 - y0, x1 - x0, 4), np.uint8)
    if bg is not None:
        img[:, :] = bg
    for dx, dy, mk, col in parts:
        sub = img[dy - y0: dy - y0 + mk.shape[0], dx - x0: dx - x0 + mk.shape[1]]
        sub[mk, :3] = pal[col[mk]]
        sub[mk, 3] = 255
    return Image.fromarray(img), (x0, y0)


def render_bob(b, level=0):
    mk, col = bob(b)
    pal = pal_array(level)
    img = np.zeros(mk.shape + (4,), np.uint8)
    img[mk, :3] = pal[col[mk]]
    img[mk, 3] = 255
    return Image.fromarray(img)


# ---- messages / tables --------------------------------------------------------------------------
def message(n):
    p = l(MSG_TAB + 4 * n)
    x, y = M[p], M[p + 1]
    s = bytearray()
    q = p + 2
    while M[q] != 0xff:
        s.append(M[q]); q += 1
    return {'n': n, 'addr': '%05x' % p, 'x_char': x, 'y_row': y, 'text': s.decode('latin-1')}


DOOR_COLS = [M[DOOR_TAB + i] for i in range(6)]            # $4d,$49,$42,$3c,$37,$31
HUT_OF_DOOR = {c: 5 - i for i, c in enumerate(DOOR_COLS)}   # d1 of the dbeq loop = $60c40


def door_c30(col):
    """$60c30 value when standing in the door with $60c34 == 0: T = col-3 -> T*8 + $1c."""
    return (col - 3) * 8 + 0x1c


def hut_spans():
    """hut interior spans from the level-5 wall tiles in tile row 1 (left wall $70/$71, right $6f)."""
    spans = []
    row1 = [map_byte(5, 1, c) for c in range(90)]
    left = [c for c in range(90) if row1[c] in (0x70, 0x71)]
    right = [c for c in range(90) if row1[c] == 0x6f]
    for a, b in zip(left, right):
        spans.append((a, b))
    return spans


def items():
    out = []
    msgs = {n: message(n)['text'] for n in range(25)}
    for i in range(20):
        a = ITEM_TAB + 4 * i
        lo, hi, m1, m2 = M[a], M[a + 1], M[a + 2], M[a + 3]
        # hut_search: d0.b = ($60c30 - $18f); match iff lo <= d0 <= hi (unsigned bytes) and d0 != $ff.
        # $60c30 is always even, so d0 is always odd: only odd values inside [lo,hi] can ever match.
        reach = [d for d in range(lo, hi + 1) if d & 1 and d != 0xff]
        c30s = [0x18f + d for d in reach]
        hut = None
        for h, (a0, b0) in enumerate(hut_spans()):
            # player tile column for a $60c30 value (as calc_player_pos with $60c34 in 0..4): (c30-$1c)/8+3
            if c30s and a0 <= ((c30s[0] - 0x1c) >> 3) + 3 <= b0:
                hut = h
        special = {0x10: 'TORCH spot: first search sets torch ($60cbd), morale+$200, +500, msg 2; '
                         'later searches give msg 3 (A POT OF RICE)',
                   0x0f: 'BOOBY TRAP: explosion, man.hits:=3, player_hit (-> KILLED IN ACTION), '
                         'entry.msg := entry.msg_after (one-shot), msg $f',
                   0x17: 'MAP spot: only if hut-2 VC is dead ($60c70) and map not yet taken ($24(a6)); '
                         'sets $24(a6), HUD icon, morale+$200, +500, msg 8; otherwise msg 7 (A TABLE)'}
        eff = {0x10: msgs[2] + ' (then: ' + msgs[3] + ')', 0x17: msgs[8] + ' (else: ' + msgs[7] + ')'}
        out.append({'index': i, 'addr': '%05x' % a, 'lo': lo, 'hi': hi, 'msg': m1, 'msg_after': m2,
                    'text': eff.get(m1, msgs.get(m1)), 'text_after': eff.get(m2, msgs.get(m2)),
                    'reachable_d0': reach, 'reachable_c30': ['%03x' % c for c in c30s],
                    'hut': hut, 'unreachable': not reach, 'special': special.get(m1)})
    return out


def world_px(c30):
    """world x (pixels from level column 0) of the player's visual centre for a given $60c30.
    Verified: in a screenshot at $60c30=$23c the visible player pixels span world x
    c30*8-11 .. c30*8+9 (hut4, level 5)."""
    return c30 * 8


# ---- outputs ----------------------------------------------------------------------------------
C0, C1 = 0x2a, 0x5a


def save_rgb(arr, level, path, scale=1):
    im = Image.fromarray(pal_array(level)[arr])
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    l0 = render_level(0, C0, C1)
    l5 = render_level(5, C0, C1)
    im0 = save_rgb(l0, 0, os.path.join(OUT, 'village_level0.png'))
    im5 = save_rgb(l5, 5, os.path.join(OUT, 'village_level5.png'))
    # annotated combo
    both = Image.new('RGB', (im0.width, 144 * 2 + 60), (0, 0, 0))
    both.paste(im0, (0, 0)); both.paste(im5, (0, 144 + 30))
    d = ImageDraw.Draw(both)
    for c in range(C0, C1):
        d.text(((c - C0) * 64 + 2, 146), '%02x' % c, fill=(200, 200, 200))
    for col in DOOR_COLS:
        x = (col - C0) * 64
        d.rectangle([x, 0, x + 63, 143], outline=(255, 255, 0))
        d.text((x + 4, 4), 'door hut%d' % HUT_OF_DOOR[col], fill=(255, 255, 0))
    for h, (a, b) in enumerate(hut_spans()):
        d.rectangle([(a - C0) * 64, 174, (b - C0) * 64 + 63, 174 + 143], outline=(0, 255, 255))
    colors = {0x0f: (255, 0, 0), 0x10: (255, 255, 255), 0x17: (0, 255, 0)}
    for it in items():
        for c30 in it['reachable_c30']:
            x = world_px(int(c30, 16)) - C0 * 64
            col = colors.get(it['msg'], (255, 128, 0))
            d.line([x, 174 + 110, x, 174 + 143], fill=col, width=3)
            d.text((x - 6, 174 + 144 + 2), '%d' % it['index'], fill=col)
    tx = world_px(0x1c4) - C0 * 64
    d.rectangle([tx - 8, 174 + 100, tx + 8, 174 + 108], outline=(255, 0, 255))
    d.text((tx - 20, 174 + 90), 'TRAPDOOR', fill=(255, 0, 255))
    both.save(os.path.join(OUT, 'village_both.png'))

    # per hut interior
    for h, (a, b) in enumerate(hut_spans()):
        ca, cb = a - 1, b + 2
        arr = render_level(5, ca, cb)
        im = save_rgb(arr, 5, os.path.join(OUT, 'hut%d_interior.png' % h))
        im2 = im.resize((im.width * 2, (144 + 24) * 2), Image.NEAREST)
        canvas = Image.new('RGB', (im.width * 2, (144 + 40) * 2), (0, 0, 0))
        canvas.paste(im.resize((im.width * 2, 288), Image.NEAREST), (0, 0))
        d = ImageDraw.Draw(canvas)
        door = DOOR_COLS[5 - h]
        x = (door - ca) * 64 * 2
        d.rectangle([x, 0, x + 127, 287], outline=(255, 255, 0))
        d.text((x + 4, 4), 'door $%02x (enter/leave here, $60c30=$%03x)' % (door, door_c30(door)), fill=(255, 255, 0))
        yy = 292
        for it in items():
            if it['hut'] != h:
                continue
            for c30 in it['reachable_c30']:
                px = (world_px(int(c30, 16)) - ca * 64) * 2
                col = colors.get(it['msg'], (255, 128, 0))
                d.line([px, 200, px, 287], fill=col, width=3)
            if it['reachable_c30']:
                px = (world_px(int(it['reachable_c30'][0], 16)) - ca * 64) * 2
                d.text((max(0, px - 30), yy), '#%d %s' % (it['index'], it['text'] or ''), fill=colors.get(it['msg'], (255, 128, 0)))
                yy += 12
        if h == 1:
            px = (world_px(0x1c4) - ca * 64) * 2
            d.rectangle([px - 16, 250, px + 16, 262], outline=(255, 0, 255))
            d.text((px - 30, yy), 'TRAP DOOR ($60c24=$35,$60c34=0, facing right)', fill=(255, 0, 255))
        canvas.save(os.path.join(OUT, 'hut%d_interior_annotated.png' % h))

    # frames sheet
    frames = [('villager walk', list(range(0x23, 0x2b))), ('villager walk (left)', list(range(0x63, 0x6b))),
              ('hut VC aiming right/left', [0x34, 0x74]), ('dying / dead', [0x1f, 0x20, 0x33, 0x5f, 0x60, 0x73]),
              ('player enter hut (back view)', [0x11, 0x12, 0x13, 0x14]),
              ('player leave hut (front view)', [0x0d, 0x0e, 0x0f, 0x10]),
              ('player hit', [0x31, 0x32, 0x33]), ('VC walk (for comparison)', list(range(0x15, 0x1d)))]
    sheet = Image.new('RGBA', (8 * 56 + 200, len(frames) * 64 + 80), (40, 40, 40, 255))
    d = ImageDraw.Draw(sheet)
    fj = {}
    for r, (name, fl) in enumerate(frames):
        d.text((4, r * 64 + 4), name, fill=(255, 255, 255))
        for k, f in enumerate(fl):
            im, (ox, oy) = render_frame(f, level=0)
            fj['%02x' % f] = {'bobs': ['%02x' % b for b in frame_bobs(f)], 'origin': [ox, oy]}
            if im is None:
                continue
            sheet.alpha_composite(im, (200 + k * 56 + 4, r * 64 + 60 - im.height if im.height < 60 else r * 64))
            d.text((200 + k * 56 + 4, r * 64 + 52), '%02x' % f, fill=(255, 255, 0))
    # trap door bob
    tb = render_bob(0x3b, 5)
    r = len(frames)
    d.text((4, r * 64 + 4), 'trap-door prop bob $3b', fill=(255, 255, 255))
    sheet.alpha_composite(tb.resize((tb.width * 2, tb.height * 2), Image.NEAREST), (204, r * 64 + 8))
    sheet.save(os.path.join(OUT, 'village_frames.png'))

    # bridge tiles
    bt = Image.new('RGB', (4 * 70, 60), (0, 0, 0))
    for k, t in enumerate([0x8c, 0x8d, 0x95, 0x96]):
        bt.paste(Image.fromarray(pal_array(1)[tile(t)]), (k * 70, 0))
    bt.save(os.path.join(OUT, 'bridge_tiles.png'))
    br = render_level(1, 0x42, 0x4f)
    save_rgb(br, 1, os.path.join(OUT, 'bridge_area_level1_intact.png'))
    arr = br.copy()
    arr[96:144, (0x47 - 0x42) * 64:(0x48 - 0x42) * 64] = tile(0x95)
    arr[96:144, (0x48 - 0x42) * 64:(0x49 - 0x42) * 64] = tile(0x96)
    save_rgb(arr, 1, os.path.join(OUT, 'bridge_area_level1_blown.png'))

    # json
    data = {
        'source': 're/platoon_darc.adf section 0 (RAM $17000 = ADF $1ce00)',
        'door_table_1aaf4': ['%02x' % c for c in DOOR_COLS],
        'huts': [{'hut': h, 'door_col': '%02x' % DOOR_COLS[5 - h], 'door_c30': '%03x' % door_c30(DOOR_COLS[5 - h]),
                  'span_cols': ['%02x' % hut_spans()[h][0], '%02x' % hut_spans()[h][1]],
                  'occupant': {0: None, 1: 'trap-door prop bob $3b at x=$d0-($60c30-$1bc)*8, y=$3d; enemy state 4 w/o frame',
                               2: 'VC (enemy state 4, facing left, frame $34 -> fires every $19 ticks, first after $f; '
                                  'dead: frame $33 and $60c70=1) at x=$d0-($60c30-$1e4)*8, y=$3d'}.get(h)}
                 for h in range(6)],
        'trapdoor': {'hut': 1, 'col_60c24': '35', 'fine_60c34': 0, 'c30': '1c4', 'requires': 'facing right, $60c32==0'},
        'items_1aafa': items(),
        'messages': [message(n) for n in range(25)],
        'palette_level0_5': ['%04x' % c for c in palette(0)],
        'palette_jungle': ['%04x' % c for c in palette(1)],
        'village_level0_map': [[('%02x' % map_byte(0, r, c)) for c in range(90)] for r in range(3)],
        'hut_level5_map': [[('%02x' % map_byte(5, r, c)) for c in range(90)] for r in range(3)],
        'solid_cells_level0_row1': {('%02x' % c): [i for i, v in enumerate(tile_attr(map_byte(0, 1, c))) if solid(v)]
                                    for c in range(0x2d, 0x5a) if any(solid(v) for v in tile_attr(map_byte(0, 1, c)))},
        'solid_cells_level5_row1': {('%02x' % c): [i for i, v in enumerate(tile_attr(map_byte(5, 1, c))) if solid(v)]
                                    for c in range(0x2d, 0x5a) if any(solid(v) for v in tile_attr(map_byte(5, 1, c)))},
        'frames': fj,
        'jump_arc_1a194': [w(JUMP_ARC + 2 * i) for i in range(17)],
        'score_bcd': {'1a6ce(+300)': bytes(M[0x1a6ce:0x1a6d2]).hex(), '1a6d2(+500)': bytes(M[0x1a6d2:0x1a6d6]).hex(),
                      '1a6d6(+10000)': bytes(M[0x1a6d6:0x1a6da]).hex()},
        'start_pos_1a6da': '%08x' % l(0x1a6da),
    }
    json.dump(data, open(os.path.join(OUT, 'village.json'), 'w'), indent=1)
    print('wrote', sorted(os.listdir(OUT)))


def validate(shot, level, col, fine, cb0):
    """Render level `level` the way the screen shows it at scroll ($60c24=col,$60c34=fine,
    $60cb0=cb0) and find the best alignment inside the emulator screenshot; prints the match ratio
    of the play area (excluding the player sprite columns)."""
    sc = np.array(Image.open(shot).convert('RGB')).astype(int)
    ref = render_level(level, col, col + 7)
    rgb = pal_array(level)[ref].astype(int)
    best = None
    for dy in range(0, 60):
        for dx in range(-64 - 16, 64 + 16):
            # screen x (canvas) of world pixel col*64 is dx; compare canvas x 40..330
            xs = np.arange(40, 330)
            wx = xs - dx
            ok = (wx >= 0) & (wx < rgb.shape[1])
            xs = xs[ok]; wx = wx[ok]
            keep = (xs < 160) | (xs > 215)
            xs = xs[keep]; wx = wx[keep]
            a = sc[dy:dy + 100, xs]
            b = rgb[0:100, wx]
            if a.shape != b.shape:
                continue
            m = (np.abs(a - b).sum(axis=2) == 0).mean()
            if best is None or m > best[0]:
                best = (m, dx, dy)
    print('best match %.4f at canvas dx=%d dy=%d (world x of col %02x at canvas x=%d)' % (best[0], best[1], best[2], col, best[1]))
    return best


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--validate':
        validate(sys.argv[2], int(sys.argv[3]), int(sys.argv[4], 16), int(sys.argv[5]), int(sys.argv[6]))
    else:
        main()
