#!/usr/bin/env python3
"""Extract the FOXHOLE / Barnes-confrontation assets (load section 2) from re/platoon_darc.adf.

Section 2 = ADF tracks $6f..$9e ($30 tracks) loaded 1:1 to $17000  ->  RAM A == ADF[A - $17000 + $98a00].
The resident/kernel image (font) = ADF tracks 1..17 loaded to $400 and relocated down by 4 bytes
(RAM A == ADF[A - $400 + $1600 + 4]).

Writes into re/foxhole/assets/:
  rooms/pic01..pic10.png   the 10 RLE room pictures (320x152, palette $18fc2); pic10 = Barnes/bunker room
  room_barnes.png          pic10 cropped to the 144 displayed lines
  map.png / map.json       10x12 room-type map ($18ea4), kinds ($18f2e), pictures ($18f1d)
  bobs_foxhole.png/json    Barnes (set $47628 frames 0-2), grenade ($476a8), explosion ($476e0 0-3),
                           Barnes' bullet ($476b0), player bullet ($476a0)  (4x zoom sheet + 1x PNGs)
  bobs/*.png               individual bobs at 1x with transparency
  bobs_all.png             every entry of the bob table $47400..$476ff (sheet)
  end_*.png                the ending text screens rendered with the kernel font and palette $18fe2
  texts.json               all section-2 print strings / message table entries decoded
  foxhole.json             tables: grenade arc, Barnes params, hit windows, bunker window, messages, sfx
  compare_*.png            our renders vs emulator screenshots (if the screenshots exist)
"""
import os, sys, json, struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')
OUT = os.path.join(HERE, 'assets')

adf = open(ADF, 'rb').read()
SEC2_BASE = 0x6f * 0x1600
# ADF track 127 (= RAM $2d000-$2e5ff, inside room picture 5) is CORRUPT in the Darc image (it holds RLE bytes of
# some other picture; the game shows garbage in rooms of type 3/4 on the Darc crack, verified in the emulator).
# The original dump re/platoon_b.adf has the correct track: with it picture 5 decodes to exactly $301a2 (= start
# of picture 6).  We extract both variants.
ADF_B = os.path.join(HERE, '..', 'platoon_b.adf')
adf_fixed = bytearray(adf)
if os.path.exists(ADF_B):
    _b = open(ADF_B, 'rb').read()
    adf_fixed[127 * 0x1600:128 * 0x1600] = _b[127 * 0x1600:128 * 0x1600]
adf_fixed = bytes(adf_fixed)


def s2(addr, n, fixed=False):
    """bytes of section 2 at RAM address addr (fixed=True: with the original track 127)"""
    o = addr - 0x17000 + SEC2_BASE
    return (adf_fixed if fixed else adf)[o:o + n]


def res(addr, n):
    """bytes of the resident/kernel image at RAM address addr (verified against the RAM dump for the font)"""
    o = addr - 0x400 + 0x1600      # (the $12e54 font matches the RAM dump at this offset)
    return adf[o:o + n]


def w(b, i=0):
    return struct.unpack('>H', b[i:i + 2])[0]


def sw(b, i=0):
    return struct.unpack('>h', b[i:i + 2])[0]


def l(b, i=0):
    return struct.unpack('>I', b[i:i + 4])[0]


