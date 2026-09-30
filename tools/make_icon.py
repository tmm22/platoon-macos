#!/usr/bin/env python3
"""Builds the app icon (port/Resources/AppIcon.icns) from the loading picture on YOUR Platoon disk image.

usage: tools/make_icon.py [DISK.adf] [OUT.icns]      (defaults: re/platoon_port.adf, port/Resources/AppIcon.icns)

The picture is decoded exactly like the boot loader at $761dc does: tracks 18-20 loaded to $70000, a byte-RLE
stream from $70022 (n>=0: n+1 literal bytes; n<0 (not $80): next byte repeated (-n & $7f)+1 times), written as
200 rows x 4 bitplanes x 40 bytes; palette = 16 of the 32 words at $766d2 in the loader (ADF offset $70c00 + $6d2).
Requires Pillow and macOS iconutil. No game artwork is stored in the repository."""
import os, sys, subprocess, tempfile
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
adf_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 're', 'platoon_port.adf')
out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'port', 'Resources', 'AppIcon.icns')
adf = open(adf_path, 'rb').read()
T = 0x1600
src = adf[18 * T:21 * T]
pal_off = 0x70c00 + 0x6d2
pal = [int.from_bytes(adf[pal_off + 2 * i:pal_off + 2 * i + 2], 'big') for i in range(16)]

planes = [bytearray(40 * 200) for _ in range(4)]
out = []
p = 0x22
while len(out) < 200 * 4 * 40 and p < len(src):
    b = src[p]; p += 1
    if b < 0x80:
        out += src[p:p + b + 1]; p += b + 1
    elif b != 0x80:
        n = ((-b) & 0xff) & 0x7f
        out += bytes([src[p]]) * (n + 1); p += 1
for i, v in enumerate(out[:200 * 4 * 40]):
    row, rem = divmod(i, 160)
    plane, col = divmod(rem, 40)
    planes[plane][row * 40 + col] = v

img = Image.new('RGB', (320, 200))
px = img.load()
for y in range(200):
    for x in range(320):
        bit = 7 - (x & 7)
        c = sum(((planes[k][y * 40 + (x >> 3)] >> bit) & 1) << k for k in range(4))
        w = pal[c]
        px[x, y] = (((w >> 8) & 15) * 17, ((w >> 4) & 15) * 17, (w & 15) * 17)

crop = img.crop((91, 30, 91 + 112, 30 + 112))    # soldier + silhouettes
S, inner = 1024, 824
off = (S - inner) // 2
icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
mask = Image.new('L', (inner, inner), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, inner - 1, inner - 1), radius=185, fill=255)
icon.paste(crop.resize((inner, inner), Image.NEAREST).convert('RGBA'), (off, off), mask)
ImageDraw.Draw(icon).rounded_rectangle((off, off, off + inner - 1, off + inner - 1), radius=185, outline=(40, 30, 10, 255), width=10)
with tempfile.TemporaryDirectory() as d:
    iconset = os.path.join(d, 'AppIcon.iconset'); os.mkdir(iconset)
    for sz in (16, 32, 128, 256, 512):
        icon.resize((sz, sz), Image.LANCZOS).save(f'{iconset}/icon_{sz}x{sz}.png')
        icon.resize((sz * 2, sz * 2), Image.LANCZOS).save(f'{iconset}/icon_{sz}x{sz}@2x.png')
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', out_path], check=True)
print('wrote', out_path)
