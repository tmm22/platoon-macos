import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
ev = []
for l in open('/tmp/verify-section0/sc/jungle_route.txt'):
    p = l.split(); ev.append((int(p[0]), ' '.join(p[1:])))
ev.append((8074, 'poke 60ca0 0 2'))     # invincibility off: with it on, bridge_blow's player_hit is skipped -> state 10 forever
P = plan.Planner('jungle_route3', start_events=ev, start_frame=8076)
P.leg(lambda t: t['bridge'] == 2, [], label='BRIDGE BLOWN')
P.leg(lambda t: t['pst'] == 0, [(0, 'poke 60ca0 ff 1')], label='knock-back over (no damage), invincible again')
P.ev(0, 'left 1')
P.leg(lambda t: t['c30'] == 0x246 and t['msgs'] > 0, [(30, 'left 0')], label='suicide guard at $246')
P.save()
P.go(1, 84, 'right', 'up')
P.save()
