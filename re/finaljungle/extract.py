#!/usr/bin/env python3
"""Asset extractor for Platoon (Amiga) section 2 -- module re/finaljungle (final jungle + bunker/Barnes room).

Section 2 = disk tracks 111..158 (48 tracks) loaded UNCOMPRESSED 1:1 to RAM $17000..$58fff:
    RAM address A  <->  ADF offset  A - $17000 + 111*$1600  (= A + $81a00)
Everything is read from re/platoon_darc.adf (no RAM dump needed), EXCEPT track 127: that track is corrupt in the
Darc image (picture 5 = right-turn rooms of types 3/4 shows garbage, in the emulator too); by default it is taken from
re/platoon_b.adf (original dump, identical to Darc on every other section-2 track). Use --darc-only to disable.

Writes into re/finaljungle/assets/:
  palettes.json / palettes.png  game palette $18fc2, text-screen palette $18fe2, HUD palette $176be
  pic05_darc_corrupt.png        picture 5 decoded from the unpatched Darc image (what the game shows)
  pic01..pic10.png              the 10 room background pictures (RLE at $19400+ofs, table $18f9a), 320x152
                                (only rows 0..143 are shown in game; a red line marks row 144)
  rooms/room_TT.png             background picture + static objects of each of the 17 room types, rendered
                                exactly like the game (painter order, cookie-cut blits, y -> screen mapping)
  bobs.png / bobs.json          all 96 entries of the bob directory $47400 (data $47700+ofs, mask + 4 planes)
  map.png / map.json            the 10x12 room grid $18ea4 with room types, exits and a solved route
  maze_graph.json               reachable (cell, heading) states and transitions, shortest route to the bunker
  messages.json                 in-game message table $189e0 (17 entries) and the text screens
  tables.json                   room-type tables, object tables, grenade arc, exit parameters, slot init table
"""
import os, sys, json, struct
from collections import deque
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ADF = os.path.join(HERE, '..', 'platoon_darc.adf')
OUT = os.path.join(HERE, 'assets')

SEC_BASE = 0x17000
SEC_ADF = 111 * 0x1600
SEC_LEN = 48 * 0x1600


ADF_ORIG = os.path.join(HERE, '..', 'platoon_b.adf')
BAD_TRACK = 127          # Darc track 127 (RAM $2d000-$2e5ff, inside picture 5) is CORRUPT, see NOTES.md (d.2)


def load_section(adf_path=ADF, fix_track127=True):
    adf = open(adf_path, 'rb').read()
    mem = bytearray(0x80000)
    mem[SEC_BASE:SEC_BASE + SEC_LEN] = adf[SEC_ADF:SEC_ADF + SEC_LEN]
    if fix_track127 and os.path.exists(ADF_ORIG):
        # the original (protected) dump has a good copy of track 127; with it picture 5 decodes to exactly
        # the bytes up to the start of picture 6 ($301a2) and shows a proper right-turn jungle scene.
        orig = open(ADF_ORIG, 'rb').read()
        ram = SEC_BASE + (BAD_TRACK - 111) * 0x1600
        mem[ram:ram + 0x1600] = orig[BAD_TRACK * 0x1600:(BAD_TRACK + 1) * 0x1600]
    return mem


FIX = '--darc-only' not in sys.argv
M = load_section(fix_track127=FIX)


def w(a): return struct.unpack('>H', M[a:a + 2])[0]
def sw(a): return struct.unpack('>h', M[a:a + 2])[0]
def l(a): return struct.unpack('>I', M[a:a + 4])[0]
def sb(a): v = M[a]; return v - 256 if v & 0x80 else v


