import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
ev = []
for l in open('/tmp/verify-section0/sc/jungle_route3.txt'):
    p = l.split(); ev.append((int(p[0]), ' '.join(p[1:])))
P = plan.Planner('honest_village', start_events=ev, start_frame=8942)
state = dict(vk=0, crates=0)
def front(t):
    return (t['fac'] == 1 and 0 < t['ex'] < 0x94) or (t['fac'] == 0 and 0x94 < t['ex'] < 0x130)
def sweep(dirn, stopcol, want_villager):
    P.ev(0, f'{dirn} 1')
    while True:
        def cond(t):
            if t['lvl'] != 0 or t['pst'] != 0: return False
            if (dirn == 'left' and t['col'] <= stopcol) or (dirn == 'right' and t['col'] >= stopcol): return True
            if t['est'] == 2 and front(t) and (t['vil'] == 0 or want_villager[0]): return True
            return False
        h = P.leg(cond, [(0, 'fire 1'), (14, 'fire 0')], maxf=2500, label=f'  sweep {dirn}')
        if (dirn == 'left' and h['col'] <= stopcol) or (dirn == 'right' and h['col'] >= stopcol):
            P.ev(0, 'fire 0'); P.ev(0, f'{dirn} 0'); return
        if h['vil']: want_villager[0] = False
wv = [True]
sweep('left', 0x33, wv)
sweep('right', 0x52, wv)
sweep('left', 0x3e, wv)
P.save()
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
    P.leg(lambda t: t['pst'] in (5, 0), [], after=24, label='  searched')
def leave(c30, dirn=None):
    if dirn: P.ev(0, f'{dirn} 1')
    P.leg(lambda t: t['pst'] == 5 and t['c30'] == c30 and t['align'] == 0 and t['c34'] == 0,
          ([(0, f'{dirn} 0')] if dirn else []) + [(0, 'down 1'), (8, 'down 0')], label=f'  leave at {c30:#x}')
    P.leg(lambda t: t['pst'] == 0 and t['lvl'] == 0, [], label='  outside')
# hut 2: guard + map
door(0x3c, 'left')
P.ev(0, 'right 1')
P.leg(lambda t: t['fac'] == 0, [(0, 'right 0'), (0, 'fire 1'), (6, 'fire 0')], label='  turned right, fire')
P.leg(lambda t: t['hk'] != 0, [], label='  guard killed')
search(0x1ec, 'right')
leave(0x1e4, 'left')
# hut 0: torch
door(0x31, 'left')
search(0x194, 'right')
leave(0x18c, 'left')
P.save()
# hut 1: trap door with torch -> Y -> section 1
door(0x37, 'right')
P.ev(0, 'right 1')
P.leg(lambda t: t['T'] == 0x35 and t['c34'] == 0 and t['align'] == 0 and t['fac'] == 0, [(0, 'right 0'), (40, 'key 0x15 1'), (46, 'key 0x15 0')],
      label='  trap door prompt with torch, answer Y')
P.ev(400, 'fire 1'); P.ev(410, 'fire 0')
P.save()
