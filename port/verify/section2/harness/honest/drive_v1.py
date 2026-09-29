# Closed-loop script generator: runs tools/amiga/emu from boot with the growing script, reads the state at every
# obj_player call ($179fa tickdump), replans where the actual state deviates from the prediction.
import sys, os, struct, subprocess
sys.path.insert(0, os.path.dirname(__file__))
from plan import *
EMU='/Users/deborahmangan/Projects/Platoon/tools/amiga/emu'
OUT=sys.argv[1]; ROUTE_ARG=sys.argv[2]; MAXIT=int(sys.argv[3]) if len(sys.argv)>3 else 200
os.makedirs(OUT, exist_ok=True)
BOOT=[(300,'fire 1'),(305,'fire 0'),(350,'poke 12e4c 2 2'),(600,'fire 1'),(605,'fire 0'),(900,'fire 1'),(905,'fire 0')]
EXTRA=[]   # extra fixed events (e.g. after the win)
inp={}     # frame -> joystick bits | 0x80 fire
def script_text(upto):
    ev=list(BOOT)+EXTRA
    prev=(0,0)
    for f in range(906, upto):
        v=inp.get(f,0)
        for bit,name in ((4,'up'),(1,'down'),(8,'left'),(2,'right'),(0x80,'fire')):
            if (v&bit)!=(prev[0]&bit) or f==906: ev.append((f,f'{name} {1 if v&bit else 0}'))
        prev=(v,0)
    ev.sort(key=lambda e:e[0])
    return ''.join(f'{f} {c}\n' for f,c in ev)
