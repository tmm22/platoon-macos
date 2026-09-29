import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
P = plan.Planner('dummy', start_events=[(820, 'poke 12e4e 1 2'), (822, 'poke 60ca0 ff 1'), (830, 'key 0x53 1'),
                 (836, 'key 0x53 0'), (842, 'poke 12e4e 0 2')], start_frame=850)
P.leg(lambda t: t['lvl'] == 0 and t['pst'] == 0 and t['T'] == 0x41, [], label='warped to village (F4)')
# input combinations in the street: RIGHT+SPACE (no grenade -> fire check), UP+DOWN, LEFT+RIGHT
P.ev(0, 'right 1'); P.ev(0, 'key 0x40 1'); P.ev(20, 'key 0x40 0'); P.ev(24, 'right 0')
P.ev(30, 'up 1'); P.ev(30, 'down 1'); P.ev(50, 'up 0'); P.ev(50, 'down 0')
P.ev(60, 'left 1'); P.ev(60, 'right 1'); P.ev(80, 'left 0'); P.ev(80, 'right 0')
P.leg(lambda t: t['pst'] == 0, [], after=90, label='input combinations')
def door(col, dirn):
    P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['lvl'] == 0 and t['pst'] == 0 and t['col'] == col and t['c34'] == 0 and t['align'] == 0,
          [(0, f'{dirn} 0'), (0, 'up 1'), (10, 'up 0')], maxf=4000, label=f'door col {col:#x}')
    P.leg(lambda t: t['pst'] == 5, [], label='  inside')
def leave(c30, dirn=None):
    if dirn: P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['pst'] == 5 and t['c30'] == c30 and t['align'] == 0 and t['c34'] == 0,
          ([(0, f'{dirn} 0')] if dirn else []) + [(0, 'down 1'), (8, 'down 0')], label=f'  leave at {c30:#x}')
    P.leg(lambda t: t['pst'] == 0 and t['lvl'] == 0, [], label='  outside')
def search(c30, dirn=None):
    if dirn: P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['pst'] == 5 and t['c30'] == c30 and t['align'] == 0,
          ([(0, f'{dirn} 0')] if dirn else []) + [(0, 'up 1'), (6, 'up 0')], label=f'  search at {c30:#x}')
    P.leg(lambda t: t['pst'] == 5, [], after=24, label='  searched')
# hut 1: Left-Alt ignored (dummy enemy state 4), the dummy quirk (stale enemy x) -> hut-2 guard "dead"
door(0x37, 'left')
P.ev(0, 'key 0x64 1'); P.ev(6, 'key 0x64 0'); P.ev(10, 'poke 5f88a 9c 2'); P.ev(12, 'right 1')
P.leg(lambda t: t['fac'] == 0, [(0, 'right 0'), (0, 'fire 1'), (6, 'fire 0')], label='  Alt ignored; dummy x := $9c; turned right, fire')
P.leg(lambda t: t['hk'] != 0, [], label='  dummy killed -> hut-2 guard flag set')
leave(0x1bc, 'left')
# hut 2: guard is a body; take the map
door(0x3c, 'right')
search(0x1ec, 'right')
leave(0x1e4, 'left')
# hut 0: choose man 3 with Left-Alt, torch
door(0x31, 'left')
P.leg(lambda t: t['pst'] == 5, [(4, 'key 0x64 1'), (10, 'key 0x64 0')], label='  Left-Alt in hut 0')
P.leg_wait('ms', lambda t: True, [(10, 'down 1'), (16, 'down 0'), (30, 'down 1'), (36, 'down 0'), (50, 'fire 1'), (56, 'fire 0')],
           label='  choose man 3')
P.leg(lambda t: t['pst'] == 5 and t['man'] == 2, [], label='  back in hut 0 as man 3')
search(0x194, 'right')
leave(0x18c, 'left')
P.save()
# hut 1: trap door Y with man 3 (bonus loop starts at the current man)
door(0x37, 'right')
P.ev(0, 'right 1')
P.leg(lambda t: t['T'] == 0x35 and t['c34'] == 0 and t['align'] == 0 and t['fac'] == 0, [(0, 'right 0'), (40, 'key 0x15 1'), (46, 'key 0x15 0')],
      label='  trap door prompt with torch, answer Y')
P.ev(400, 'fire 1'); P.ev(410, 'fire 0')
P.save()
