import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
P = plan.Planner('doom', start_events=[(820, 'poke 12e4e 1 2'), (830, 'key 0x52 1'), (836, 'key 0x52 0'), (842, 'poke 12e4e 0 2')],
                 start_frame=850)
P.leg(lambda t: t['lvl'] == 1 and t['T'] == 0x41 and t['pst'] == 0, [(0, 'right 1')], label='F3 warp: level 1 x $41, walk right')
P.leg(lambda t: t['pst'] == 9, [(0, 'right 0')], maxf=3000, label='doomed (state 9) at col >= $4e without explosives')
P.leg(lambda t: t['est'] == 8, [], label='bridge runner (enemy state 8)')
P.leg_wait('wf', lambda t: True, [(60, 'fire 1'), (66, 'fire 0')], label='YOU DIDNT BLOW UP THE BRIDGE -> wait fire')
P.ev(700, 'fire 0')
P.save()
