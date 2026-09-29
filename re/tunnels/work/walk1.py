from run import *
s=S()
for i in range(0,3000,200): s.l.append(f'{i+1} poke 3b237 ff 1')
s.shot('p00')
seq=['F']*10+['L']+['F']*4+['R']+['F']*8+['R']+['F']*4+['R']+['F']*5
for i,c in enumerate(seq):
    if c=='F': s.fwd()
    elif c=='L': s.left()
    else: s.right()
    s.wait(4)
    s.shot('p%02d'%(i+1))
s.wait(40); s.shot('room'); s.add('dump room0.bin')
s.add('save /Users/deborahmangan/Projects/Platoon/re/states/tunnels_room0.state')
s.l.sort(key=lambda x:int(x.split()[0]))
print(run(s.l, s.f+10, 'o5')[-300:])