def amiga_rgb(c):
    return (((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17)


# ------------------------------------------------------------------ addresses
PAL_GAME = 0x18fc2      # 16 words, playfield palette (set by $17676 / $1771e)
PAL_TEXT = 0x18fe2      # 16 words, text screens ($176ea)
PAL_HUD = 0x176be       # 16 words, HUD palette ($17676 -> kernel $f87c)
PIC_TABLE = 0x18f9a     # 10 longs: offset of picture n (1..10) relative to PIC_BASE
PIC_BASE = 0x19400
PIC_PLANE = 0x17c0      # bytes per decoded plane (152 rows x 40 bytes)
MAP = 0x18ea4           # 120 bytes: 12 rows x 10 cols of room types
MAP_W, MAP_H = 10, 12
START_ROOM = 0x69       # $1816c: d0 = $69
DIRS_INIT = 0x18f44     # long $010afff6 = [R, B, L, F] byte offsets (heading "north")
TYPE_PIC = 0x18f1d      # 17 bytes: room type -> picture number 1..10
TYPE_EXITS = 0x18f2e    # 17 bytes: room type -> exit mask (bit0 left, bit1 right)
ROOM_LISTS = 0x18866    # 17 longs: room type -> static object list (word type, word x, word y; $ffff end)
OBJ_GFX = 0x188aa       # 12 longs: static object type -> bob directory entry
OBJ_HANDLER = 0x188da   # 12 longs: static object type -> handler
BOB_DIR = 0x47400       # 8-byte entries: long ofs (from BOB_DATA), word w-1 (words), word h-1 (rows)
BOB_DATA = 0x47700
N_BOBS = 96             # entries $47400..$476ff (data $47700..$57a64)
MSG_TABLE = 0x189e0
N_MSG = 17
SLOT_INIT = 0x18df0     # 46 longs copied to $57e22 on every room entry
GREN_ARC = 0x18400      # 13 words
EXIT_FRAME = 0x18f48    # 3 bytes  (index exits-1): soldier start frame
EXIT_X = 0x18f4c        # 3 words: soldier start x ($ffff = choose side)
EXIT_DX = 0x18f52       # 3 words: soldier dx
EXIT_HANDLER = 0x18f58  # 3 longs: soldier handler
HINTS_INIT = 0x189d8    # long copied to $189dc (random hint message numbers)
SCORE_KILL = 0x19002    # 4-byte BCD added per soldier killed (kernel $f80c)

TEXTS = {'intro': 0x18c6d, 'won': 0x18b5f, 'napalm': 0x18bb8, 'withdrawn': 0x18c14,
         'destroyed_2nd': 0x18ce7, 'one_more_chance': 0x18d2c}


def palette(a):
    return [w(a + 2 * i) for i in range(16)]


# ------------------------------------------------------------------ picture decoder ($17604)
def decode_picture(n):
    """exact port of $17604: 4 planes, per plane: first byte = escape; then
    b != esc -> literal b ; b == esc -> value, count (count 0 = 256); exactly $17c0 bytes per plane"""
    src = PIC_BASE + l(PIC_TABLE + 4 * (n - 1))
    planes = []
    for p in range(4):
        out = bytearray()
        esc = M[src]; src += 1
        while len(out) < PIC_PLANE:
            b = M[src]; src += 1
            if b != esc:
                out.append(b)
            else:
                val = M[src]; cnt = M[src + 1]; src += 2
                cnt = cnt if cnt else 256
                for _ in range(cnt):
                    out.append(val)
                    if len(out) == PIC_PLANE:   # dbeq exits when the plane counter hits 0
                        break
        planes.append(out)
    return planes, src


def planes_to_image(planes, pal, width_bytes=40, rows=152):
    im = Image.new('RGB', (width_bytes * 8, rows))
    px = im.load()
    for y in range(rows):
        for xb in range(width_bytes):
            bs = [planes[p][y * width_bytes + xb] for p in range(4)]
            for bit in range(8):
                m = 0x80 >> bit
                c = sum(((bs[p] & m) != 0) << p for p in range(4))
                px[xb * 8 + bit, y] = amiga_rgb(pal[c])
    return im


# ------------------------------------------------------------------ bobs
def bob_entry(e):
    """e = address of a directory entry -> dict"""
    ofs = l(e); wm1 = w(e + 4); hm1 = w(e + 6)
    a = BOB_DATA + ofs
    hw, hh = w(a), w(a + 2)
    return dict(entry=e, ofs=ofs, data=a, words=wm1 + 1, rows=hm1 + 1, hdr_words=hw + 1, hdr_rows=hh + 1)


def bob_planes(b):
    """returns (mask rows, [plane rows]) as lists of ints (width = words*16 bits); header taken from the data"""
    W_, H_ = b['hdr_words'], b['hdr_rows']
    a = b['data'] + 4
    blk = []
    for k in range(5):
        rows = []
        for y in range(H_):
            v = 0
            for x in range(W_):
                v = (v << 16) | w(a); a += 2
            rows.append(v)
        blk.append(rows)
    return blk[0], blk[1:]


def bob_image(b, pal, bg=None):
    W_, H_ = b['hdr_words'], b['hdr_rows']
    mask, pl = bob_planes(b)
    im = Image.new('RGBA', (W_ * 16, H_), (0, 0, 0, 0) if bg is None else bg)
    px = im.load()
    for y in range(H_):
        for x in range(W_ * 16):
            bit = 1 << (W_ * 16 - 1 - x)
            if mask[y] & bit:
                c = sum(((pl[p][y] & bit) != 0) << p for p in range(4))
                px[x, y] = amiga_rgb(pal[c]) + (255,)
    return im


def blit_bob(fb, b, x, y_top):
    """cookie-cut blit into a 4-plane framebuffer fb[p][row] (bytearray 40*rows each), like $17850.
    x in pixels (word aligned dest + shift), y_top screen row. No clipping (like the original)."""
    W_, H_ = b['hdr_words'], b['hdr_rows']
    mask, pl = bob_planes(b)
    shift = x & 15
    xb = (x >> 3) & 0xfffe
    for yy in range(H_):
        row = y_top + yy
        if row < 0:
            continue
        # (W+1) words, shifted
        m = (mask[yy] << 16) >> shift
        for p in range(4):
            d = (pl[p][yy] << 16) >> shift
            base = row * 40 + xb
            for k in range(W_ + 1):
                a = base + 2 * k
                if a + 1 >= len(fb[p]):
                    continue
                sh = 16 * (W_ - k)
                mw = (m >> sh) & 0xffff
                dw = (d >> sh) & 0xffff
                old = (fb[p][a] << 8) | fb[p][a + 1]
                new = (dw & mw) | (old & ~mw & 0xffff)
                fb[p][a] = new >> 8; fb[p][a + 1] = new & 255


def screen_y(y, gfx):
    """$1773e: screen top row = $8f - y - (h-1 of entry 0 of the object's directory)"""
    return (0x8f - y - w(gfx + 6)) & 0xffff


def draw_objects(fb, objs):
    """objs: list of (slot, x, y, gfx, frame, anim). Sort exactly like $1773e: bucket y (-$14 for slots 1-3 and
    7-9), linear probe upward, drawn from highest bucket down."""
    buckets = {}
    for (slot, x, y, gfx, frame, anim) in sorted(objs, key=lambda o: -o[0]):   # slot 15 first
        k = y
        if slot != 0 and (slot < 4 or 7 <= slot < 10):
            k = (k - 0x14) & 0xffff
        k &= 0xff
        while k in buckets:
            k += 1
        buckets[k] = (slot, x, y, gfx, frame, anim)
    for k in sorted(buckets, reverse=True):
        if k > 0xff:
            continue          # never drawn (draw loop starts at $5808f)
        slot, x, y, gfx, frame, anim = buckets[k]
        idx = ((anim & 7) >> 1) + frame
        b = bob_entry(gfx + 8 * idx)
        yt = screen_y(y, gfx)
        if yt & 0x8000:
            yt -= 0x10000
        blit_bob(fb, b, x, yt)


# ------------------------------------------------------------------ maze
def maze():
    cells = list(M[MAP:MAP + 120])
    d0 = l(DIRS_INIT)
    # dirs long bytes: [R, B, L, F]   (heading index 0 = north as displayed in map.png)
    start = (START_ROOM, d0, 0)

    def step(state, side):
        room, dl, comp = state
        if side == 'R':
            nroom = (room + sb_(dl >> 24)) & 0xff
            ndl = ((dl << 8) | (dl >> 24)) & 0xffffffff     # rol.l #8
            ncomp = (comp + 1) & 3
        else:
            nroom = (room + sb_((dl >> 8) & 0xff)) & 0xff
            ndl = ((dl >> 8) | (dl << 24)) & 0xffffffff     # ror.l #8
            ncomp = (comp - 1) & 3
        return (nroom, ndl, ncomp)

    def sb_(v):
        v &= 0xff
        return v - 256 if v & 0x80 else v

    seen = {start: None}
    q = deque([start])
    edges = []
    while q:
        s = q.popleft()
        t = cells[s[0]] if s[0] < 120 else None
        ex = M[TYPE_EXITS + t] if t is not None and t <= 16 else 0
        for side, bit in (('L', 1), ('R', 2)):
            if ex & bit:
                n = step(s, side)
                edges.append((s, side, n))
                if n not in seen:
                    seen[n] = (s, side)
                    q.append(n)
    return cells, start, seen, edges


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.join(OUT, 'rooms'), exist_ok=True)
    pg, pt, ph = palette(PAL_GAME), palette(PAL_TEXT), palette(PAL_HUD)
    json.dump({'game_18fc2': ['%03x' % c for c in pg], 'text_18fe2': ['%03x' % c for c in pt],
               'hud_176be': ['%03x' % c for c in ph]}, open(os.path.join(OUT, 'palettes.json'), 'w'), indent=1)
    im = Image.new('RGB', (16 * 24, 3 * 24))
    d = ImageDraw.Draw(im)
    for r, p in enumerate((pg, pt, ph)):
        for i, c in enumerate(p):
            d.rectangle([i * 24, r * 24, i * 24 + 23, r * 24 + 23], fill=amiga_rgb(c))
    im.save(os.path.join(OUT, 'palettes.png'))

    # pictures
    pics = {}
    info = []
    for n in range(1, 11):
        planes, end = decode_picture(n)
        pics[n] = planes
        img = planes_to_image(planes, pg)
        dd = ImageDraw.Draw(img)
        img2 = img.copy()
        ImageDraw.Draw(img2).line([0, 144, 319, 144], fill=(255, 0, 0))
        img2.save(os.path.join(OUT, 'pic%02d.png' % n))
        if n == 5 and FIX:
            dm = load_section(fix_track127=False)
            global M
            keep = M; M = dm
            pdarc, end_d = decode_picture(5)
            M = keep
            planes_to_image(pdarc, pg).save(os.path.join(OUT, 'pic05_darc_corrupt.png'))
        info.append({'n': n, 'src': '%05x' % (PIC_BASE + l(PIC_TABLE + 4 * (n - 1))), 'end': '%05x' % end})

    # bobs
    bobs = []
    sheet_items = []
    for i in range(N_BOBS):
        b = bob_entry(BOB_DIR + 8 * i)
        bobs.append({k: (('%05x' % v) if k in ('entry', 'data', 'ofs') else v) for k, v in b.items()})
        sheet_items.append((i, bob_image(b, pg, (40, 40, 60, 255))))
    json.dump(bobs, open(os.path.join(OUT, 'bobs.json'), 'w'), indent=0)
    cols = 12
    cw = max(im.size[0] for _, im in sheet_items) + 6
    ch = max(im.size[1] for _, im in sheet_items) + 14
    S = Image.new('RGB', (cols * cw, ((len(sheet_items) + cols - 1) // cols) * ch), (0, 0, 0))
    dS = ImageDraw.Draw(S)
    for k, (i, im) in enumerate(sheet_items):
        x, y = (k % cols) * cw, (k // cols) * ch
        dS.text((x + 1, y), '%d' % i, fill=(255, 255, 0))
        S.paste(im, (x + 2, y + 12))
    S = S.resize((S.size[0] * 2, S.size[1] * 2), Image.NEAREST)
    S.save(os.path.join(OUT, 'bobs.png'))

    # room renders: picture + static objects (as the game draws them at room entry, player at (x=$a0,y=0))
    rooms = []
    for t in range(17):
        pic = M[TYPE_PIC + t]
        fb = [bytearray(pics[pic][p][:144 * 40]) for p in range(4)]
        objs = []
        p = l(ROOM_LISTS + 4 * t)
        slot = 10
        lst = []
        while not (w(p) & 0x8000):
            ot, x, y = w(p), w(p + 2), w(p + 4)
            lst.append({'type': ot, 'x': x, 'y': y, 'gfx': '%05x' % l(OBJ_GFX + 4 * ot),
                        'handler': '%05x' % l(OBJ_HANDLER + 4 * ot)})
            objs.append((slot, x, y, l(OBJ_GFX + 4 * ot), 0, 0))
            slot += 1; p += 6
        objs.append((0, 0xa0, 0, 0x47400, 4, 0))   # player standing (frame 4) at the entry point
        if t == 16:
            objs.append((4, 0x96, 0x69, 0x47628, 0, 0))   # Barnes
        draw_objects(fb, objs)
        img = planes_to_image(fb, pg, rows=144)
        img.save(os.path.join(OUT, 'rooms', 'room_%02d.png' % t))
        rooms.append({'type': t, 'picture': pic, 'exits': M[TYPE_EXITS + t], 'objects': lst})

    # maze
    cells, start, seen, edges = maze()
    json.dump({'cells': cells, 'width': MAP_W, 'height': MAP_H, 'start_room': START_ROOM,
               'dirs_init': '%08x' % l(DIRS_INIT), 'room_types': rooms},
              open(os.path.join(OUT, 'map.json'), 'w'), indent=1)
    # shortest path to any type-16 room
    goal = None
    for s in seen:
        if cells[s[0]] == 16:
            # BFS order is not preserved in dict iteration for distance; recompute
            pass
    # BFS distances
    dist = {start: 0}
    q = deque([start]); par = {start: None}
    adj = {}
    for (s, side, n) in edges:
        adj.setdefault(s, []).append((side, n))
    while q:
        s = q.popleft()
        if cells[s[0]] == 16:
            goal = s; break
        for side, n in adj.get(s, []):
            if n not in dist:
                dist[n] = dist[s] + 1; par[n] = (s, side); q.append(n)
    route = []
    s = goal
    while s is not None and par.get(s):
        ps, side = par[s]
        route.append(side); s = ps
    route.reverse()
    names = 'NESW'
    json.dump({'states': [{'room': s[0], 'row': s[0] // 10, 'col': s[0] % 10, 'type': cells[s[0]],
                           'dirs': '%08x' % s[1], 'compass': names[s[2]]} for s in seen],
               'edges': [{'from': [s[0], names[s[2]]], 'exit': side, 'to': [n[0], names[n[2]]],
                          'to_type': cells[n[0]] if n[0] < 120 else None} for (s, side, n) in edges],
               'shortest_route_to_bunker': route, 'bunker_state': [goal[0], names[goal[2]]] if goal else None},
              open(os.path.join(OUT, 'maze_graph.json'), 'w'), indent=0)

    # map picture
    CS = 64
    im = Image.new('RGB', (MAP_W * CS, MAP_H * CS), (20, 20, 20))
    d = ImageDraw.Draw(im)
    visited_cells = set(s[0] for s in seen)
    for r in range(MAP_H):
        for c in range(MAP_W):
            t = cells[r * 10 + c]
            x0, y0 = c * CS, r * CS
            if t == 0 and (r * 10 + c) not in visited_cells:
                continue
            thumb = Image.open(os.path.join(OUT, 'rooms', 'room_%02d.png' % t)).resize((CS - 4, int((CS - 4) * 144 / 320)))
            col = (200, 60, 60) if t == 16 else ((60, 200, 60) if r * 10 + c == START_ROOM else (90, 90, 90))
            d.rectangle([x0 + 1, y0 + 1, x0 + CS - 2, y0 + CS - 2], outline=col)
            im.paste(thumb, (x0 + 2, y0 + 2))
            ex = M[TYPE_EXITS + t]
            d.text((x0 + 3, y0 + 34), 't%d %s' % (t, {0: '--', 1: 'L', 2: 'R', 3: 'LR'}[ex]), fill=(255, 255, 0))
            d.text((x0 + 3, y0 + 46), '#%d' % (r * 10 + c), fill=(200, 200, 255))
    # route arrows
    s = start
    pts = [s]
    for side in route:
        for sd, n in adj[s]:
            if sd == side:
                s = n; break
        pts.append(s)
    for a, b in zip(pts, pts[1:]):
        ax, ay = (a[0] % 10) * CS + CS // 2, (a[0] // 10) * CS + CS // 2
        bx, by = (b[0] % 10) * CS + CS // 2, (b[0] // 10) * CS + CS // 2
        d.line([ax, ay, bx, by], fill=(255, 128, 0), width=3)
    im.save(os.path.join(OUT, 'map.png'))

    # messages
    msgs = []
    for i in range(N_MSG):
        a = l(MSG_TABLE + 4 * i)
        col, row = M[a], M[a + 1]
        s = bytearray()
        k = a + 2
        while M[k] != 0xff:
            s.append(M[k]); k += 1
        msgs.append({'n': i, 'addr': '%05x' % a, 'x': col, 'y': row, 'text': s.decode('latin1')})
    texts = {}
    for name, a in TEXTS.items():
        # $408 print string: [col,row] pairs after 0, 1..4 = colour slot + value, $ff end
        parts = []
        k = a
        cur = {'col': M[k], 'row': M[k + 1], 'text': ''}
        k += 2
        while True:
            c = M[k]
            if c == 0xff:
                parts.append(cur); break
            if c == 0:
                parts.append(cur); cur = {'col': M[k + 1], 'row': M[k + 2], 'text': ''}; k += 3; continue
            if 1 <= c <= 4:
                cur['text'] += '{c%d=%d}' % (c, M[k + 1]); k += 2; continue
            cur['text'] += chr(c); k += 1
        texts[name] = {'addr': '%05x' % a, 'lines': parts}
    json.dump({'messages_189e0': msgs, 'text_screens': texts}, open(os.path.join(OUT, 'messages.json'), 'w'), indent=1)

    # tables
    tables = {
        'pictures': info,
        'type_picture_18f1d': list(M[TYPE_PIC:TYPE_PIC + 17]),
        'type_exits_18f2e': list(M[TYPE_EXITS:TYPE_EXITS + 17]),
        'static_objects': [{'type': i, 'gfx': '%05x' % l(OBJ_GFX + 4 * i), 'handler': '%05x' % l(OBJ_HANDLER + 4 * i)}
                           for i in range(12)],
        'grenade_arc_18400': [sw(GREN_ARC + 2 * i) for i in range(13)],
        'exit_params': [{'exits': e + 1, 'frame': M[EXIT_FRAME + e], 'x': sw(EXIT_X + 2 * e), 'dx': sw(EXIT_DX + 2 * e),
                         'handler': '%05x' % l(EXIT_HANDLER + 4 * e)} for e in range(3)],
        'hints_189d8': list(M[HINTS_INIT:HINTS_INIT + 4]),
        'score_per_kill_19002_bcd': M[SCORE_KILL:SCORE_KILL + 4].hex(),
        'slot_init_18df0': [M[SLOT_INIT + 18 * i:SLOT_INIT + 18 * i + 18].hex() for i in range(10)],
    }
    json.dump(tables, open(os.path.join(OUT, 'tables.json'), 'w'), indent=1)
    print('route to bunker:', ''.join(route), 'goal', goal, 'states', len(seen))


if __name__ == '__main__':
    main()
