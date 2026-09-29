#!/usr/bin/env python3
"""Extract every audio asset of Platoon (Amiga) from re/platoon_darc.adf and render all tunes/sfx with the
Python re-implementation of the David Whittaker driver (replayer.py).

Outputs (re/audio/assets/):
  audio.json                 all tables: songs, sequences, decoded patterns, instruments, envelopes, arpeggios,
                             period table, synth sfx definitions, sample sfx table
  instruments/instN.wav      the 8 music instrument samples (8-bit, native rate)
  sfx_samples/sfx_8X.wav     the 5 sampled sound effects ($80-$84) at their playback rate (+ $85 = $83 at half rate)
  synth_waves/waveN.wav      the 6 x 128-byte synth-sfx waveforms (+ PWM + instrument 4..7 waveforms), waves.png plot
  songs/songN.wav            each tune rendered for one full loop (stereo 44.1 kHz, emulator-identical Paula mix)
  sfx/sfx_XX.wav             every sound effect rendered through the driver (synth ids 0-11, samples $80-$85)
usage: extract.py [--quick] [--sfx-only] [--verify]   (--quick renders only 20 s of each song; --verify also runs verify.py:
       emulator-vs-Python register stream + bit-exact WAV comparison for every song and every sfx)
"""
import os, sys, json, struct, wave
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
from replayer import Driver, Paula, load_ram_from_adf, sx8, sx16

ADF = os.path.join(ROOT, 're/platoon_darc.adf')
OUT = os.path.join(HERE, 'assets')
QUICK = '--quick' in sys.argv
for d in ('instruments', 'sfx_samples', 'synth_waves', 'songs', 'sfx'):
    os.makedirs(os.path.join(OUT, d), exist_ok=True)

ram = load_ram_from_adf(ADF)
r8 = lambda a: ram[a]
r16 = lambda a: (ram[a] << 8) | ram[a + 1]
r32 = lambda a: (r16(a) << 16) | r16(a + 2)
A3 = 0x2800


def wav8(path, data, rate):
    """signed 8-bit Amiga sample -> unsigned 8-bit mono WAV"""
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(1); w.setframerate(int(rate))
        w.writeframes(bytes(((b + 128) & 0xff) for b in data))


def wav16(path, data):
    with open(path, 'wb') as fh:
        fh.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' +
                 struct.pack('<IHHIIHH', 16, 1, 2, 44100, 176400, 4, 16) + b'data' + struct.pack('<I', len(data)) + data)


PAL = 3546895
J = {'note': 'addresses absolute; offsets marked rel2800 are relative to $2800; periods in Paula ticks (PAL clock 3546895 Hz)'}

# ---------------- instruments (built exactly like init_tables $3bce) ----------------
inst = []
a0 = 0x430a
for i in range(8):
    ln = r32(a0); rate = r16(a0 + 4); ptr = a0 + 6
    loop = r32(0x2f48 + i * 12 + 4)
    mult = 0x369e99 // rate
    lw = ln >> 1
    if i == 5: lw = 0x20
    e = dict(index=i, header=a0, ptr=ptr, length_bytes=ln, rate_hz=rate, len_words=lw, loop_offset=(None if loop & 0x80000000 else loop),
             period_mult=mult, adf_offset=ptr + 0x1200)
    data = bytes(ram[ptr:ptr + ln])
    if i == 5:   # PWM square: runtime-initialised 32 x $c0 then 32 x $3f (the disk bytes are overwritten)
        data = bytes([0xc0] * 32 + [0x3f] * 32)
        e['note'] = 'runtime PWM waveform: init 32x$c0,32x$3f; bytes $20..$2b toggled one word per music tick'
    wav8(os.path.join(OUT, 'instruments', 'inst%d.wav' % i), [sx8(b) for b in data], rate)
    inst.append(e)
    a0 = ptr + ln
J['instruments'] = inst
J['silence_buffer'] = a0            # $89c0, 64 zero bytes
J['synth_wave_base'] = a0 + 0x40    # $8a00

