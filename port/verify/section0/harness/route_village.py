import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
P = plan.Planner('village_route', start_events=[(820, 'poke 12e4e 1 2'), (822, 'poke 60ca0 ff 1'), (830, 'key 0x53 1'),
                 (836, 'key 0x53 0'), (842, 'poke 12e4e 0 2')], start_frame=850)
P.leg(lambda t: t['lvl'] == 0 and t['pst'] == 0 and t['T'] == 0x41, [], label='warped to village (F4)')

def door(col, dirn):
    P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['lvl'] == 0 and t['pst'] == 0 and t['col'] == col and t['c34'] == 0 and t['align'] == 0,
          [(0, f'{dirn} 0'), (0, 'up 1'), (10, 'up 0')], maxf=4000, label=f'door col {col:#x}')
    P.leg(lambda t: t['pst'] == 5, [], label='  inside')

def search(c30, dirn=None, again=False):
    if dirn: P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['pst'] == 5 and t['c30'] == c30 and t['align'] == 0,
          ([(0, f'{dirn} 0')] if dirn else []) + [(0, 'up 1'), (6, 'up 0')] + ([(10, 'up 1'), (16, 'up 0')] if again else []),
          label=f'  search at {c30:#x}')
    P.leg(lambda t: t['pst'] in (5, 0) and t['msgs'] >= 0, [], after=24, label='  searched')

def leave(c30, dirn=None):
    if dirn: P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['pst'] == 5 and t['c30'] == c30 and t['align'] == 0 and t['c34'] == 0,
          ([(0, f'{dirn} 0')] if dirn else []) + [(0, 'down 1'), (8, 'down 0')], label=f'  leave at {c30:#x}')
    P.leg(lambda t: t['pst'] == 0 and t['lvl'] == 0, [], label='  outside')

# hut 3 (door $42, c30 $214): rubbish $20c, flour $20e, rice $210/$212
door(0x42, 'left')
search(0x212, 'left'); search(0x210, 'left'); search(0x20e, 'left'); search(0x20c, 'left')
leave(0x214, 'right')
# hut 2 (door $3c, c30 $1e4): VC guard, shoot him, stool $1e8, map $1ec
door(0x3c, 'left')
P.ev(0, 'right 1')
P.leg(lambda t: t['fac'] == 0, [(0, 'right 0'), (0, 'fire 1'), (6, 'fire 0')], label='  turned right, fire')
P.leg(lambda t: t['hk'] != 0, [], label='  guard killed')
search(0x1e8, 'right'); search(0x1ec, 'right'); search(0x1ee, 'right')
leave(0x1e4, 'left')
P.save()
# hut 1 (door $37, c30 $1bc): rubbish $1b4, rice $1b6, stool $1ba, empty $1c0, trap door at T=$35
door(0x37, 'left')
search(0x1ba, 'left'); search(0x1b6, 'left'); search(0x1b4, 'left')
search(0x1c0, 'right')
P.ev(0, 'right 1')
P.leg(lambda t: t['T'] == 0x35 and t['c34'] == 0 and t['align'] == 0, [(0, 'right 0'), (40, 'key 0x36 1'), (46, 'key 0x36 0')],
      label='  trap door prompt, answer N')
P.leg(lambda t: t['pst'] == 5, [(20, 'right 1')], after=60, label='  back from N')
P.leg(lambda t: t['T'] == 0x35 and t['c34'] == 0 and t['align'] == 0 and t['fac'] == 0, [(0, 'right 0'), (40, 'key 0x15 1'), (46, 'key 0x15 0')],
      label='  trap door prompt again, answer Y without torch')
P.leg(lambda t: t['pst'] == 5, [], after=60, label='  back from Y')
leave(0x1bc, 'left')
P.save()
# hut 0 (door $31, c30 $18c): booby trap $190, torch $194
door(0x31, 'left')
search(0x190, 'right'); search(0x190, None); search(0x194, 'right', again=True)
leave(0x18c, 'left')
P.save()
# hut 4 (door $49, c30 $24c): provisions $23c, booby trap/water $23e, table $242.., stool $248
door(0x49, 'right')
search(0x248, 'left'); search(0x246, 'left'); search(0x244, 'left'); search(0x242, 'left'); search(0x240, 'left')
search(0x23e, 'left'); search(0x23e, None); search(0x23c, 'left')
leave(0x24c, 'right')
# hut 5 (door $4d, c30 $26c): flour $270, stool $272, $276
door(0x4d, 'right')
search(0x270, 'right'); search(0x272, 'right'); search(0x274, 'right'); search(0x276, 'right')
leave(0x26c, 'left')
P.save()
# back to hut 1 with the torch: trap door, Y
door(0x37, 'left')
P.ev(0, 'right 1')
P.leg(lambda t: t['T'] == 0x35 and t['c34'] == 0 and t['align'] == 0 and t['fac'] == 0, [(0, 'right 0'), (40, 'key 0x15 1'), (46, 'key 0x15 0')],
      label='  trap door prompt with torch, answer Y')
P.save()
