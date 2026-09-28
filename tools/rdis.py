#!/usr/bin/env python3
"""Recursive-descent 68000 disassembler for Amiga RAM dumps.

usage: rdis.py RAMDUMP LO HI [--entry ADDR ...] [--cov HISTFILE ...] [--labels FILE] > out.s

- RAMDUMP: raw chip RAM image (address 0 = file offset 0), e.g. from the emu `dump` command.
- LO/HI: hex address range to list.
- Entry points: explicit --entry, every address from coverage histograms (--cov, emu --pchist output),
  and optional label file lines "ADDR NAME [comment]".
Code is discovered by following branches from the entries; everything else is listed as data.
Each label gets an xref comment listing its callers/branchers.
"""
import sys, re, argparse
import capstone

ap = argparse.ArgumentParser()
ap.add_argument('ram'); ap.add_argument('lo'); ap.add_argument('hi')
ap.add_argument('--entry', action='append', default=[])
ap.add_argument('--cov', action='append', default=[])
ap.add_argument('--labels', action='append', default=[])
ap.add_argument('--follow-lo', default=None, help='restrict following to this range (default LO)')
ap.add_argument('--follow-hi', default=None)
a = ap.parse_args()
mem = open(a.ram, 'rb').read()
LO, HI = int(a.lo, 16), int(a.hi, 16)
FLO = int(a.follow_lo, 16) if a.follow_lo else LO
FHI = int(a.follow_hi, 16) if a.follow_hi else HI

md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_BIG_ENDIAN | capstone.CS_MODE_M68K_000)

names = {}
comments = {}
for lf in a.labels:
    for line in open(lf):
        line = line.strip()
        if not line or line.startswith('#'): continue
        parts = line.split(None, 2)
        ad = int(parts[0], 16)
        if len(parts) > 1: names[ad] = parts[1]
        if len(parts) > 2: comments[ad] = parts[2]

entries = set(int(e, 16) for e in a.entry)
for cf in a.cov:
    for line in open(cf):
        p = line.split()
        if p: entries.add(int(p[0], 16))
entries |= set(k for k in names if FLO <= k < FHI and not names[k].startswith('v_') and not names[k].startswith('d_'))

insns = {}      # addr -> (size, mnemonic, op_str)
targets = {}    # addr -> set(from)
data_refs = {}  # addr -> set(from) for absolute/lea references
BRANCH = re.compile(r'^(b(ra|sr|hi|ls|cc|cs|ne|eq|vc|vs|pl|mi|ge|lt|gt|le|hs|lo)|db\w+|jsr|jmp)(\.[bwls])?$')
STOP = {'rts', 'rte', 'rtr', 'bra', 'bra.b', 'bra.w', 'bra.s', 'jmp', 'illegal'}
hexre = re.compile(r'\$([0-9a-f]+)(\.[wl])?')

def decode(addr):
    code = mem[addr:addr + 10]
    for i in md.disasm(code, addr, 1):
        return i
    return None

work = [e for e in entries if FLO <= e < FHI]
while work:
    pc = work.pop()
    while FLO <= pc < FHI and pc not in insns:
        if pc & 1: break
        i = decode(pc)
        if i is None: break
        mn = i.mnemonic; op = i.op_str
        insns[pc] = (i.size, mn, op)
        base = mn.split('.')[0]
        if BRANCH.match(mn) or base in ('jsr', 'jmp', 'bsr', 'bra'):
            # only direct targets (no register indirect)
            if '(' not in op or 'pc)' in op:
                m = hexre.findall(op)
                if m:
                    t = int(m[-1][0], 16)
                    targets.setdefault(t, set()).add(pc)
                    if FLO <= t < FHI: work.append(t)
        else:
            for m in hexre.finditer(op):
                v = int(m.group(1), 16)
                if 0x400 <= v < 0x80000 and (m.group(2) or 'pc)' in op or 'lea' in mn or mn.startswith('pea')):
                    data_refs.setdefault(v, set()).add(pc)
        if base in ('rts', 'rte', 'rtr', 'illegal') or mn in ('bra', 'bra.b', 'bra.w', 'bra.s', 'jmp') or base == 'jmp' or base == 'bra':
            break
        pc += i.size

def lab(ad):
    if ad in names: return names[ad]
    if ad in insns: return f'L_{ad:06x}'
    return f'D_{ad:06x}'

out = sys.stdout
out.write(f'; rdis {a.ram} {LO:06x}-{HI:06x}: {len(insns)} instructions discovered\n')
ad = LO
while ad < HI:
    if ad in insns:
        if ad in targets or ad in names:
            xr = sorted(targets.get(ad, set()))
            xs = ' '.join(f'{x:06x}' for x in xr[:12]) + (' ...' if len(xr) > 12 else '')
            out.write(f'\n{lab(ad)}:' + (f'    ; <- {xs}' if xs else '') + (f'  ; {comments[ad]}' if ad in comments else '') + '\n')
        size, mn, op = insns[ad]
        def rep(m):
            v = int(m.group(1), 16)
            if v in names or (v in insns and v in targets): return lab(v) + (m.group(2) or '')
            return m.group(0)
        op2 = hexre.sub(rep, op)
        raw = mem[ad:ad + size].hex()
        c = f' ; {comments[ad]}' if (ad in comments and ad not in targets and ad not in names) else ''
        out.write(f'{ad:06x}  {raw:<20} {mn:<8} {op2}{c}\n')
        ad += size
    else:
        # data run until next insn
        end = ad
        while end < HI and end not in insns: end += 1
        p = ad
        while p < end:
            if p in data_refs or p in names:
                xr = sorted(data_refs.get(p, set()))
                xs = ' '.join(f'{x:06x}' for x in xr[:8]) + (' ...' if len(xr) > 8 else '')
                out.write(f'{lab(p)}:' + (f'    ; data <- {xs}' if xs else '') + (f'  ; {comments[p]}' if p in comments else '') + '\n')
            n = min(16, end - p)
            # break at next referenced address
            for q in range(p + 1, p + n):
                if q in data_refs or q in names: n = q - p; break
            chunk = mem[p:p + n]
            asc = ''.join(chr(c) if 32 <= c < 127 else '.' for c in chunk)
            out.write(f'{p:06x}  dc.b {",".join(f"${c:02x}" for c in chunk):<64} ; {asc}\n')
            p += n
        ad = end
