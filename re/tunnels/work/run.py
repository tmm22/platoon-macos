import subprocess, os, sys
ROOT='/Users/deborahmangan/Projects/Platoon'
EMU=ROOT+'/tools/amiga/emu'
def run(lines, frames, out, state=ROOT+'/re/states/tunnels_start.state', extra=[]):
    os.makedirs(out, exist_ok=True)
    sp=out+'/script.txt'
    open(sp,'w').write('\n'.join(lines)+'\n')
    cmd=[EMU,'--adf',ROOT+'/re/platoon_darc.adf','--script',sp,'--frames',str(frames),'--out',out]+extra
    if state: cmd+=['--load-state',state]
    r=subprocess.run(cmd,capture_output=True,text=True)
    return r.stdout+r.stderr
class S:
    def __init__(s,f=5): s.f=f; s.l=[]
    def add(s,c): s.l.append(f'{s.f} {c}')
    def hold(s,d,n):
        s.add(f'{d} 1'); s.f+=n; s.add(f'{d} 0'); s.f+=6
    def fwd(s,n=1): s.hold('up',8*n)
    def left(s): s.hold('left',6)
    def right(s): s.hold('right',6)
    def shot(s,name): s.add(f'shot {name}')
    def wait(s,n): s.f+=n
