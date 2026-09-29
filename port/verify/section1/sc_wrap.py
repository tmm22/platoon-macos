import sys; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
s=S()
s.go(7,3); s.face(1); s.F(); s.bx,s.by=7,3; s.wait(20)
s.cross(35,40); s.hold('fire',10,60)                 # kill guard
s.poke('12e0c','fe00',2); s.wait(8)
s.click(67,86,200); s.shot('wrap_after')            # SECRET DOCUMENTS: morale +$200 wraps to 0 -> withdrawn
s.hold('fire',6,300); s.shot('wrap_gameover')
s.save('/tmp/verify-section1/wrap.txt'); print(s.f)
