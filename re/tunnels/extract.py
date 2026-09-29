#!/usr/bin/env python3
"""Extract the tunnel-section assets of Platoon (Amiga) from re/platoon_darc.adf.

Writes into re/tunnels/assets/:
  palettes.json, messages.json, maze.json, rooms.json, tables.json, frames.json
  maze_map.png (map as drawn by the game, 1 cell = 8x8), maze_map_2x.png, maze_logic.png (schematic)
  map_tiles.png (40 map tiles), view_tiles.png (256 view tiles), viewmaps/vmNN.png + viewmaps_sheet.png
  bobs/<name>_fNN.png + bobs_sheet.png, rooms/room_typeN.png (+ _hotspots.png)
  views/ sample views rendered with the original algorithm
If re/tunnels/assets/ref/*.png (emulator screenshots named view_X_Y_D.png) exist they are compared pixel-exactly.
"""
import os, sys, json, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tlib import *
from PIL import Image, ImageDraw

OUT = os.path.join(HERE, 'assets')


def mk(*p):
    d = os.path.join(OUT, *p)
    os.makedirs(d, exist_ok=True)
    return d


def tile_img(m, a, pal):
    im = Image.new('RGB', (8, 8))
    px = im.load()
    t = planar_tile(m, a)
    for y in range(8):
        for x in range(8):
            px[x, y] = pal[t[y][x]]
    return im