# ---------------- period table / arpeggios / envelopes ----------------
J['period_table'] = [r16(0x2e6c + 2 * i) for i in range(84)]
arps = []
for i in range(13):
    a = A3 + r16(0x2efc + 2 * i); lst = []
    while True:
        b = r8(a); a += 1; lst.append(b & 0x7f)
        if b & 0x80: break
    arps.append(dict(index=i, cmd=0xa0 + i, addr=A3 + r16(0x2efc + 2 * i), offsets=lst))
J['arpeggios'] = arps
envs = []
for i in range(16):
    a = A3 + r16(0x4200 + 2 * i); st = a; lst = []
    while True:
        b = r8(a); a += 1; lst.append(b & 0x7f)
        if b & 0x80: break
    envs.append(dict(index=i, cmd=0xb0 + i, addr=st, speed=r8(st - 1), volumes=lst, note='last value is held'))
J['envelopes'] = envs

# ---------------- songs / sequences / patterns ----------------
USE = {0: 'title screen (kernel $f90e/$f93e)', 1: 'high-score entry after game over (kernel $ff40)',
       2: 'section 0 in-game: Jungle & Village (section0 $17180)',
       3: 'Adagio/"message" tune: section-complete screen (kernel $11076 via $f874), death/failure message screens '
          '(section0 $19daa, section1 $17278, section2 $176de) and the between-section text screen',
       4: 'section 1 in-game: Tunnels (section1 $172c2)', 5: 'section 2 in-game: Jungle 2 & Foxhole (section2 $17724)',
       6: 'section 1 Flare/Bunker sub-section (section1 $18b66)'}
songs = []; seqs = {}; pats = {}
def decode_pattern(po):
    a = A3 + po; ev = []
    while True:
        at = a; b = r8(a); a += 1
        if b < 0x80: ev.append(dict(at=at, op='note', n=b))
        elif b >= 0xe0: ev.append(dict(at=at, op='dur', units=b - 0xdf))
        elif b >= 0xc0: ev.append(dict(at=at, op='inst', i=b - 0xc0))
        elif b >= 0xb0: ev.append(dict(at=at, op='env', i=b - 0xb0))
        elif b >= 0xa0: ev.append(dict(at=at, op='arp', i=b - 0xa0))
        elif b == 0x80: ev.append(dict(at=at, op='end')); break
        elif b == 0x81: ev.append(dict(at=at, op='porta', speed=sx8(r8(a)), delay=r8(a + 1))); a += 2
        elif b == 0x82: ev.append(dict(at=at, op='rest'))
        elif b == 0x83: ev.append(dict(at=at, op='tie'))
        elif b == 0x84: ev.append(dict(at=at, op='stop')); break
        elif b == 0x85: ev.append(dict(at=at, op='gtranspose', t=r8(a))); a += 1
        elif b == 0x86: ev.append(dict(at=at, op='vibrato', speed=r8(a), depth=r8(a + 1))); a += 2
        elif b == 0x87: ev.append(dict(at=at, op='vibrato_off'))
        elif b == 0x88: ev.append(dict(at=at, op='transpose', t=sx8(r8(a)))); a += 1
        elif b == 0x89: ev.append(dict(at=at, op='newseq', seq=r16(a))); a += 2
        elif b == 0x8a: ev.append(dict(at=at, op='tempo', t=sx8(r8(a)))); a += 1
        else: ev.append(dict(at=at, op='undefined', b=b)); break
    return ev, a
for s in range(7):
    b = 0x2fa8 + s * 10
    e = dict(index=s, addr=b, tempo=sx8(r8(b)), speed=r8(b + 1), sequences_rel2800=[r16(b + 2 + 2 * c) for c in range(4)], used_for=USE[s])
    for so in e['sequences_rel2800']:
        if so in seqs: continue
        lst = []; a = A3 + so
        while r16(a): lst.append(r16(a)); a += 2
        seqs[so] = lst
        for po in lst:
            if po not in pats:
                pats[po] = decode_pattern(po)
    songs.append(e)
