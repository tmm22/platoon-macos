import sys; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
s=S()
s.hold('down',20); s.shot('h_down')                 # down does nothing in corridor mode
s.face(0); s.F(); s.shot('h_wall')                 # facing N at (21,3): wall -> blocked (position unchanged)
s.y+=1                                             # undo generator's position update (blocked)
s.face(3)
s.go(7,11); s.face(0); s.F(); s.bx,s.by=7,11; s.wait(20); s.shot('h_room2')
# honest cursor: joystick moves (in_room acceleration), clicks where it lands
for i,(d,n) in enumerate([('up',48),('left',36),('left',1),('right',40),('down',12),('left',40)]):
    s.hold(d,n,4); s.hold('fire',6,30); s.shot(f'h_click{i}')
s.leave(); s.wait(10)
s.hold('fire',12,6); s.shot('h_fire_after_leave')  # fire latch after leaving: no wasted shot until released
s.hold('fire',12,6); s.shot('h_fire_again')        # now wastes shots
s.save('/tmp/verify-section1/honest.txt'); print(s.f)