def main():
    m = Mem()
    mk()
    pal = palette(m, PAL_VIEW)
    pals = {'tunnel_1a032': [m.w(PAL_VIEW + 2 * i) for i in range(16)],
            'text_1a052': [m.w(PAL_TEXT + 2 * i) for i in range(16)],
            'hud_1a06e': [m.w(PAL_HUD + 2 * i) for i in range(16)]}
    json.dump({k: ['%03x' % c for c in v] for k, v in pals.items()}, open(os.path.join(OUT, 'palettes.json'), 'w'), indent=1)

    # ---- messages
    msgs = []
    for i in range(42):
        p = m.l(MSGTAB + 4 * i)
        e = p
        while m.b(e) != 0xff:
            e += 1
        msgs.append({'id': i, 'addr': '%05x' % p, 'x': m.b(p), 'row': m.b(p + 1), 'text': m.blk(p + 2, e - p - 2).decode('latin1')})
    json.dump(msgs, open(os.path.join(OUT, 'messages.json'), 'w'), indent=1)
    # text screens (format for resident print $408: see NOTES)
    ts = {}
    for name, a in (('intro', 0x1981c), ('destroyed', 0x19851), ('withdrawn', 0x198a3), ('onemore', 0x198fc)):
        e = a
        while m.b(e) != 0xff:
            e += 1
        ts[name] = {'addr': '%05x' % a, 'bytes': m.blk(a, e + 1 - a).hex()}
    json.dump(ts, open(os.path.join(OUT, 'textscreens.json'), 'w'), indent=1)

    # ---- maze
    cells = [[m.b(MAP + y * MAPW + x) for x in range(MAPW)] for y in range(MAPW)]
    rooms = []
    for r in range(10):
        p = m.w(ROOMPOS + 2 * r)
        t = m.w(ROOMTYPE + 2 * r)
        hl = m.l(HOTSPOTS + 4 * t)
        n = m.w(hl)
        a = hl + 2
        groups = []
        il = m.l(ROOMITEMS + 4 * r)
        for g in range(n):
            k = m.w(a); a += 2
            rects = [list(m.blk(a + 4 * i, 4)) for i in range(k)]
            a += 4 * k
            code = m.w(il + 2 * g)
            groups.append({'rects_x1y1x2y2': rects, 'item_word_addr': '%05x' % (il + 2 * g), 'item': code,
                           'message': msgs[code & 0x7f]['text']})
        rooms.append({'index': r, 'entry_cell': [p >> 8, p & 255], 'type': t, 'picture': '%05x' % m.l(ROOMPICS + 4 * t),
                      'hotspots': groups, 'has_guard': r == 0})
    json.dump({'width': 43, 'height': 43, 'addr': '%05x' % MAP,
               'legend': {'2': 'corridor (walkable)', '3': 'room (cell in d_roompos enters a room)',
                          'other': 'wall; value = map-display tile index (tile at $29220 + v*32)',
                          '0x21+dir': 'player marker drawn temporarily on the map'},
               'start': {'x': 21, 'y': 3, 'dir': 3, 'dirs': 'N=0 E=1 S=2 W=3'},
               'cells': cells}, open(os.path.join(OUT, 'maze.json'), 'w'))
    json.dump(rooms, open(os.path.join(OUT, 'rooms.json'), 'w'), indent=1)

    # map as the game draws it
    im = Image.new('RGB', (MAPW * 8, MAPW * 8))
    for y in range(MAPW):
        for x in range(MAPW):
            im.paste(tile_img(m, MAPTILES + cells[y][x] * 32, pal), (x * 8, y * 8))
    im.save(os.path.join(OUT, 'maze_map.png'))
    im.resize((MAPW * 16, MAPW * 16), Image.NEAREST).save(os.path.join(OUT, 'maze_map_2x.png'))
    # schematic
    S = 14
    im = Image.new('RGB', (MAPW * S, MAPW * S), (40, 30, 20))
    d = ImageDraw.Draw(im)
    for y in range(MAPW):
        for x in range(MAPW):
            v = cells[y][x]
            c = (40, 30, 20) if v not in (2, 3) else ((60, 110, 230) if v == 2 else (200, 60, 60))
            d.rectangle([x * S, y * S, x * S + S - 2, y * S + S - 2], fill=c)
    for r in rooms:
        x, y = r['entry_cell']
        d.rectangle([x * S, y * S, x * S + S - 2, y * S + S - 2], fill=(255, 220, 0))
        d.text((x * S + 2, y * S + 1), str(r['index']), fill=(0, 0, 0))
    d.text((21 * S + 2, 3 * S + 1), '<', fill=(255, 255, 255))
    im.save(os.path.join(OUT, 'maze_logic.png'))

    # tiles
    im = Image.new('RGB', (40 * 9, 9), (80, 0, 80))
    for v in range(40):
        im.paste(tile_img(m, MAPTILES + v * 32, pal), (v * 9, 0))
    im.resize((40 * 9 * 3, 27), Image.NEAREST).save(os.path.join(OUT, 'map_tiles.png'))
    im = Image.new('RGB', (16 * 9, 16 * 9), (80, 0, 80))
    for v in range(256):
        im.paste(tile_img(m, TILES + v * 32, pal), ((v % 16) * 9, (v // 16) * 9))
    im.resize((16 * 9 * 3, 16 * 9 * 3), Image.NEAREST).save(os.path.join(OUT, 'view_tiles.png'))

    # view tile maps
    vd = mk('viewmaps')
    sh = Image.new('RGB', (20 * 84, 2 * 160), (40, 0, 40))
    dr = ImageDraw.Draw(sh)
    for i in range(40):
        t = render_tilemap(m, i, pal)
        t.save(os.path.join(vd, 'vm%02x.png' % i))
        x, y = (i % 20) * 84, (i // 20) * 160
        sh.paste(t, (x, y + 14))
        dr.text((x + 2, y + 1), ('L%02x' % i) if i < 20 else ('R%02x' % (i - 20)), fill=(255, 255, 0))
    sh.save(os.path.join(OUT, 'viewmaps_sheet.png'))
    json.dump({'meaning': {
        'code bits (per half)': 'bit4 door (room) ahead, bit3 wall ahead, bit2 side opening, bits0-1 = 3-distance',
        '0-3': 'open corridor >=4 cells, no side opening within 4 cells; animated with (y&3 facing N/S, x&3 facing E/W)',
        '4-7': 'side opening, 4=3 cells ahead .. 7=adjacent',
        '8-b': 'wall ahead, 8=3 cells ahead .. b=directly ahead',
        'c-f': 'wall + side opening; LEFT: low bits = wallDist|openDist (OR), RIGHT: low bits = openDist',
        '10-13': 'room entrance ahead, 10=3 cells ahead .. 13=directly ahead',
        'left half': 'tile map index = code, drawn at byte column $3b3f8 (10, or 0 with map)',
        'right half': 'tile map index = code + $14, drawn at byte column $3b3fe (20, or 10 with map)'},
        'usage_count_all_cells_dirs': view_usage(m)}, open(os.path.join(OUT, 'viewcodes.json'), 'w'), indent=1)

    # sample views
    vv = mk('views')
    for (x, y, d) in ((21, 3, 3), (11, 3, 3), (11, 4, 2), (7, 3, 1), (3, 7, 0), (39, 31, 0)):
        v, codes = render_view(m, x, y, d, pal)
        v.save(os.path.join(vv, 'view_%d_%d_%d.png' % (x, y, d)))

    # bobs
    recolour_crosshair(m)
    bd = mk('bobs')
    groups = [('crosshair', 0x1e020, 1), ('flare_sect_1e028', 0x1e028, 4), ('flare_sect_1e048', 0x1e048, 2),
              ('enemy_shot', 0x1e058, 5), ('corridor_enemy', 0x1e080, 12), ('room_guard', 0x1e0e0, 5),
              ('water_enemy', 0x1e108, 7)]
    frames = {}
    allims = []
    for name, tab, n in groups:
        frames[name] = []
        for f in range(n):
            e = tab + 8 * f
            off = m.l(e)
            hdr = m.l(BOBBASE + off)
            b = bob_image(m, off, pal)
            b.save(os.path.join(bd, '%s_f%02d.png' % (name, f)))
            allims.append(b)
            frames[name].append({'entry': '%05x' % e, 'data': '%05x' % (BOBBASE + off), 'w_px': ((hdr >> 16) + 1) * 16,
                                 'h': (hdr & 0xffff) + 1})
    json.dump(frames, open(os.path.join(OUT, 'frames.json'), 'w'), indent=1)
    W = sum(i.size[0] + 4 for i in allims)
    H = max(i.size[1] for i in allims)
    sh = Image.new('RGB', (W, H), (60, 0, 60))
    x = 0
    for b in allims:
        sh.paste(b, (x, 0), b)
        x += b.size[0] + 4
    sh.save(os.path.join(OUT, 'bobs_sheet.png'))

    # rooms
    rd = mk('rooms')
    for t in range(4):
        im = room_picture(m, m.l(ROOMPICS + 4 * t), pal)
        im.save(os.path.join(rd, 'room_type%d.png' % t))
        hl = m.l(HOTSPOTS + 4 * t)
        n = m.w(hl)
        a = hl + 2
        im2 = im.resize((320, 288), Image.NEAREST)
        dr = ImageDraw.Draw(im2)
        for g in range(n):
            k = m.w(a); a += 2
            for i in range(k):
                x1, y1, x2, y2 = m.blk(a, 4); a += 4
                # rects are in crosshair top-left coords; the visible crosshair centre is +9,+9
                dr.rectangle([(x1 + 9) * 2, (y1 + 9) * 2, (x2 + 9) * 2, (y2 + 9) * 2], outline=(255, 255, 0))
                dr.text(((x1 + 9) * 2 + 2, (y1 + 9) * 2 + 1), str(g), fill=(255, 255, 0))
        im2.save(os.path.join(rd, 'room_type%d_hotspots.png' % t))
    im = Image.new('RGB', (160, 144))
    ro = Image.open(os.path.join(rd, 'room_type0.png'))
    im.paste(ro)
    g = bob_image(m, m.l(0x1e0e0), pal)
    im.paste(g, (30, 35), g)
    im.save(os.path.join(rd, 'room0_with_guard.png'))

    # misc tables
    tab = {
        'dir_delta': [[(m.b(DIRDELTA + 2 * i) ^ 0x80) - 0x80, (m.b(DIRDELTA + 2 * i + 1) ^ 0x80) - 0x80] for i in range(4)],
        'dir_offsets_left_right_fwd': [[m.sw(m.l(DIROFS + 4 * i) + 2 * k) for k in range(3)] for i in range(4)],
        'sway_table_dxdy_plus_24_68': [[m.w(0x19bc2 + 4 * i), m.w(0x19bc4 + 4 * i)] for i in range(32)],
        'water_enemy_xy': [[m.w(0x19cf2 + 4 * i), m.w(0x19cf4 + 4 * i)] for i in range(8)],
        'water_enemy_frame_entries': ['%05x' % m.l(0x19d12 + 4 * i) for i in range(8)],
        'score_bcd': {'enemy_1a0a0': m.blk(0x1a0a0, 4).hex(), 'item_1a0a4': m.blk(0x1a0a4, 4).hex(),
                      'exit_1a0a8': m.blk(0x1a0a8, 4).hex()},
        'objects_initial_19d32': [m.blk(0x19d32 + 18 * i, 18).hex() for i in range(8)],
        'item_handlers_199bc': ['%05x' % m.l(0x199bc + 4 * i) for i in range(22)],
    }
    json.dump(tab, open(os.path.join(OUT, 'tables.json'), 'w'), indent=1)

    # verification against emulator screenshots (crop of the view area)
    refs = sorted(glob.glob(os.path.join(OUT, 'ref', 'view_*.png')))
    m2 = Mem()
    bad = 0
    for r in refs:
        x, y, d = map(int, os.path.basename(r)[5:-4].split('_'))
        v, _ = render_view(m2, x, y, d)
        sc = Image.open(r).convert('RGB').crop((97, 36, 257, 180))
        n = sum(1 for yy in range(144) for xx in range(160) if v.getpixel((xx, yy)) != sc.getpixel((xx, yy)))
        if n > 120:   # crosshair bob covers ~110 pixels
            bad += 1
            print('MISMATCH', r, n)
    if refs:
        print('verified %d emulator views, %d mismatches' % (len(refs), bad))
    print('assets written to', OUT)


def view_usage(m):
    from collections import Counter
    L, R = Counter(), Counter()
    for y in range(MAPW):
        for x in range(MAPW):
            if m.b(MAP + y * MAPW + x) != 2:
                continue
            for d in range(4):
                a, b = view_indices(m, x, y, d)
                L['%02x' % a] += 1
                R['%02x' % b] += 1
    return {'left': dict(sorted(L.items())), 'right': dict(sorted(R.items()))}


if __name__ == '__main__':
    main()
