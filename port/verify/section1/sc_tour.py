import sys, json; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
R=json.load(open('/Users/deborahmangan/Projects/Platoon/re/tunnels/assets/rooms.json'))
def center(r): return ((r[0]+r[2])//2,(r[1]+r[3])//2)
def do_room(s,k,again=True,guard=False,tag=''):
    s.enter(k); s.shot(f'r{k}{tag}_in')
    if guard: s.cross(35,40); s.hold('fire',10,60)
    hs=R[k]['hotspots'][:-1]
    for i,h in enumerate(hs):
        x,y=center(h['rects_x1y1x2y2'][0]); s.click(x,y,70); s.shot(f'r{k}{tag}_h{i}')
    if again:
        for i,h in enumerate(hs):
            x,y=center(h['rects_x1y1x2y2'][0]); s.click(x,y,70); s.shot(f'r{k}{tag}_a{i}')
    s.leave(); s.wait(40)
def tour(upto=None):
    s=S(suppress=False)
    s.hold('fire',40,10)            # wasted shots in the corridor (ammo -10, sfx $82)
    s.wait(1250-s.f)                # first enemy hits us once (hits=1)
    s.sup=True; s.poke('3b237','ff',1)
    for k in [0,2,3,4,1,5,6,7,9,8]:
        do_room(s,k,guard=(k==0))
        if upto is not None and k==upto: return s
    s.enter(9); s.shot('r9b_in')
    x,y=center(R[9]['hotspots'][4]['rects_x1y1x2y2'][0]); s.click(x,y,10); s.shot('exit_click')
    return s
if __name__=='__main__':
    s=tour(); s.wait(700)
    s.save('/tmp/verify-section1/tour.txt'); print(s.f)