def run(frames):
    s=OUT+'/script.txt'; open(s,'w').write(script_text(frames))
    for f in ('pl.bin','rm.bin'):
        if os.path.exists(OUT+'/'+f): os.remove(OUT+'/'+f)
    subprocess.run([EMU,'--adf',ADF,'--frames',str(frames),'--script',s,'--out',OUT,'--deterministic',
        '--tickdump','179fa','57e22','270',OUT+'/pl.bin','--tickdump','179fa','18f1c','fc',OUT+'/rm.bin',
        '--bp','17c0a','--bp','17e96','--bp','17f18','--bp','17f04','--bp','1718a','--events',OUT+'/ev.txt'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    def recs(p,L):
        d=open(p,'rb').read(); n=len(d)//(4+L)
        return [(struct.unpack('<I',d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]
    A=recs(OUT+'/pl.bin',0x270); B=recs(OUT+'/rm.bin',0xfc)
    res=[]
    for (f,a),(_,b) in zip(A,B):
        x=struct.unpack('>h',a[2:4])[0]; y=struct.unpack('>h',a[4:6])[0]
        w=struct.unpack('>h',b[0xf6:0xf8])[0]; room=b[0]
        res.append(dict(f=f,x=x,y=y,w=w,room=room,barnes=a[0x48],slots=a,ammo=None))
    ev=open(OUT+'/ev.txt').read()
    return res, ev
route=ROUTE_ARG
def next_exit(visited_rooms_count):
    return route[visited_rooms_count] if visited_rooms_count < len(route) else None
# plan state
C=925; pred={}; startkey=None; plan_end=10**9; handled_sc=[]   # frame -> predicted (x,y,w,room)
leg=0            # index into route of the current room
cur_room=0x69
def make_plan(r):
    """returns list of joystick values for frames C.. and predicted states."""
    t=MAP[r['room']]
    if t==16:
        a=r['slots']; hp=a[0x48]
        infl=sum(1 for k in (10,11,12) if a[k*0x12] and a[k*0x12+0xa:k*0x12+0xe]==bytes.fromhex('0001833a'))
        acts=[]
        x,y,w=r['x'],r['y'],r['w']
        if hp==0:
            while y<0x5f: acts.append(U); x,y,w,_=step(x,y,w,U,0)
            acts += [0]*5
            return acts
        while y<20: acts.append(U); x,y,w,_=step(x,y,w,U,0)
        need=(hp+9)//10-infl
        for k in range(max(0,min(need,3-infl))): acts += [0x80,0x80,0,0]
        acts += [0]*15
        return acts
    want=route[leg] if leg<len(route) else 'L'
    p=plan(t,r['x'],r['y'],r['w'],want)
    if p is None: p=plan(t,r['x'],r['y'],r['w'],want,2,1)
    if p is None: raise SystemExit(f'no plan room {r["room"]} type {t} from {r}')
    # rifle: fire on/off every 2 ticks while deep in the room
    out=[]; x,y,w=r['x'],r['y'],r['w']
    for i,j in enumerate(p):
        fire=0x80 if (y>=56 and (i//2)%2==0) else 0
        out.append(j|fire); x,y,w,_=step(x,y,w,j,EXITS[t])
    return out + [(0x08 if want=='L' else 0x02)|0x04]*6      # keep pushing (exit after a doubled tick)
def predict(r, acts):
    t=MAP[r['room']]; x,y,w=r['x'],r['y'],r['w']; d={}
    for i,j in enumerate(acts):
        d[C+i]=(x,y,w,r['room'])
        x,y,w,ex=step(x,y,w,j&0x7f,EXITS[t])
        if ex: break
    return d
won=False
horizon=600
for it in range(MAXIT):
    recs, ev = run(C+horizon)
    if 'BP 017c0a' in ev: won=True; break
    # chain prediction from the plan-start record: s_{j+1} = step(s_j, input at frame of record j)
    dev=None; idx=None
    for j,r in enumerate(recs):
        if r['f']>C or (r['f']==C and startkey is None): idx=j; break
        if r['f']==C and (r['x'],r['y'],r['w'],r['room'])==startkey: idx=j; break
    if idx is None: print('no records after', C); horizon+=400; continue
    s=(recs[idx]['x'],recs[idx]['y'],recs[idx]['w'],recs[idx]['room'])
    if startkey is None or s!=startkey: dev=recs[idx]
    else:
        for j in range(idx+1,len(recs)):
            r=recs[j]; a=inp.get(recs[j-1]['f'],0)&0x7f
            x,y,w,ex=step(s[0],s[1],s[2],a,EXITS[MAP[s[3]]])
            s=(x,y,w,s[3])
            if ex or s!=(r['x'],r['y'],r['w'],r['room']) or r['f']>=plan_end: dev=r; break
    import re as _re
    ends=[int(m.group(1)) for m in _re.finditer(r'\[f(\d+) v\d+\] BP 01(718a|7f18|7f04)', ev)]
    if ends and (dev is None or ends[0]<=dev['f']): print('game ended at', ends[0], flush=True); break
    sc=[int(m.group(1)) for m in _re.finditer(r'\[f(\d+) v\d+\] BP 017e96', ev)]
    if len(sc)>len(handled_sc) and (dev is None or sc[len(handled_sc)]<=dev['f']):
        f0=sc[len(handled_sc)]; handled_sc.append(f0)
        for f in [f for f in inp if f>=f0]: del inp[f]
        for f in range(f0+150,f0+156): inp[f]=0x80
        C=f0+160; startkey=None; leg=-1; cur_room=None; plan_end=10**9
        print('second chance at', f0, flush=True); continue
    if dev is None: print('no deviation', C, len(recs)); horizon+=400; continue
    if 'BP 017e96' in ev and dev['room']==0x69 and cur_room!=0x69:
        pass
    if dev['room']!=cur_room:
        # new room: which leg?  restart (second chance) -> back to leg 0
        leg+=1
        cur_room=dev['room']
    C=dev['f']
    for f in [f for f in inp if f>=C]: del inp[f]
    acts=make_plan(dev)
    for i,a in enumerate(acts): inp[C+i]=a
    plan_end=C+len(acts) if MAP[dev['room']]==16 else 10**9
    pred=predict(dev,acts); startkey=(dev['x'],dev['y'],dev['w'],dev['room'])
    print(f'it{it} f{C} room {dev["room"]} type {MAP[dev["room"]]} leg {leg} pos ({dev["x"]},{dev["y"]},{dev["w"]}) barnes {dev["barnes"]} plan {len(acts)}', flush=True)
open(OUT+'/final_inputs.txt','w').write(script_text(C+horizon))
print('won' if won else 'not won', 'C', C)
