import sys; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
s=S()
s.go(7,3,shots='w'); s.face(1); s.F(); s.bx,s.by=7,3; s.wait(20); s.shot('room0_in')
# kill guard: crosshair onto box, fire 2 ticks
s.cross(35,40); s.hold('fire',10,30); s.shot('guard_dead')
s.wait(40)
# hotspots of type 0: map, poetry, flares, documents, tea, empty, boots
for i,(x,y) in enumerate([(28,19),(19,63),(17,84),(59,84),(41,70),(61,58),(108,70)]):
    s.click(x,y,60); s.shot(f'item{i}')
# again: taken items
for i,(x,y) in enumerate([(28,19),(17,84),(59,84)]):
    s.click(x,y,60); s.shot(f'again{i}')
s.leave(); s.wait(30); s.shot('left')
s.save('/tmp/verify-section1/room0.txt'); print(s.f)
