#!/usr/bin/env python3
"""Generates the name-entry script (section 0 game over via morale poke, two entries). Usage: mk_hs.py OUT [T2]
T2 = frame of the second game's fire press (after the first entry returned to the title)."""
import sys
out = sys.argv[1]; t2 = int(sys.argv[2]) if len(sys.argv) > 2 else None
L = ["300 fire 1", "305 fire 0", "900 poke 12e2c 00012345 4", "900 poke 12e0c 0001 2"]
t = 1100
def inp(*dirs, dur=6, gap=14):
    global t
    for d in dirs: L.append(f"{t} {d} 1")
    for d in dirs: L.append(f"{t+dur} {d} 0")
    L.append(f"{t+dur-1} shot ne{t:05d}")
    t += dur + gap
inp('left'); inp('left'); inp('fire')                 # DEL glyph at position 0 -> no-op
for _ in range(4): inp('right')                       # $5d -> $41 'A'
inp('fire')
for _ in range(3): inp('right')                       # '_' -> '@' 'A' 'B'
inp('fire')
inp('left'); inp('left'); inp('fire')                 # pos2 DEL -> back to pos1
inp('left'); inp('fire')                              # pos1 'B' -> 'A', accept
inp('left', 'right'); inp('up'); inp('down')          # ignored inputs
inp('left'); inp('fire')                              # END glyph -> rest spaces
L.append(f"{t+100} shot tbl1")
if t2:
    L += [f"{t2} fire 1", f"{t2+5} fire 0", f"{t2+600} poke 12e2c 00010000 4", f"{t2+600} poke 12e0c 0001 2"]
    t = t2 + 800
    for _ in range(16): inp('fire')                   # accept the pre-filled name (quirk)
    L.append(f"{t+100} shot tbl2")
    L.append(f"{t+700} shot title2")
open(out, 'w').write("\n".join(L) + "\n")
print("last input frame", t)
