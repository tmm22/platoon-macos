import sys; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
s=S()
s.wait(20); s.poke('1a0b0','271f',2); s.poke('12e08','0',2); s.x,s.y,s.d=39,31,0; s.wait(12)
s.F(); s.bx,s.by=39,31; s.wait(20); s.shot('x_in')
s.click(116,36,150); s.shot('x_noflares')          # EXIT hotspot (106,0)-(126,73): "YOU WILL NEED SOME FLARES."
s.poke('12e0a','6',2); s.wait(8); s.click(116,36,150); s.shot('x_moreflares')
s.poke('12e0a','8',2); s.wait(8); s.click(116,36,10); s.shot('x_go')
s.wait(200); s.poke('12e0c','c00',2)                # morale low during the flare intro
s.wait(1200); s.shot('fl_withdrawn'); s.hold('fire',6,400); s.shot('fl_gameover')
s.save('/tmp/verify-section1/exit.txt'); print(s.f)
