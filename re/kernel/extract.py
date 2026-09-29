#!/usr/bin/env python3
"""Extract the kernel/resident/boot-loader assets of Platoon (Amiga) from re/platoon_darc.adf.

Writes into re/kernel/assets/:
  font_12e54.png / .json      64-glyph 8x8 2bpp text font used by $404/$408 (chars $20-$5f)
  monfont_2094.png            96-glyph 8x8 1bpp monitor font (resident debug monitor)
  hud_cells.png               the 8x8 HUD bar cells ($13254..$132f3)
  hud_icons.png               the 24x24 HUD icons (star x4, $24/$28/$2c icons, wound, music/fx on/off)
  logo.png                    RLE logo $14074 (320x48, 4 planes) with the logo palette $1137e (runtime-reset values)
  logo_cycle.png              same, shown at the 4 phases of the logo colour cycle
  attract.png                 RLE attract picture $14ec4 (160x151) with palette $113fe
  loading_picture.png         boot loading picture (tracks 18-20, ByteRun1) with palette $766d2
  palettes.json               all kernel palettes / text colour ramps
  strings.json                every kernel text string decoded (position, colour codes, text)
  copper.json                 the three copper list fragments
  hiscore_original.json       hiscore table (track 77) from re/platoon_b.adf (Darc track 77 is blank!)
  cheats.json                 cheat key sequences
  tables.json                 misc tables (row offsets, bar masks, section loader table)
The script also self-checks the kernel image against the RAM dump re/dumps/ram_section0.bin.
"""
import os, sys, json, struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
ADF = os.path.join(ROOT, 're', 'platoon_darc.adf')
ADF_B = os.path.join(ROOT, 're', 'platoon_b.adf')
OUT = os.path.join(HERE, 'assets')
os.makedirs(OUT, exist_ok=True)
TRK = 0x1600

adf = open(ADF, 'rb').read()

# ---------------------------------------------------------------- memory image as the game builds it
mem = bytearray(0x80000)
# bootblock (crack) loads $2c00 bytes from ADF $70c00 to $76000
mem[0x76000:0x76000 + 0x2c00] = adf[0x70c00:0x70c00 + 0x2c00]
# boot loader $7613a loads tracks 1..17 ($11 tracks) to $400
mem[0x400:0x400 + 17 * TRK] = adf[TRK:TRK + 17 * TRK]
# $253c relocator: copies $84d longs from $404 to $400 (resident $404-$2537 -> $400-$2533)
mem[0x400:0x400 + 0x84d * 4] = mem[0x404:0x404 + 0x84d * 4]
# kernel init at $10484 resets logo colours 0,1 -> 0 and 6 -> $fff
struct.pack_into('>H', mem, 0x1137e, 0); struct.pack_into('>H', mem, 0x11380, 0); struct.pack_into('>H', mem, 0x1138a, 0xfff)


def w(a): return struct.unpack('>H', mem[a:a + 2])[0]
def l(a): return struct.unpack('>I', mem[a:a + 4])[0]
def rgb(c): return ((c >> 8 & 15) * 17, (c >> 4 & 15) * 17, (c & 15) * 17)
def pal(a, n=16): return [w(a + 2 * i) for i in range(n)]


def selfcheck():
    p = os.path.join(ROOT, 're', 'dumps', 'ram_section0.bin')
    if not os.path.exists(p): return
    d = open(p, 'rb').read()
    for lo, hi in [(0xf800, 0x10dbe), (0x10dc2, 0x11100), (0x12e54, 0x14074), (0x14074, 0x16a6c)]:
        bad = sum(1 for i in range(lo, hi) if d[i] != mem[i])
        print('selfcheck %05x-%05x mismatches vs ram_section0: %d' % (lo, hi, bad))


