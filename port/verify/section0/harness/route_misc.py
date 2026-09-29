import sys; sys.path.insert(0, '/tmp/verify-section0')
import plan
P = plan.Planner('misc', start_events=[(820, 'poke 60ca0 ff 1')], start_frame=830)
def front(t):
    return (t['fac'] == 1 and 0 < t['ex'] < 0x94) or (t['fac'] == 0 and 0x94 < t['ex'] < 0x130)
# A: at the start (level 1, boxed in): crouch, crouch-fire, jump, jump+right, grenade throws
P.ev(0, 'down 1'); P.ev(10, 'fire 1'); P.ev(20, 'fire 0'); P.ev(24, 'down 0')
P.ev(30, 'up 1'); P.ev(36, 'up 0'); P.ev(70, 'right 1'); P.ev(72, 'up 1'); P.ev(78, 'up 0'); P.ev(110, 'right 0')
P.ev(120, 'key 0x40 1'); P.ev(126, 'key 0x40 0')
P.leg(lambda t: t['pst'] == 0 and t['grenade'] == 0, [], after=140, label='A: crouch, jump, grenade')
P.ev(0, 'left 1'); P.ev(4, 'left 0'); P.ev(10, 'key 0x40 1'); P.ev(16, 'key 0x40 0')
P.leg(lambda t: t['pst'] == 0 and t['grenade'] == 0, [], after=40, label='  grenade left')
# grenades at enemies on level 2 (spider-hole VC can only be killed by grenades)
P.go(1, 13, 'right', 'down')
kills = [0]
for i in range(14):
    h = P.leg(lambda t: t['pst'] == 0 and t['grenade'] == 0 and ((t['est'] == 5) or (t['est'] == 2 and front(t))),
              [(0, 'key 0x40 1'), (6, 'key 0x40 0')], maxf=3000, label=f'  grenade at enemy state')
    P.leg(lambda t: t['grenade'] == 0 and t['pst'] == 0, [], after=10, label='  grenade done')
    if i % 3 == 2:
        P.ev(0, 'right 1'); P.ev(40, 'right 0')
P.save()
# B: bridge via F3 with explosives poked, blow, F3 again (bridge stays blown), suicide guard from the left ($238)
P.ev(0, 'poke 12e4e 1 2'); P.ev(10, 'key 0x52 1'); P.ev(16, 'key 0x52 0'); P.ev(20, 'poke 12e4e 0 2')
P.leg(lambda t: t['lvl'] == 1 and t['T'] == 0x41 and t['pst'] == 0, [(0, 'poke 12e06 ff00 2'), (0, 'right 1')], label='B: F3, explosives poked')
P.leg(lambda t: t['pst'] == 10, [(0, 'right 0'), (0, 'poke 60ca0 0 2')], label='  planted')
P.leg(lambda t: t['bridge'] == 2 and t['pst'] == 0, [(0, 'poke 60ca0 ff 1')], label='  blown, knock-back over')
P.ev(0, 'poke 12e4e 1 2'); P.ev(10, 'key 0x52 1'); P.ev(16, 'key 0x52 0'); P.ev(20, 'poke 12e4e 0 2')
P.leg(lambda t: t['lvl'] == 1 and t['T'] == 0x41 and t['pst'] == 0, [(0, 'right 1')], label='  F3 again (west of the gap)')
P.leg(lambda t: t['c30'] == 0x238 and t['msgs'] > 0, [(40, 'right 0')], label='  suicide guard at $238')
P.save()
# C: F4 to the village with the bridge blown: shoot soldiers (not villagers) -> supply crates, pick them up
P.ev(0, 'poke 12e4e 1 2'); P.ev(10, 'key 0x53 1'); P.ev(16, 'key 0x53 0'); P.ev(20, 'poke 12e4e 0 2')
P.leg(lambda t: t['lvl'] == 0 and t['T'] == 0x41 and t['pst'] == 0, [], label='C: F4 village, bridge blown')
for i in range(40):
    h = P.leg(lambda t: t['pst'] == 0 and ((t['est'] == 2 and t['vil'] == 0 and front(t)) or t['crate'] != 0), [], maxf=3000,
              label='  enemy or crate')
    if h['crate']:
        cx = None
        d = 'right' if h['fac'] == 0 else 'left'
        P.ev(0, f'{d} 1')
        P.leg(lambda t: t['crate'] == 0, [(0, f'{d} 0')], label=f'  walked {d} onto the crate')
    else:
        P.ev(0, 'fire 1'); P.ev(8, 'fire 0')
        P.leg(lambda t: t['est'] != 2, [], label='  shot')
    if i % 6 == 5:
        P.ev(0, 'left 1'); P.ev(0, 'left 0')
P.save()
# D: level 0 col $54 down-path back to level 1
P.go(0, 0x54, 'right', 'down')
P.save()