J['songs'] = songs
J['sequences'] = {('%04x' % k): dict(addr=A3 + k, patterns_rel2800=['%04x' % p for p in v]) for k, v in sorted(seqs.items())}
J['patterns'] = {('%04x' % k): dict(addr=A3 + k, end=v[1], events=v[0]) for k, v in sorted(pats.items())}

# ---------------- synth sfx ----------------
sd = []
for i in range(12):
    a = 0x40b4 + i * 22
    b = bytes(ram[a:a + 22])
    ea = A3 + r16(0x41bc + 2 * sx8(b[0x14]))
    env = []; p = ea
    while True:
        v = r8(p); p += 1
        if v & 0x80: break
        env.append(v)
    sd.append(dict(id=i, addr=a, raw=b.hex(), period_delta=sx16(r16(a)), period_reset=r16(a + 2),
                   alt_period_hi=sx16(r16(a + 4)), alt_period_lo=sx16(r16(a + 6)), period_start=r16(a + 8),
                   wave_off_hi=sx16(r16(a + 10)), wave_off_lo=sx16(r16(a + 12)), reset_interval=b[0xe], alt_interval=b[0xf],
                   alt_pattern='%02x' % b[0x10], wave_pattern='%02x' % b[0x11], duration_frames=b[0x12] or 256,
                   env_speed=b[0x13], env_index=b[0x14], env_addr=ea, env_volumes=env, byte15=b[0x15]))
J['synth_sfx'] = sd
J['synth_sfx_waves'] = [dict(index=k, addr=0x8a00 + 128 * k) for k in range(6)]
for k in range(6):
    wav8(os.path.join(OUT, 'synth_waves', 'wave%d.wav' % k), [sx8(x) for x in ram[0x8a00 + 128 * k:0x8a80 + 128 * k]] * 64, 8000)

