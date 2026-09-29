import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
ev = []
for l in open('/tmp/verify-section0/sc/jungle_route_part1.txt'):
    p = l.split(); ev.append((int(p[0]), ' '.join(p[1:])))
P = plan.Planner('jungle_route', start_events=ev, start_frame=7710)
def go(l, c, d, v): P.go(l, c, d, v)
P.leg(lambda t: t['lvl'] == 2 and t['pst'] == 0, [(0, 'fire 0')], label='  arrived L2')
go(2, 68, 'left', 'up')
P.save()
P.ev(0, 'right 1')
P.leg(lambda t: t['pst'] == 10, [(0, 'right 0')], label='PLANT (state 10)')
P.leg(lambda t: t['bridge'] == 2, [], label='BRIDGE BLOWN')
P.leg(lambda t: t['pst'] == 0, [], label='knock-back over')
go(1, 84, 'right', 'up')
P.save()
