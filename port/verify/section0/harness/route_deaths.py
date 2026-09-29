import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
P = plan.Planner('deaths', start_events=[], start_frame=850)
# 1: idle until shot -> choose screen, keep the same man
P.leg_wait('ms', lambda t: True, [(10, 'fire 1'), (16, 'fire 0')], label='death 1 -> choose, FIRE (same man)')
P.leg(lambda t: t['pst'] == 0, [], label='  playing')
# 2: Left-Alt voluntary change while no enemy on screen: choose man 2 (DOWN), fire
P.leg(lambda t: t['est'] == 0 and t['pst'] == 0, [(0, 'key 0x64 1'), (6, 'key 0x64 0')], label='Left-Alt')
P.leg_wait('ms', lambda t: True, [(10, 'down 1'), (16, 'down 0'), (30, 'fire 1'), (36, 'fire 0')], label='  choose: DOWN, FIRE (man 2)')
P.leg(lambda t: t['pst'] == 0 and t['man'] == 1, [], label='  playing as man 2')
# 3: next death: DOWN twice then UP once -> man 3
P.leg_wait('ms', lambda t: True, [(10, 'down 1'), (16, 'down 0'), (30, 'down 1'), (36, 'down 0'), (50, 'up 1'), (56, 'up 0'),
                                  (70, 'fire 1'), (76, 'fire 0')], label='death 2 -> DOWN DOWN UP FIRE')
P.leg(lambda t: t['pst'] == 0, [(0, 'poke 12de2 3 2')], label='  playing; poke man 0 hits = 3')
# 4: select man 1 (hits 3) via Left-Alt, die -> KIA -> auto first living man
P.leg(lambda t: t['est'] == 0 and t['pst'] == 0, [(0, 'key 0x64 1'), (6, 'key 0x64 0')], label='Left-Alt 2')
P.leg_wait('ms', lambda t: True, [(10, 'up 1'), (16, 'up 0'), (30, 'up 1'), (36, 'up 0'), (50, 'up 1'), (56, 'up 0'),
                                  (70, 'fire 1'), (76, 'fire 0')], label='  choose: UP x3 -> man 1, FIRE')
P.leg(lambda t: t['pst'] == 0 and t['man'] == 0, [], label='  playing as man 1 (hits 3)')
P.leg_wait('ms', lambda t: True, [(10, 'up 1'), (16, 'up 0'), (30, 'fire 1'), (36, 'fire 0')], label='death 3 (man 1 KIA) -> UP (blocked), FIRE')
P.leg(lambda t: t['pst'] == 0, [(0, 'poke 12de8 4 2'), (0, 'poke 12dee 4 2'), (0, 'poke 12df4 4 2'), (0, 'poke 12dfa 3 2')],
      label='  playing; poke men 2-4 KIA, man 5 hits 3')
P.save()
# 5: death -> KIA -> only man 5 left
P.leg_wait('ms', lambda t: True, [(10, 'up 1'), (16, 'up 0'), (30, 'fire 1'), (36, 'fire 0')], label='death 4 -> only man 5 left')
P.leg(lambda t: t['pst'] == 0, [], label='  playing as man 5 (hits 3)')
# 6: death -> whole platoon dead -> game over
P.leg(lambda t: t['pst'] == 8, [], maxf=4000, label='  man 5 hit (last man)')
P.ev(1500, 'fire 1'); P.ev(1506, 'fire 0')
P.save()
