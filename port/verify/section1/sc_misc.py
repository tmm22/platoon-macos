import sys; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
s=S()
# 1: room 0, guard not killed -> shoots us -> thrown out
s.go(7,3); s.face(1); s.F(); s.bx,s.by=7,3; s.wait(12); s.shot('g_in')
s.wait(36*4+300); s.shot('g_thrown_out')      # guard fires on the 36th tick; hit freeze ~110 frames
s.x,s.y=7,3                                  # ejected to the cell before the room, facing the room (E)
s.F(); s.wait(12); s.shot('g_reenter')
s.cross(35,40); s.hold('fire',10,60); s.shot('g_killed')
s.click(37,28,60); s.shot('g_map')           # map
s.leave(); s.wait(30)
s.face(1); s.F(); s.wait(20); s.shot('g_body_stays')
s.click(37,28,60); s.shot('g_map_again')
s.leave(); s.wait(30)
# 3: KIA with the map -> life 2 loses the map
s.poke('12de2','3',2)
s.sup=False; s.poke('3b237','1',1); s.wait(700); s.shot('kia_text')
s.hold('fire',6,200); s.shot('life2')
s.sup=True; s.poke('3b237','ff',1); s.wait(40)
# 4: morale low -> next hit -> withdrawn -> game over
s.poke('12e0c','c00',2); s.sup=False; s.poke('3b237','1',1); s.wait(700); s.shot('withdrawn_text')
s.hold('fire',6,400); s.shot('after_gameover')
s.save('/tmp/verify-section1/misc.txt'); print(s.f)
