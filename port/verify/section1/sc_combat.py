import sys; sys.path.insert(0,'/tmp/verify-section1')
from gen import *
def al(s):
    while s.f%4!=2: s.f+=1
def tele(s,x,y,d,spawn=True):
    al(s); s.poke('1a0b0','%02x%02x'%(x,y),2); s.poke('12e08',str(d),2)
    if spawn: s.poke('3b237','1',1)
    s.x,s.y,s.d=x,y,d
def build(stage=99):
    s=S(suppress=False)
    s.f=936; s.hold('up',32,0); s.hold('left',8,0); s.cross(70,40); s.hold('fire',12,0); s.shot('A_fired'); s.wait(80); s.shot('A_dead')
    s.sup=True; s.poke('3b237','ff',1); s.wait(40)
    if stage<=1: return s
    # B: left side enemy at (17,3) W, honest walk
    s.F(); s.F(); s.F(); s.F(); s.wait(8); al(s); s.poke('3b237','1',1); s.wait(12); s.shot('B_spawn')
    s.cross(40,55); s.hold('fire',12,0); s.wait(80); s.shot('B_dead'); s.sup=True; s.poke('3b237','ff',1); s.wait(20)
    if stage<=2: return s
    # C: right side enemy
    tele(s,13,3,1); s.wait(12); s.shot('C_spawn'); s.cross(110,55); s.hold('fire',12,0); s.wait(80); s.shot('C_dead')
    s.poke('3b237','ff',1); s.wait(20)
    if stage<=3: return s
    # D: water enemy, honest aim (up 5 ticks)
    tele(s,5,3,3); s.wait(6); s.shot('D_spawn'); s.hold('up',20,0); s.hold('fire',12,0); s.wait(80); s.shot('D_dead')
    s.poke('3b237','ff',1); s.wait(20)
    if stage<=4: return s
    # E: far enemy fires, then killed: its shot still hits; a new enemy spawned meanwhile is erased by the shot
    tele(s,21,3,3); S0=s.f+1
    s.f=S0+86; s.cross(70,40); s.f=S0+90; s.hold('fire',5,0); s.shot('E_killed_after_fire')
    s.f=S0+152; s.poke('3b237','1',1); s.f=S0+164; s.shot('E_new_enemy'); s.f=S0+168; s.shot('E_erased')
    s.f=S0+290; s.shot('E_after_hit'); s.poke('3b237','ff',1); s.wait(20)
    if stage<=5: return s
    # F: side enemy (left) hits us
    tele(s,17,3,3); s.wait(260); s.shot('F_after_hit'); s.poke('3b237','ff',1); s.wait(20)
    # G: water enemy hits us
    tele(s,5,3,3); s.wait(200); s.shot('G_after_hit'); s.poke('3b237','ff',1); s.wait(20)
    if stage<=7: return s
    # H: ammo 1 -> last bullet cannot kill; then ammo 0 -> no shot
    tele(s,21,3,3); s.wait(8); s.poke('12de0','1',2); s.cross(70,40); s.hold('fire',16,0); s.shot('H_ammo0')
    s.cross(70,40); s.hold('fire',16,0); s.wait(300); s.shot('H_after')
    s.f=3000; s.shot('KIA_text'); s.hold('fire',6,300); s.shot('man2')
    return s
if __name__=='__main__':
    st=int(sys.argv[1]) if len(sys.argv)>1 else 99
    s=build(st); s.wait(200); s.save('/tmp/verify-section1/combat.txt'); print(s.f)