# ---------------------------------------------------------------- fonts
def font_2bpp():
    """$12e54: 64 glyphs * 16 bytes: 8 rows, one big-endian word per row, 2 bits per pixel, MSB pair = leftmost."""
    base = 0x12e54
    greys = [(0, 0, 0), (255, 255, 255), (255, 80, 80), (80, 160, 255)]
    im = Image.new('RGB', (16 * 9, 4 * 9), (40, 40, 40))
    glyphs = {}
    for g in range(64):
        rows = []
        for y in range(8):
            v = w(base + g * 16 + y * 2)
            row = [(v >> (14 - 2 * x)) & 3 for x in range(8)]
            rows.append(''.join(str(c) for c in row))
            for x in range(8):
                im.putpixel(((g % 16) * 9 + x, (g // 16) * 9 + y), greys[row[x]])
        glyphs['%02x' % (g + 0x20)] = rows
    im.resize((im.width * 4, im.height * 4), Image.NEAREST).save(os.path.join(OUT, 'font_12e54.png'))
    json.dump({'base': '0x12e54', 'first_char': '0x20', 'count': 64, 'format': '8 rows x 16-bit word, 2bpp, pixel value v -> colour slot v (set by print control codes 1..4)',
               'glyphs': glyphs}, open(os.path.join(OUT, 'font_12e54.json'), 'w'), indent=1)


def font_mon():
    base = 0x2094
    im = Image.new('RGB', (16 * 9, 6 * 9), (40, 40, 40))
    for g in range(96):
        for y in range(8):
            b = mem[base + g * 8 + y]
            for x in range(8):
                im.putpixel(((g % 16) * 9 + x, (g // 16) * 9 + y), (255, 255, 255) if b >> (7 - x) & 1 else (0, 0, 0))
    im.resize((im.width * 3, im.height * 3), Image.NEAREST).save(os.path.join(OUT, 'monfont_2094.png'))


# ---------------------------------------------------------------- HUD graphics
def hud_palette():
    """HUD palette of section 0 ($1a018 in section data, installed by jt28/jt31). Falls back to a default."""
    p = os.path.join(ROOT, 're', 'dumps', 'ram_section0.bin')
    if os.path.exists(p):
        d = open(p, 'rb').read()
        return [struct.unpack('>H', d[0x1a018 + 2 * i:0x1a01a + 2 * i])[0] for i in range(16)]
    return pal(0x11666)


def cell(a, P, img, ox, oy):
    """8x8 cell, 32 bytes: for each line: plane0,plane1,plane2,plane3 bytes."""
    for y in range(8):
        pb = mem[a + 4 * y:a + 4 * y + 4]
        for x in range(8):
            c = sum(((pb[p] >> (7 - x)) & 1) << p for p in range(4))
            img.putpixel((ox + x, oy + y), rgb(P[c]))


def hud():
    P = hud_palette()
    cells = [(0x13254, 'heart (morale bar)'), (0x13274, 'bullet (ammo bar, man+2)'), (0x13294, 'grenade (top bar, man+0)'),
             (0x132b4, 'small wound mark (used by sections via $f884+$60)'), (0x132d4, 'alt top-bar cell when $54(a6)!=0')]
    im = Image.new('RGB', (len(cells) * 10, 8), (60, 60, 60))
    for i, (a, n) in enumerate(cells): cell(a, P, im, i * 10, 0)
    im.resize((im.width * 6, im.height * 6), Image.NEAREST).save(os.path.join(OUT, 'hud_cells.png'))
    icons = [(0x132f4, 'star frame 0 ($26!=0, $2a&3==0)'), (0x13414, 'star frame 1'), (0x13534, 'star frame 2'), (0x13654, 'star frame 3'),
             (0x13774, 'icon $24(a6) at $797d8'), (0x13894, 'icon $28(a6) at $797dc'), (0x139b4, 'wound icon (man+4 count) at $797c0+4k'),
             (0x13ad4, 'icon $2c(a6) at $797d4'), (0x13bf4, 'music ON'), (0x13d14, 'fx ON'), (0x13e34, 'music OFF'), (0x13f54, 'fx OFF')]
    im = Image.new('RGB', (len(icons) * 28, 24), (60, 60, 60))
    for i, (a, n) in enumerate(icons):
        for k in range(9):  # 3x3 cells, row-major
            cell(a + 32 * k, P, im, i * 28 + (k % 3) * 8, (k // 3) * 8)
    im.resize((im.width * 4, im.height * 4), Image.NEAREST).save(os.path.join(OUT, 'hud_icons.png'))
    return {'palette_used': ['%03x' % c for c in P], 'cells': {'%05x' % a: n for a, n in cells}, 'icons': {'%05x' % a: n for a, n in icons}}


# ---------------------------------------------------------------- RLE pictures
def rle_kernel(a):
    """$102d2: word N = bytes per plane; then 4 planes: byte ESC, stream: b!=ESC literal; ESC,value,count (count 0 = 256)."""
    n = w(a); p = a + 2; planes = []
    for _ in range(4):
        esc = mem[p]; p += 1; out = bytearray()
        while len(out) < n:
            b = mem[p]; p += 1
            if b != esc: out.append(b)
            else:
                v, c = mem[p], mem[p + 1]; p += 2
                out += bytes([v]) * (c if c else 256)
        planes.append(bytes(out[:n]))
    return n, planes, p


def planar(planes, wbytes, h, P, img=None, ox=0, oy=0):
    if img is None: img = Image.new('RGB', (wbytes * 8, h))
    for y in range(h):
        for x in range(wbytes * 8):
            c = sum(((planes[p][y * wbytes + x // 8] >> (7 - x % 8)) & 1) << p for p in range(len(planes)))
            img.putpixel((ox + x, oy + y), rgb(P[c]))
    return img


def pictures():
    info = {}
    n, pl, end = rle_kernel(0x14074)
    P = pal(0x1137e)
    planar(pl, 40, 48, P).save(os.path.join(OUT, 'logo.png'))
    # logo colour cycle phases (c0,c1 += $111 / c6 -= $111 per step, 15 steps)
    sheet = Image.new('RGB', (320, 4 * 50))
    for i, k in enumerate([0, 5, 10, 15]):
        Q = list(P); Q[0] = 0x111 * k; Q[1] = 0x111 * k; Q[6] = 0xfff - 0x111 * k
        planar(pl, 40, 48, Q, sheet, 0, i * 50)
    sheet.save(os.path.join(OUT, 'logo_cycle.png'))
    info['logo'] = {'addr': '0x14074', 'bytes_per_plane': n, 'end': hex(end), 'w': 320, 'h': 48}
    n, pl, end = rle_kernel(0x14ec4)
    planar(pl, 20, 151, pal(0x113fe)).save(os.path.join(OUT, 'attract.png'))
    info['attract'] = {'addr': '0x14ec4', 'bytes_per_plane': n, 'end': hex(end), 'w': 160, 'h': 151, 'blit_dest': '0x7878a (buffer $78000 line 48, x=80)'}
    # loading picture: tracks 18..20 loaded to $70000; ByteRun1 body at $70022 -> 200 rows, 4 planes interleaved per row
    src = adf[18 * TRK:21 * TRK]
    p = 0x22; rows = []
    buf = bytearray()
    total = 200 * 4 * 40
    while len(buf) < total:
        b = src[p]; p += 1
        if b < 0x80:
            buf += src[p:p + b + 1]; p += b + 1
        elif b == 0x80:
            continue
        else:
            cnt = (256 - b) & 0x7f
            buf += bytes([src[p]]) * (cnt + 1); p += 1
    planes = [bytearray(8000) for _ in range(4)]
    for y in range(200):
        for pl_ in range(4):
            planes[pl_][y * 40:(y + 1) * 40] = buf[(y * 4 + pl_) * 40:(y * 4 + pl_ + 1) * 40]
    Pl = pal(0x766d2)
    planar(planes, 40, 200, Pl).save(os.path.join(OUT, 'loading_picture.png'))
    hdr_pal = [struct.unpack('>H', src[2 + 2 * i:4 + 2 * i])[0] for i in range(16)]
    info['loading_picture'] = {'tracks': '18-20 -> $70000', 'body_offset': '0x22', 'encoded_bytes_used': p - 0x22, 'w': 320, 'h': 200,
                               'palette_used($766d2)': ['%03x' % c for c in Pl], 'file_header_word0': '%04x' % struct.unpack('>H', src[0:2])[0],
                               'file_header_palette(unused)': ['%03x' % c for c in hdr_pal]}
    return info


# ---------------------------------------------------------------- strings
def decode_print_string(a, maxlen=400):
    """Format of $408 strings: [col,row] then bytes: 0 -> new [col,row]; 1..4 -> colour slot (code-1) = next byte;
    $05-$7f char; $ff end; other >=$80 -> char (b&$7f) then end.  'ops' keeps the exact order of colour changes/text."""
    out = []; p = a
    cur = {'col': mem[p], 'row': mem[p + 1], 'ops': [], 'text': ''}; p += 2
    def addtext(ch):
        cur['text'] += ch
        if cur['ops'] and cur['ops'][-1][0] == 'text': cur['ops'][-1][1] += ch
        else: cur['ops'].append(['text', ch])
    while p < a + maxlen:
        b = mem[p]; p += 1
        if b == 0:
            out.append(cur); cur = {'col': mem[p], 'row': mem[p + 1], 'ops': [], 'text': ''}; p += 2
        elif b < 5:
            cur['ops'].append(['slot%d' % (b - 1), mem[p]]); p += 1
        elif b < 0x80:
            addtext(chr(b))
        else:
            if b != 0xff: addtext(chr(b & 0x7f))
            break
    out.append(cur)
    return {'addr': hex(a), 'end': hex(p), 'parts': out}


def strings():
    S = {}
    named = {0x11172: 'LOADING...', 0x11196: 'section 0 name', 0x111b7: 'section 1 name', 0x111d6: 'section 2 name',
             0x11217: 'score header', 0x11220: 'hiscore header', 0x11229: 'queued text header (colours 8/9)',
             0x11232: 'HUD labels', 0x11267: 'TIME header', 0x11272: 'DISK ERROR', 0x1129a: 'FATAL DISK ERROR',
             0x112c3: 'SAVING HISCORES', 0x112da: 'LOADING HISCORES', 0x112f1: 'blank line row 22', 0x114a1: 'credits page'}
    for a, n in named.items():
        S[n] = decode_print_string(a)
    tbl = []
    for i in range(5):
        a = l(0x1141e + 4 * i)
        tbl.append(dict(index=i, **decode_print_string(a)))
    S['kernel text table $1141e (jt11)'] = tbl
    S['credits tail (shown when cheat flags cleared)'] = [decode_print_string(0x115b4), decode_print_string(0x115c3)]
    json.dump(S, open(os.path.join(OUT, 'strings.json'), 'w'), indent=1)
    return S


def copper():
    def lst(a, stop):
        r = []
        while a < stop:
            w1, w2 = w(a), w(a + 2)
            if w1 & 1:
                r.append({'addr': hex(a), 'op': 'WAIT' if not (w2 & 1) else 'SKIP', 'vp': hex(w1 >> 8), 'hp': hex(w1 & 0xfe), 'mask': '%04x' % w2})
            else:
                r.append({'addr': hex(a), 'op': 'MOVE', 'reg': '$%03x' % w1, 'val': '%04x' % w2})
            a += 4
            if w1 == 0xffff and w2 == 0xfffe: break
        return r
    C = {'A ($115d0, displays $70000)': lst(0x115d0, 0x115f0), 'common ($115f0 = COP2LC)': lst(0x115f0, 0x116a8),
         'B ($116a8, displays $78000, then COPJMP2)': lst(0x116a8, 0x116cc),
         'boot loader copper $766ae': lst(0x766ae, 0x766d2), 'monitor copper $23d4': lst(0x23d4, 0x23e2)}
    json.dump(C, open(os.path.join(OUT, 'copper.json'), 'w'), indent=1)


def palettes():
    P = {}
    for a, n in [(0x1137e, 'logo (top, title/loading) - colours 0,1,6 animated'), (0x1139e, 'text/loading screen'), (0x113be, 'black'),
                 (0x113de, 'credits/hiscore text'), (0x113fe, 'attract picture grey ramp'), (0x115fa, 'copper top palette (live values)'),
                 (0x11666, 'copper HUD palette (live values)'), (0x766d2, 'boot loading picture')]:
        P[n] = {'addr': hex(a), 'colours': ['%03x' % c for c in pal(a)]}
    P['copper top palette (live values)']['colours'] = ['%03x' % w(0x115fa + 4 * i) for i in range(16)]
    P['copper HUD palette (live values)']['colours'] = ['%03x' % w(0x11666 + 4 * i) for i in range(16)]
    for a, n in [(0x1133e, 'text colour ramp grey/cyan ($34 during attract)'), (0x1135e, 'text colour ramp red (section start / hiscore entry)')]:
        P[n] = {'addr': hex(a), 'steps(colour8,colour9)': [['%03x' % w(a + 4 * i), '%03x' % w(a + 4 * i + 2)] for i in range(8)]}
    json.dump(P, open(os.path.join(OUT, 'palettes.json'), 'w'), indent=1)


def hiscore():
    H = {'note': 'Darc image track 77 is all zeros -> the kernel hiscore screens/name entry print garbage/nothing. '
                 'Original table below comes from re/platoon_b.adf track 77 (loaded to $116cc, $1600 bytes).'}
    darc = adf[77 * TRK:78 * TRK]
    H['darc_track77_nonzero_bytes'] = sum(1 for b in darc if b)
    if os.path.exists(ADF_B):
        b = open(ADF_B, 'rb').read()[77 * TRK:78 * TRK]
        base = 0x116cc
        def bw(a): return struct.unpack('>I', b[a - base:a - base + 4])[0]
        ents = []
        for i in range(10):
            off = bw(0x117e0 + 4 * i)
            e = 0x116e5 + off
            ents.append({'rank': i + 1, 'string_addr': hex(e), 'col': b[e - base], 'row': b[e - base + 1],
                         'name': b[e - base + 6:e - base + 22].decode('latin1'), 'score_bcd': '%08x' % bw(0x11808 + 4 * i)})
        H['entries'] = ents
        H['title_string'] = b[0:0x19].hex()
        H['name_entry_line_$11830'] = b[0x11830 - base:0x1185a - base].hex()
        H['raw_used_bytes_hex'] = b[:0x11860 - base].hex()
    json.dump(H, open(os.path.join(OUT, 'hiscore_original.json'), 'w'), indent=1)


def cheats():
    names = {0x10: 'Q', 0x11: 'W', 0x12: 'E', 0x13: 'R', 0x14: 'T', 0x15: 'Y', 0x16: 'U', 0x17: 'I', 0x18: 'O', 0x19: 'P',
             0x20: 'A', 0x21: 'S', 0x22: 'D', 0x23: 'F', 0x24: 'G', 0x25: 'H', 0x26: 'J', 0x27: 'K', 0x28: 'L',
             0x31: 'Z', 0x32: 'X', 0x33: 'C', 0x34: 'V', 0x35: 'B', 0x36: 'N', 0x37: 'M', 0x4a: 'KEYPAD-'}
    C = {}
    for a, n in [(0x11207, 'CHEAT!!! (sets bit0 of $70(a6))'), (0x11211, 'MEGA CHEAT (sets bit1 of $70(a6))')]:
        seq = []
        while mem[a]: seq.append(mem[a]); a += 1
        C[n] = {'rawkeys': ['%02x' % k for k in seq], 'keys': [names.get(k, '?') for k in seq]}
    json.dump(C, open(os.path.join(OUT, 'cheats.json'), 'w'), indent=1)


def tables():
    T = {'row_offsets_$12d7a(built by jt21 at init)': [i * 0x140 for i in range(25)],
         'bar_masks_$1131e': ['%08x' % l(0x1131e + 4 * i) for i in range(8)],
         'section_loaders_$11166': [hex(l(0x11166 + 4 * i)) for i in range(3)],
         'section_loads': [{'section': 0, 'track': 0x15, 'count': 0x38, 'dest': '0x17000'}, {'section': 1, 'track': 0x54, 'count': 0x1b, 'dest': '0x17000'},
                           {'section': 2, 'track': 0x6f, 'count': 0x30, 'dest': '0x17000'}],
         'jump_table_$f800': [hex(0xf800 + 4 * i + 2 + struct.unpack('>h', mem[0xf802 + 4 * i:0xf804 + 4 * i])[0]) for i in range(33)],
         'exported_pointers_$f884': [hex(l(0xf884)), hex(l(0xf888)), hex(l(0xf88c))],
         'resident_jump_table_$400': {hex(0x400 + 4 * i): hex(0x402 + 4 * i + struct.unpack('>h', mem[0x402 + 4 * i:0x404 + 4 * i])[0]) for i in (0, 1, 2, 3, 4, 5, 8, 9)},
         'monitor_commands_$742': {chr(mem[0x742 + i]) if mem[0x742 + i] >= 32 else '\\x%02x' % mem[0x742 + i]: hex(l(0x756 + 4 * i)) for i in range(19)}}
    json.dump(T, open(os.path.join(OUT, 'tables.json'), 'w'), indent=1)


if __name__ == '__main__':
    selfcheck()
    font_2bpp(); font_mon()
    info = {'hud': hud(), 'pictures': pictures()}
    strings(); copper(); palettes(); hiscore(); cheats(); tables()
    json.dump(info, open(os.path.join(OUT, 'graphics.json'), 'w'), indent=1)
    print('assets written to', OUT)
