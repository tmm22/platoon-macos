#!/usr/bin/env python3
"""Incremental route planner on tools/amiga/emu (--deterministic) using save states.
Builds an absolute-frame emulator script (boot + events) leg by leg.  Script frames after --load-state are relative
to the state's frame; held inputs are preserved in the state."""
import struct, subprocess, os, sys
E = '/Users/deborahmangan/Projects/Platoon/tools/amiga/emu'
ADF = '/Users/deborahmangan/Projects/Platoon/re/platoon_port.adf'
BOOT = ['300 fire 1', '305 fire 0', '350 poke 12e4c 0 2', '600 fire 1', '605 fire 0']
W0 = '/tmp/verify-section0/plan'
w16 = lambda d, o: struct.unpack('>H', d[o:o+2])[0]

def recs(p, L):
    if not os.path.exists(p): return []
    d = open(p, 'rb').read(); n = len(d) // (4 + L)
    return [(struct.unpack('<I', d[i*(4+L):i*(4+L)+4])[0], d[i*(4+L)+4:(i+1)*(4+L)]) for i in range(n)]

def s16(v): return v - 0x10000 if v & 0x8000 else v

class Planner:
    def __init__(self, name, start_events=(), start_frame=812):
        global W
        W = f'{W0}/{name}'; os.makedirs(W, exist_ok=True)
        self.name = name
        self.events = []          # (absolute frame, cmd)
        self.state = None; self.F = 0
        # make the initial state at start_frame from boot
        for f, c in start_events: self.events.append((f, c))
        self._run(None, 0, start_frame + 2, [(f, c) for f, c in self.events if f < start_frame] , save_at=start_frame)
        self.state = f'{W}/{name}_{start_frame}.state'; self.F = start_frame
        self.events = [e for e in self.events]
        self.pending = [(f, c) for f, c in self.events if f >= start_frame]

    def _run(self, state, F, frames, evs, save_at=None, tick=True):
        scr = [] if state else list(BOOT)
        for f, c in sorted(evs, key=lambda x: x[0]):
            scr.append(f'{f - F} {c}')
        if save_at is not None:
            scr.append(f'{save_at - F} save {W}/{self.name}_{save_at}.state')
        scr.sort(key=lambda l: int(l.split()[0]))
        open(f'{W}/scr.txt', 'w').write('\n'.join(scr) + '\n')
        for n in 'abcstw':
            if os.path.exists(f'{W}/t_{n}.bin'): os.remove(f'{W}/t_{n}.bin')
        cmd = [E, '--adf', ADF, '--frames', str(frames), '--script', f'{W}/scr.txt', '--out', W, '--deterministic',
               '--tickdump', '17186', '5f880', '1c', f'{W}/t_a.bin', '--tickdump', '17186', '60c24', 'a0', f'{W}/t_b.bin',
               '--tickdump', '17186', '12dde', '78', f'{W}/t_c.bin', '--tickdump', '19772', '12dde', '78', f'{W}/t_s.bin',
               '--tickdump', '17dae', '12dde', '78', f'{W}/t_t.bin', '--tickdump', '1986c', '12dde', '78', f'{W}/t_w.bin']
        if state: cmd += ['--load-state', state]
        subprocess.run(cmd, capture_output=True)
        A = recs(f'{W}/t_a.bin', 0x1c); B = recs(f'{W}/t_b.bin', 0xa0); C = recs(f'{W}/t_c.bin', 0x78)
        out = []
        for (f, a), (_, b), (_, c) in zip(A, B, C):
            out.append(dict(f=f, pst=w16(a, 0x1a), pfr=w16(a, 4), y=w16(a, 2), fac=w16(a, 6), est=w16(a, 8), ex=w16(a, 0xa),
                            efr=w16(a, 0xe), vil=a[0x18], T=w16(b, 0), lvl=w16(b, 2), col=w16(b, 4), c34=s16(w16(b, 0x10)),
                            c30=w16(b, 0xc), align=w16(b, 0xe), hut=w16(b, 0x1c), torch=b[0x99], hk=w16(b, 0x4c),
                            trap=w16(b, 0x56), grenade=w16(b, 0x38), bomb=w16(b, 0x58), crate=w16(b, 0x62), bridge=w16(b, 0x78),
                            mor=w16(c, 0x2e), hits=[w16(c, 6*i+4) for i in range(5)], man=w16(c, 0x22), map=w16(c, 0x24),
                            expl=w16(c, 0x28), msgs=w16(c, 0x48), score=c[0x4e:0x52].hex(),
                            ammo=w16(c, 2), gren=w16(c, 0)))
        self.ms = []
        for fn, kind in (('t_s.bin', 'ms'), ('t_t.bin', 'tp'), ('t_w.bin', 'wf')):
            for f, c in recs(f'{W}/{fn}', 0x78):
                self.ms.append(dict(f=f, kind=kind, hits=[w16(c, 6*i+4) for i in range(5)], man=w16(c, 0x22), mor=w16(c, 0x2e),
                                    msgs=w16(c, 0x48), score=c[0x4e:0x52].hex(), pst=-1, lvl=-1))
        self.ms.sort(key=lambda r: r['f'])
        return out

    def leg_wait(self, kind, cond, events, maxf=3000, label='', after=0):
        """like leg(), but on the wait-loop ticks (kind 'ms' = choose-your-man $19772, 'tp' = trap door $17dae)"""
        self.reassert()
        self._run(self.state, self.F, maxf, self.pending)
        hit = next((t for t in self.ms if t['kind'] == kind and t['f'] >= self.F + after and cond(t)), None)
        if hit is None:
            print('FAIL', label); self.save(); sys.exit(1)
        t = hit['f']
        new = [(t + o, c) for o, c in events]
        self.pending += new; self.events += new
        nf = max([t] + [f for f, _ in new]) + 1
        self._run(self.state, self.F, nf - self.F + 1, self.pending, save_at=nf)
        self.state = f'{W}/{self.name}_{nf}.state'
        self.pending = [(f, c) for f, c in self.pending if f >= nf]
        self.F = nf
        print(f'{label}: wait tick f{t} man {hit["man"]} hits {hit["hits"]} mor {hit["mor"]:#x} score {hit["score"]}', flush=True)
        return hit

    def reassert(self):
        """tools/amiga/emu keeps the joystick direction flags in globals outside the save state: after --load-state the next
        script event recomputes JOY1DAT from zeroed flags. Re-press the directions held at F (harmless in a continuous run)."""
        held = {}
        for f, c in sorted(self.events, key=lambda x: x[0]):
            if f >= self.F: break
            p = c.split()
            if p[0] in ('up', 'down', 'left', 'right'): held[p[0]] = p[1] != '0'
        for d, on in held.items():
            if on and not any(f == self.F and c.split()[0] == d for f, c in self.pending): self.ev(0, f'{d} 1')

    def leg(self, cond, events, maxf=3000, label='', after=0):
        """run from the current state (with pending events) until cond(tick) holds; then add events (rel. to that
        tick's head frame) and advance the state to just after the last new event."""
        self.reassert()
        ticks = self._run(self.state, self.F, maxf, self.pending)
        hit = next((t for t in ticks if t['f'] >= self.F + after and cond(t)), None)
        if hit is None:
            last = ticks[-1] if ticks else None
            print('FAIL', label, 'last tick', last); self.save(); sys.exit(1)
        t = hit['f']
        new = [(t + o, c) for o, c in events]
        self.pending += new
        self.events += new
        nf = max([t] + [f for f, _ in new]) + 1
        self._run(self.state, self.F, nf - self.F + 1, self.pending, save_at=nf)
        self.state = f'{W}/{self.name}_{nf}.state'
        self.pending = [(f, c) for f, c in self.pending if f >= nf]
        self.F = nf
        print(f'{label}: tick f{t} lvl {hit["lvl"]} col {hit["col"]} c34 {hit["c34"]} c30 {hit["c30"]:#x} pst {hit["pst"]} est {hit["est"]} mor {hit["mor"]:#x} score {hit["score"]}', flush=True)
        return hit

    def ev(self, rel, cmd):
        """add an event relative to the current state frame"""
        e = (self.F + rel, cmd); self.pending.append(e); self.events.append(e)

    def save(self, path=None):
        path = path or f'/tmp/verify-section0/sc/{self.name}.txt'
        open(path, 'w').write('\n'.join(f'{f} {c}' for f, c in sorted(self.events, key=lambda x: x[0])) + '\n')
        print('saved', path, len(self.events), 'events, last frame', max(f for f, _ in self.events))

    # ---- helpers
    def path_ok(self, t, lvl, col):
        return t['lvl'] == lvl and t['col'] == col and t['align'] == 0 and abs(t['c34']) in (0, 2, 6) and t['pst'] == 0

    def go(self, lvl, col, dirn, vert, label=None):
        """walk (dirn 'left'/'right') on level lvl to col, then take the path (vert 'up'/'down')."""
        newl = lvl + (1 if vert == 'down' else -1)
        self.ev(0, f'{dirn} 1')
        self.leg(lambda t: self.path_ok(t, lvl, col), [(0, f'{dirn} 0'), (0, f'{vert} 1'), (8, f'{vert} 0')],
                 maxf=6000, label=label or f'L{lvl} col {col} {dirn} -> {vert}')
        self.leg(lambda t: t['lvl'] == newl and t['pst'] == 0, [(0, 'fire 0')], label=f'  arrived L{newl}')