def palette(addr, src=s2):
    b = src(addr, 32)
    out = []
    for i in range(16):
        v = w(b, 2 * i)
        out.append((((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17))
    return out


PAL_GAME = palette(0x18fc2)      # playfield palette of every jungle room ($17676 -> jt30)
PAL_TEXT = palette(0x18fe2)      # palette of the intro / ending text screens ($176ea -> jt30)
PAL_HUD = palette(0x176be)       # HUD palette set by $17676 (entries 8,9 are animated at run time)


# ------------------------------------------------------------------------------------------------
# room pictures: RLE at $19400 + offs[$18f9a + 4*(n-1)], decoder $17604
def decode_picture(n, fixed=False):
    off = l(s2(0x18f9a + 4 * (n - 1), 4))
    src = 0x19400 + off
    data = s2(src, 0x8000, fixed)
    p = 0
    planes = []
    for plane in range(4):
        esc = data[p]; p += 1
        out = bytearray()
        cnt = 0x17c0            # d3: bytes per plane (40 x 152)
        while True:
            b = data[p]; p += 1
            if b == esc:
                v = data[p]; c = data[p + 1]; p += 2
                c = c if c else 256          # subq.b #1 + dbeq: count 0 = 256
                stop = False
                for _ in range(c):
                    out.append(v); cnt -= 1
                    if cnt == 0:             # dbeq exits on Z of the subq.w #1,d3
                        stop = True; break
                if stop or cnt == 0:
                    break
            else:
                out.append(b); cnt -= 1
                if cnt == 0:
                    break
        planes.append(bytes(out))
    end = src + p
    return planes, src, end


def planes_to_image(planes, width_bytes, height, pal):
    img = Image.new('RGB', (width_bytes * 8, height))
    px = img.load()
    for y in range(height):
        for xb in range(width_bytes):
            bs = [pl[y * width_bytes + xb] for pl in planes]
            for bit in range(8):
                m = 0x80 >> bit
                v = sum(((bs[k] & m) != 0) << k for k in range(4))
                px[xb * 8 + bit, y] = pal[v]
    return img


# ------------------------------------------------------------------------------------------------
# bobs: table at $47400: 8-byte entries {long offset from $47700, word w_words-1, word h-1}
# data at $47700+offset: long header (copy of w-1,h-1), then 5 planar blocks of h rows x w words:
# block0 = mask (blitter A), blocks 1..4 = bitplanes 0..3 (blitter B), cookie-cut D = B | (C & ~A)
def bob(entry_addr):
    e = s2(entry_addr, 8)
    off, wm1, hm1 = l(e), w(e, 4), w(e, 6)
    ww, h = wm1 + 1, hm1 + 1
    a = 0x47700 + off
    hdr = s2(a, 4)
    blk = ww * 2 * h
    body = s2(a + 4, blk * 5)
    mask = body[:blk]
    planes = [body[blk * (k + 1):blk * (k + 2)] for k in range(4)]
    img = Image.new('RGBA', (ww * 16, h), (0, 0, 0, 0))
    px = img.load()
    for y in range(h):
        for xb in range(ww * 2):
            i = y * ww * 2 + xb
            for bit in range(8):
                m = 0x80 >> bit
                if mask[i] & m:
                    v = sum(((planes[k][i] & m) != 0) << k for k in range(4))
                    px[xb * 8 + bit, y] = PAL_GAME[v] + (255,)
    return img, dict(entry=hex(entry_addr), data=hex(a), w=ww * 16, h=h, header=hdr.hex(),
                     header_ok=(l(hdr) == ((wm1 << 16) | hm1)))


def zoom(img, k):
    return img.resize((img.width * k, img.height * k), Image.NEAREST)


# ------------------------------------------------------------------------------------------------
# kernel font + $408 print strings
FONT = res(0x12e54, 64 * 16)


def render_print(strings, pal, slots=(0, 8, 9, 0), pal_low=None, split=144):
    """strings: list of RAM addresses of $408 strings (section 2). Renders a 320x200 bitplane screen."""
    scr = [[0] * 320 for _ in range(200)]
    slots = list(slots)
    ops = []
    for a in strings:
        b = s2(a, 400)
        i = 0
        col, row = b[0], b[1]; i = 2
        while True:
            c = b[i]; i += 1
            if c == 0:
                col, row = b[i], b[i + 1]; i += 2; continue
            if 1 <= c <= 4:
                slots[(c - 1) & 3] = b[i] & 15; ops.append(('slot', (c - 1) & 3, b[i] & 15)); i += 1; continue
            last = False
            if c == 0xff:
                break
            if c >= 0x80:
                c &= 0x7f; last = True
            ops.append(('chr', col, row, chr(c)))
            if c >= 0x20:
                g = FONT[(c - 0x20) * 16:(c - 0x20) * 16 + 16]
                for yy in range(8):
                    word = w(g, 2 * yy)
                    for xx in range(8):
                        v = (word >> (14 - 2 * xx)) & 3
                        Y, X = row * 8 + yy, col * 8 + xx
                        if Y < 200 and X < 320:
                            scr[Y][X] = slots[v]
            col += 1
            if col >= 40:
                col = 0; row += 1
            if last:
                break
    img = Image.new('RGB', (320, 200))
    px = img.load()
    for y in range(200):
        for x in range(320):
            px[x, y] = (pal if (pal_low is None or y < split) else pal_low)[scr[y][x]]
    return img, ops


def decode_string(a):
    b = s2(a, 400)
    col, row = b[0], b[1]
    i = 2
    parts = [{'pos': [col, row]}]
    txt = ''
    while True:
        c = b[i]; i += 1
        if c == 0:
            if txt: parts.append({'text': txt}); txt = ''
            parts.append({'pos': [b[i], b[i + 1]]}); i += 2; continue
        if 1 <= c <= 4:
            if txt: parts.append({'text': txt}); txt = ''
            parts.append({'slot': (c - 1) & 3, 'colour': b[i] & 15}); i += 1; continue
        if c == 0xff:
            break
        if c >= 0x80:
            txt += chr(c & 0x7f); break
        txt += chr(c)
    if txt: parts.append({'text': txt})
    return {'addr': hex(a), 'end': hex(a + i - 1), 'ops': parts}


def main():
    os.makedirs(os.path.join(OUT, 'rooms'), exist_ok=True)
    os.makedirs(os.path.join(OUT, 'bobs'), exist_ok=True)
    info = {}

    # ---- pictures
    pics = []
    for n in range(1, 11):
        planes, src, end = decode_picture(n)
        img = planes_to_image(planes, 40, 152, PAL_GAME)
        img.save(os.path.join(OUT, 'rooms', 'pic%02d.png' % n))
        pics.append({'n': n, 'src': hex(src), 'end': hex(end), 'bytes': end - src})
        img.save(os.path.join(OUT, 'rooms', 'pic%02d.png' % n))
        if n == 10:
            img.crop((0, 0, 320, 144)).save(os.path.join(OUT, 'room_barnes.png'))
        if n == 5:
            img.save(os.path.join(OUT, 'rooms', 'pic05_darc_corrupt.png'))
            planes, src, end = decode_picture(n, fixed=True)
            img = planes_to_image(planes, 40, 152, PAL_GAME)
            img.save(os.path.join(OUT, 'rooms', 'pic05.png'))
            pics[-1]['end_fixed_track127'] = hex(end)
    info['pictures'] = pics

    # ---- map
    m = s2(0x18ea4, 120)
    kinds = s2(0x18f2e, 17)
    picidx = s2(0x18f1d, 17)
    info['map'] = {'width': 10, 'height': 12, 'start_room': 0x69,
                   'types': [list(m[r * 10:r * 10 + 10]) for r in range(12)],
                   'kind_of_type': list(kinds), 'picture_of_type': list(picidx),
                   'barnes_rooms': [i for i in range(120) if m[i] == 0x10],
                   'dir_table_initial': s2(0x18f40, 4).hex(), 'dir_table_reset': s2(0x18f44, 4).hex()}
    cell = 40
    mi = Image.new('RGB', (10 * cell, 12 * cell), (0, 0, 0))
    thumbs = {n: Image.open(os.path.join(OUT, 'rooms', 'pic%02d.png' % n)).resize((cell, int(cell * 152 / 320)))
              for n in range(1, 11)}
    from PIL import ImageDraw
    dr = ImageDraw.Draw(mi)
    for r in range(12):
        for c in range(10):
            t = m[r * 10 + c]
            if t == 0:
                continue
            mi.paste(thumbs[picidx[t]], (c * cell, r * cell + 10))
            col = (255, 64, 64) if t == 0x10 else ((255, 255, 0) if r * 10 + c == 0x69 else (255, 255, 255))
            dr.text((c * cell + 1, r * cell), '%d:%x' % (r * 10 + c, t), fill=col)
    mi = zoom(mi, 2)
    mi.save(os.path.join(OUT, 'map.png'))

    # ---- bobs
    fox = [('barnes_f0', 0x47628), ('barnes_f1', 0x47630), ('barnes_f2', 0x47638),
           ('grenade', 0x476a8), ('expl_f0', 0x476e0), ('expl_f1', 0x476e8), ('expl_f2', 0x476f0),
           ('expl_f3', 0x476f8), ('enemy_bullet', 0x476b0), ('player_bullet', 0x476a0)]
    bobinfo = {}
    imgs = []
    for name, ea in fox:
        img, d = bob(ea)
        img.save(os.path.join(OUT, 'bobs', name + '.png'))
        bobinfo[name] = d
        imgs.append((name, img))
    sheet = Image.new('RGBA', (sum(i.width * 4 + 8 for _, i in imgs), max(i.height * 4 for _, i in imgs)),
                      (40, 40, 40, 255))
    x = 0
    for _, i in imgs:
        z = zoom(i, 4)
        sheet.alpha_composite(z, (x, 0))
        x += z.width + 8
    sheet.save(os.path.join(OUT, 'bobs_foxhole.png'))
    info['bobs'] = bobinfo
    json.dump(bobinfo, open(os.path.join(OUT, 'bobs_foxhole.json'), 'w'), indent=1)

    # whole bob table
    allimgs = []
    for k in range((0x47700 - 0x47400) // 8):
        ea = 0x47400 + 8 * k
        try:
            img, d = bob(ea)
        except Exception:
            continue
        allimgs.append((k, img))
    cols = 12
    cw, ch = 70, 50
    sh = Image.new('RGBA', (cols * cw, ((len(allimgs) + cols - 1) // cols) * ch), (40, 40, 40, 255))
    dr = ImageDraw.Draw(sh)
    for n, (k, img) in enumerate(allimgs):
        X, Y = (n % cols) * cw, (n // cols) * ch
        sh.alpha_composite(img.crop((0, 0, min(img.width, cw), min(img.height, ch - 8))), (X, Y + 8))
        dr.text((X, Y), '%d' % k, fill=(255, 255, 0, 255))
    sh.save(os.path.join(OUT, 'bobs_all.png'))

    # ---- texts
    texts = {}
    tab = []
    for i in range(17):
        p = l(s2(0x189e0 + 4 * i, 4))
        b = s2(p, 60)
        txt = b[2:b.index(0xff, 2)].decode('latin-1')
        tab.append({'n': i, 'addr': hex(p), 'col': b[0], 'row': b[1], 'text': txt})
    texts['message_table_189e0'] = tab
    screens = {'intro_18c6d': [0x18c6d], 'win_18b5f': [0x18b5f], 'napalm_18bb8': [0x18bb8],
               'withdrawn_18c14_unused': [0x18c14], 'destroyed_18ce7': [0x18ce7],
               'second_chance_18d2c': [0x18d2c]}
    texts['print_strings'] = {k: decode_string(v[0]) for k, v in screens.items()}
    json.dump(texts, open(os.path.join(OUT, 'texts.json'), 'w'), indent=1)
    for k, v in screens.items():
        img, ops = render_print(v, PAL_TEXT, pal_low=PAL_HUD)
        img.save(os.path.join(OUT, 'end_%s.png' % k))

    # ---- tables
    arc = [sw(s2(0x18400 + 2 * i, 2)) for i in range(13)]
    y = 0; traj = []
    for e in range(13):
        y += 4 + arc[e]; traj.append(y)
    info['grenade'] = {
        'spawn': 'x = player.x + $0a, y = player.y + $1e, e = 0, frame = 0, set $476a8, handler $1833a',
        'arc_table_18400': arc, 'per_tick_dy': [4 + a for a in arc], 'cumulative_dy': traj,
        'remove_if_y_uge': 0x8c, 'land_tick': 13,
        'hit_window': {'y_min': 0x60, 'y_max_excl': 0x6e, 'x_gt': 0x9b, 'x_le': 0xaa},
        'player_window': 'player.y in [14,27] (y+30+52 in [$60,$6e)), player.x in [$92,$a0]',
        'explosion': 'x -= $0e, y += 4, set $476e0, frames 0..3 one tick each, handler $18706'}
    info['barnes'] = {'slot': 4, 'slot_addr': '0x57e6a', 'hp_init': 0x32, 'hp_per_hit': 10, 'hits_to_kill': 5,
                      'x': 0x96, 'y': 0x69, 'set': '0x47628', 'handler': '0x182b0',
                      'frame_by_player_x': {'<$82': 0, '$82..$9f': 1, '>=$a0': 2},
                      'shot_cooldown': 'rand&15 + $0a ticks (fires when $57f5a < 0)'}
    info['bunker_entry'] = {'requires': 'Barnes slot byte $57e6a == 0', 'x_gt': 0x9e, 'x_le': 0xae,
                            'y_ge': 0x5f}
    json.dump(info, open(os.path.join(OUT, 'foxhole.json'), 'w'), indent=1)
    json.dump(info['map'], open(os.path.join(OUT, 'map.json'), 'w'), indent=1)

    # ---- comparisons with emulator screenshots (made by the notes' recipes)
    comps = [('work/obg/bg.png', 'room', None), ('work/ow/w400.png', 'win', 'win_18b5f'),
             ('work/ot2/n300.png', 'napalm', 'napalm_18bb8'), ('work/ot1/m60.png', 'destroyed', 'destroyed_18ce7'),
             ('work/ot4/d200.png', 'second_chance', 'second_chance_18d2c')]
    res_ = {}
    for shot, name, scr in comps:
        p = os.path.join(HERE, shot)
        if not os.path.exists(p):
            continue
        s = Image.open(p).convert('RGB')
        if scr is None:
            ours = Image.open(os.path.join(OUT, 'room_barnes.png')).convert('RGB')
            crop = s.crop((17, 36, 17 + 320, 36 + 144))
        else:
            ours = Image.open(os.path.join(OUT, 'end_%s.png' % scr)).convert('RGB')
            crop = s.crop((17, 36, 17 + 320, 36 + 200))
        a, b = ours.load(), crop.load()
        hh = ours.height
        diff = sum(1 for yy in range(hh) for xx in range(320) if a[xx, yy] != b[xx, yy])
        res_[name] = diff
        both = Image.new('RGB', (640, hh)); both.paste(ours, (0, 0)); both.paste(crop, (320, 0))
        both.save(os.path.join(OUT, 'compare_%s.png' % name))
    print('picture spans:', [(p['n'], p['src'], p['end']) for p in pics])
    print('pixel differences vs emulator (room: 320x144 window; text screens: full 320x200 bitmap):', res_)


if __name__ == '__main__':
    main()