# ---------------- sample sfx (built like $3c42) ----------------
ss = []
a0 = 0x8d02
for i in range(5):
    ln = r32(a0); rate = r16(a0 + 4); ptr = a0 + 6
    frames = ((r16(a0 + 2) * 50) // rate + 1) & 0xff
    per = 0x369e99 // rate
    ss.append(dict(id=0x80 + i, header=a0, ptr=ptr, length_bytes=ln, len_words=ln >> 1, rate_hz=rate, period=per,
                   play_hz=round(PAL / per, 1), duration_frames=frames, loop=None, adf_offset=ptr + 0x1200))
    data = [sx8(x) for x in ram[ptr:ptr + ln]]
    wav8(os.path.join(OUT, 'sfx_samples', 'sfx_%02x.wav' % (0x80 + i)), data, PAL / per)
    if i == 3:
        wav8(os.path.join(OUT, 'sfx_samples', 'sfx_85.wav'), data, PAL / (per * 2))
    a0 = ptr + ln
ss.append(dict(id=0x85, note='sample $83 played with period*2 (octave down) for duration*2 frames', period=ss[3]['period'] * 2,
               duration_frames=(ss[3]['duration_frames'] * 2) & 0xff))
J['sample_sfx'] = ss
J['sample_sfx_end'] = a0

# waveform plot
try:
    from PIL import Image, ImageDraw
    waves = [('sfx wave %d' % k, [sx8(x) for x in ram[0x8a00 + 128 * k:0x8a80 + 128 * k]]) for k in range(6)]
    waves += [('inst%d' % i, [sx8(x) for x in (ram[inst[i]['ptr']:inst[i]['ptr'] + inst[i]['length_bytes']] if i != 5 else bytes([0xc0] * 32 + [0x3f] * 32))]) for i in range(4, 8)]
    W, H = 512, 96
    img = Image.new('RGB', (W, H * len(waves)), (0, 0, 0)); dr = ImageDraw.Draw(img)
    for k, (nm, w) in enumerate(waves):
        y0 = k * H + H // 2
        dr.line([(0, y0), (W, y0)], fill=(60, 60, 60))
        pts = [(x * W // len(w), y0 - w[x] * (H // 2 - 4) // 128) for x in range(len(w))]
        dr.line(pts, fill=(80, 255, 80)); dr.text((4, k * H + 2), nm, fill=(255, 255, 0))
    img.save(os.path.join(OUT, 'synth_waves', 'waves.png'))
except ImportError:
    pass

json.dump(J, open(os.path.join(OUT, 'audio.json'), 'w'), indent=1)
print('tables -> audio.json (%d sequences, %d patterns)' % (len(seqs), len(pats)))


# ---------------- rendering through the driver ----------------
def render(frames, setup, play_line=3):
    """mix the driver output; all writes of a vblank are applied at raster line `play_line`, a busy-wait marker
    (-2, n) in the log advances the mixer n raster lines (the trigger's delay loops)"""
    ram2 = load_ram_from_adf(ADF)
    p = Paula(ram2); p.dmacon = 0x200
    d = Driver(ram2)
    for f in range(frames):
        d.frame = f
        ln = 0
        while ln < 313:
            if ln == play_line:
                d.log = []
                d.play()
                if f == 0: setup(d)
                for (_, r, v) in d.log:
                    if r == -2:
                        for _k in range(v):
                            if ln < 312: p.line(); ln += 1
                    else:
                        p.write(r, v)
                d.log = []
            p.line(); ln += 1
    return bytes(p.out), d


def loop_frames(song):
    """frames until every channel whose sequence has >1 entry has restarted its sequence once"""
    d = Driver(load_ram_from_adf(ADF)); d.init_song(song)
    multi = [c for c in range(4) if len(seqs[r16(0x2fa8 + song * 10 + 2 + 2 * c)]) > 1]
    for f in range(1, 30000):
        d.play()
        if all(d.seq_wraps[c] for c in multi): return f
    return 30000


info = []
for s in ([] if '--sfx-only' in sys.argv else range(7)):
    n = 1000 if QUICK else loop_frames(s) + 50
    pcm, _ = render(n, lambda d, s=s: d.k_music(s, 3))
    wav16(os.path.join(OUT, 'songs', 'song%d.wav' % s), pcm)
    info.append((s, n)); print('song %d: %d frames (%.1f s)' % (s, n, n / 50))

for sid in list(range(12)) + [0x80, 0x81, 0x82, 0x83, 0x84, 0x85]:
    def setup(d, sid=sid):
        d.init_tables()
        d.k_sfx(sid, 3)
    pcm, d = render(300 if sid in (0x85,) else 280, setup)
    wav16(os.path.join(OUT, 'sfx', 'sfx_%02x.wav' % sid), pcm)
print('rendered sfx; done')

if '--verify' in sys.argv:
    import subprocess
    W = os.path.join(HERE, 'work')
    def mk(name, text):
        p = os.path.join(W, name); open(p, 'w').write(text); return p
    runs = [('title', 3000, None)]
    for n in range(1, 7):
        runs.append(('song%d' % n, 4500, mk('song%d.txt' % n, '400 poke 12cce %d 2\n402 key 0x59 1\n408 key 0x59 0\n422 key 0x59 1\n428 key 0x59 0\n' % n)))
    for name in ('sfxtest', 'sfxtest3'):
        p = os.path.join(W, name + '.txt')
        if os.path.exists(p): runs.append((name, 5600 if name == 'sfxtest' else 2600, p))
    for name, frames, script in runs:
        cmd = [sys.executable, os.path.join(HERE, 'verify.py'), name, str(frames), '--wav', '--quiet']
        if script: cmd += ['--script', script]
        r = subprocess.run(cmd, capture_output=True, text=True)
        print('\n'.join(l[:220] for l in r.stdout.splitlines()))

