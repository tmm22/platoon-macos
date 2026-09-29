#!/usr/bin/env python3
"""Faithful Python re-implementation of the Platoon (Amiga) David Whittaker music + SFX driver ($2800-$3ff8).

Operates directly on a 512K chip-RAM image (bytearray) using the original addresses so that the
state layout is identical to the original.  Every Paula register write is recorded (in the exact
original order) into self.log as (frame, reg_offset, value16) with reg_offset relative to $dff000,
so it can be compared with the emulator's --reglog output.

Entry points (original addresses):
  init_song(d0)      $2800 -> $2854   (d0 = song 0..6)
  play()             $280e -> $2990   (call once per vblank)
  stop()             $281c -> $28e8
  resume()           $282a -> $2960   (unused by the game)
  sfx(d0)            $2838 -> $3c90   (d0 = (channel<<8) | id)
  sfx_stop_all()     $2846 -> $2942
Kernel wrappers (in $f800 kernel):
  k_music(d0, opts)  $10c00  (jump table $f868)
  k_music_off()      $10c3a
  k_sfx(d0, opts)    $10c50  (jump table $f86c)
  k_fade()           $fed6
"""

A3 = 0x2800
TRACK = 0x1600


def load_ram_from_adf(adf_path):
    """Build a chip RAM image with the main program (tracks 1..17) at $400 (RAM addr X = ADF offset X+$1200)."""
    adf = open(adf_path, 'rb').read()
    ram = bytearray(0x80000)
    ram[0x400:0x400 + 17 * TRACK] = adf[TRACK:TRACK + 17 * TRACK]
    return ram


def sx8(v):
    v &= 0xff
    return v - 0x100 if v & 0x80 else v


def sx16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


class Driver:
    # music globals (absolute addresses)
    TEMPO = 0x2d96      # w  duration unit (multiplier for $e0-$ff duration bytes)
    MVOL = 0x2d98       # w  master volume 0..64
    SPEED = 0x2d9a      # b  tick-skip rate (added to ACC; carry => skip music tick)
    SPEED0 = 0x2d9b     # b  copy of SPEED at song start (unused)
    ACC = 0x2d9c        # b  speed accumulator
    LOADED = 0x2d9d     # b  $ff = a song has been initialised (for resume)
    TABINIT = 0x2d9e    # b  $ff = instrument table built ($3bce done)
    PLAYING = 0x2d9f    # b  $ff = music running
    GTRANS = 0x2da0     # b  global transpose (cmd $85)
    NTSCCNT = 0x2da1    # b  NTSC frame skip counter (init 6)
    NTSC = 0x2da2       # b  NTSC compensation enable (never set by the game)
    SILENT = 0x2da4     # l  pointer to 64 zero bytes (end of instrument samples, $89c0)
    PWMDIR = 0x2da8     # w  PWM direction (0 = widening, $ffff = narrowing)
    PWMOFS = 0x2daa     # w  PWM byte offset into instrument 5 waveform ($20..$2c)
    CHAN = 0x2dac       # 4 x $30 channel structs
    PERTAB = 0x2e6c     # 84 words period table
    ARPTAB = 0x2efc     # 13 words (offsets rel $2800) arpeggio tables
    INST = 0x2f48       # 8 x 12 instrument table
    SONGS = 0x2fa8      # 7 x 10 song table
    SMPHDR = 0x430a     # 8 chained instrument samples (long len, word rate, data)
    ENVTAB = 0x4200     # 16 words (offsets rel $2800) music volume envelopes
    SFXCH = 0x3ffa      # 4 x $22 sfx channel structs
    SFXSEL = 0x4082     # w  (channel<<8)|id of last sfx request
    SHADOW = 0x4084     # 4 x 12 music shadow registers
    SFXDEF = 0x40b4     # 12 x 22 synth sfx definitions
    SFXENV = 0x41bc     # 3 words (offsets rel $2800) synth sfx volume envelopes
    SFXWAVE = 0x41fc    # l  synth sfx waveform base ($8a00)
    SMPSFX = 0x3d72     # 5 x 16 sample sfx table
    SMPSFXINIT = 0x3c8e  # b  $ff = sample sfx table built
    SMPSFXHDR = 0x8d02  # 5 chained sample sfx (long len, word rate, data)

    def __init__(self, ram):
        self.m = ram
        self.frame = 0
        self.log = []   # (frame, reg, value)
        self.hw = [0] * 0x100  # custom register shadow (word index = reg>>1)
        self.dmacon = 0
        self.seq_wraps = [0, 0, 0, 0]   # instrumentation only (counts sequence restarts per channel)

    # ---- memory helpers ----
    def r8(self, a): return self.m[a & 0x7ffff]
    def r16(self, a): a &= 0x7ffff; return (self.m[a] << 8) | self.m[a + 1]
    def r32(self, a): return (self.r16(a) << 16) | self.r16(a + 2)
    def w8(self, a, v): self.m[a & 0x7ffff] = v & 0xff
    def w16(self, a, v): a &= 0x7ffff; self.m[a] = (v >> 8) & 0xff; self.m[a + 1] = v & 0xff
    def w32(self, a, v): self.w16(a, (v >> 16) & 0xffff); self.w16(a + 2, v & 0xffff)

    # ---- custom chip writes ----
    def cw(self, reg, v):
        v &= 0xffff
        self.log.append((self.frame, reg, v))
        self.hw[reg >> 1] = v
        if reg == 0x96:
            if v & 0x8000: self.dmacon |= v & 0x7fff
            else: self.dmacon &= ~v & 0xffff

    def cwl(self, reg, v):  # move.l to AUDxLC: high word then low word
        self.cw(reg, (v >> 16) & 0xffff)
        self.cw(reg + 2, v & 0xffff)

    # =====================================================================
    # $28e8 stop
    def stop(self):
        m = self
        m.w8(m.PLAYING, 0)
        for ch in range(4):
            m.w8(m.SFXCH + ch * 0x22 + 0x18, 0)      # sfx inactive ($4012,$4034,$4056,$4078)
        for ch in range(4):
            m.w16(m.SHADOW + ch * 12 + 0xa, 0)       # clr.w shadow+$a (+$a and +$b!)
        m.cw(0x96, 0x000f)
        m.cw(0x9e, 0x00ff)
        m.cw(0xa8, 0); m.cw(0xb8, 0); m.cw(0xc8, 0); m.cw(0xd8, 0)

    # $2942 stop all sfx (end next tick)
    def sfx_stop_all(self):
        for ch in range(4):
            self.w8(self.SFXCH + ch * 0x22 + 0x12, 1)

    # $2960 resume (unused)
    def resume(self):
        if self.r8(self.LOADED):
            self.cw(0x9e, 0x00ff)
            self.cw(0x96, 0x820f)
            self.w8(self.PLAYING, 0xff)

    # $3bce build instrument table (once)
    def init_tables(self):
        m = self
        if m.r8(m.TABINIT):
            return
        a0 = m.SMPHDR
        a5 = m.INST
        for _ in range(8):
            d2 = m.r32(a0); d3 = m.r16(a0 + 4); a0 += 6
            m.w32(a5 + 0, a0)
            a0 = (a0 + d2) & 0xffffffff
            d2 >>= 1
            m.w16(a5 + 8, d2 & 0xffff)
            m.w16(a5 + 0xa, (0x369e99 // d3) & 0xffff)   # divu: quotient (no overflow in data)
            a5 += 12
        m.w32(m.SILENT, a0)
        a0 += 0x40
        m.w32(m.SFXWAVE, a0)
        a0 = m.r32(0x2f84)            # instrument 5 sample pointer ($8834)
        for _ in range(16): m.w16(a0, 0xc0c0); a0 += 2
        for _ in range(16): m.w16(a0, 0x3f3f); a0 += 2
        m.w16(0x2f8c, 0x20)           # instrument 5 length = 32 words
        m.w16(m.PWMOFS, 0x20)
        m.w16(m.PWMDIR, 0)
        m.w8(m.TABINIT, 0xff)

    # $3c42 build sample-sfx table (once)
    def init_smp_sfx(self):
        m = self
        if m.r8(m.SMPSFXINIT):
            return
        a0 = m.SMPSFXHDR
        a5 = m.SMPSFX
        for _ in range(5):
            d2 = m.r16(a0 + 2) * 0x32            # mulu.w #50 of low word of length
            q = d2 // m.r16(a0 + 4)
            m.w8(a5 + 0xc, (q + 1) & 0xff)       # divu then addq.b #1 (byte)
            d2 = m.r32(a0); d3 = m.r16(a0 + 4); a0 += 6
            m.w32(a5 + 0, a0)
            a0 = (a0 + d2) & 0xffffffff
            m.w16(a5 + 8, (d2 >> 1) & 0xffff)
            m.w16(a5 + 0xa, (0x369e99 // d3) & 0xffff)
            a5 += 0x10
        m.w8(m.SMPSFXINIT, 0xff)

    # $2854 init song d0
    def init_song(self, d0):
        m = self
        # bset #1,$bfe001 (audio filter/LED off) - not a custom reg; recorded as pseudo reg -1
        m.log.append((m.frame, -1, 1))
        m.stop()                                   # bsr $281c
        m.init_tables()                            # bsr $3bce
        m.w8(m.GTRANS, 0)
        d0 = (sx8(d0) & 0xffff) * 10 & 0xffff      # ext.w d0 ; mulu #10
        a0 = m.SONGS
        m.w16(m.TEMPO, sx8(m.r8(a0 + d0)) & 0xffff)
        m.w8(m.SPEED, m.r8(a0 + d0 + 1))
        m.w8(m.SPEED0, m.r8(m.SPEED))
        for ch in range(4):
            a1 = m.CHAN + ch * 0x30
            m.w16(a1 + 0x1e, 1)
            m.w8(a1 + 0, 0); m.w8(a1 + 1, 0); m.w8(a1 + 3, 0)
            m.w8(a1 + 0x16, 0xff)
            m.w32(a1 + 0xc, 0x2f16); m.w32(a1 + 0x10, 0x2f16)
            seq = sx16(m.r16(m.SONGS + d0 + 2))
            m.w16(a1 + 8, seq & 0xffff)
            m.w16(a1 + 0xa, 2)
            pat = sx16(m.r16((A3 + seq) & 0xffffffff))
            m.w32(a1 + 4, (A3 + pat) & 0xffffffff)
            d0 += 2
        m.w8(m.PLAYING, 0xff)
        m.w8(m.LOADED, 0xff)

    def period(self, note, a5):
        d0 = self.r16(self.PERTAB + (note & 0xff) * 2)
        return (d0 * self.r16(a5 + 0xa)) >> 10          # 32-bit result; callers truncate to word

    def scale_vol(self, d1w):
        prod = ((d1w & 0xffff) * self.r16(self.MVOL)) & 0xffffffff
        return (prod & 0xffff) >> 6                      # lsr.w #6 acts on the low word only

    # $2990 play (one vblank)
    def play(self):
        m = self
        if not m.r8(m.PLAYING):
            m.sfx_update(); return
        if m.r8(m.NTSC):
            c = (m.r8(m.NTSCCNT) - 1) & 0xff
            m.w8(m.NTSCCNT, c)
            if c == 0:
                m.w8(m.NTSCCNT, 6)
                return                                    # skips sfx update too
        s = m.r8(m.ACC) + m.r8(m.SPEED)
        m.w8(m.ACC, s)
        if s > 0xff:
            m.sfx_update(); return
        # PWM on instrument 5 waveform
        a0 = m.r32(0x2f84)
        d0 = m.r16(m.PWMOFS)
        if m.r16(m.PWMDIR) & 0x8000 == 0:
            m.w16(a0 + d0, 0xc0c0)
            o = (m.r16(m.PWMOFS) + 2) & 0xffff; m.w16(m.PWMOFS, o)
            if o == 0x2c: m.w16(m.PWMDIR, ~m.r16(m.PWMDIR) & 0xffff)
        else:
            m.w16(a0 + d0, 0x3f3f)
            o = (m.r16(m.PWMOFS) - 2) & 0xffff; m.w16(m.PWMOFS, o)
            if o == 0x20: m.w16(m.PWMDIR, ~m.r16(m.PWMDIR) & 0xffff)
        for d7 in range(4):
            if m.channel(d7) == 'stop':
                return                                   # cmd $84 ends play (no sfx update)
        m.sfx_update()

    def channel(self, d7):
        m = self
        a4 = m.SHADOW + d7 * 12
        m.w8(a4 + 0xa, 0xff)
        hw = 0xa0 + d7 * 16
        a0 = m.CHAN + d7 * 0x30
        a1 = m.r32(a0 + 4)
        a5 = m.r32(a0 + 0x18)
        sfx_owns = lambda: m.r8(a4 + 0xb) != 0
        if m.r8(a0 + 0x16) == 0:
            m.w8(a0 + 0x16, 0xff)
            d0 = m.r32(a5 + 4)
            if d0 & 0x80000000:
                sil = m.r32(m.SILENT)
                m.w32(a4 + 0, sil); m.w16(a4 + 4, 0x20)
                if not sfx_owns():
                    m.cwl(hw + 0, sil); m.cw(hw + 4, 0x20)
            else:
                a2 = (m.r32(a5 + 0) + d0) & 0xffffffff
                d0 >>= 1
                d1 = (m.r16(a5 + 8) - d0) & 0xffff
                m.w32(a4 + 0, a2); m.w16(a4 + 4, d1)
                if not sfx_owns():
                    m.cwl(hw + 0, a2); m.cw(hw + 4, d1)
        cnt = (m.r16(a0 + 0x1e) - 1) & 0xffff
        m.w16(a0 + 0x1e, cnt)
        if cnt != 0:
            if cnt != 1:
                m.effects(d7, a0, a4, a5, hw)
                return
            if not sfx_owns() and m.r8(a1) != 0x83:
                m.cw(0x96, 1 << d7)
            return
        # ---- new event: read pattern bytes ----
        m.w8(a0 + 0, 0)
        while True:
            d0 = m.r8(a1); a1 += 1
            if d0 < 0x80:
                m.w8(a0 + 2, d0)
                d0 = (d0 + m.r8(m.GTRANS) + m.r8(a0 + 3)) & 0xff
                a2 = m.r32(a0 + 0x22)
                d1 = m.r8(a2); a2 += 1
                m.w32(a0 + 0x26, a2)
                m.w8(a0 + 0x2b, m.r8(a0 + 0x2a))
                d1w = sx8(d1) & 0xffff
                m.w32(a4 + 0, m.r32(a5 + 0))
                m.w16(a4 + 4, m.r16(a5 + 8))
                vol = m.scale_vol(d1w)
                m.w16(a4 + 8, vol)
                if not sfx_owns():
                    m.cwl(hw + 0, m.r32(a5 + 0))
                    m.cw(hw + 4, m.r16(a5 + 8))
                    m.cw(hw + 8, vol)
                per = m.period(d0, a5) & 0xffff
                m.w16(a4 + 6, per)
                if not sfx_owns():
                    m.cw(hw + 6, per)
                m.w8(a0 + 0x16, 0)
                m.w32(a0 + 4, a1)
                m.w16(a0 + 0x1e, m.r16(a0 + 0x1c))
                m.cw(0x96, 0x8200 | (1 << d7))
                return
            if d0 >= 0xe0:
                m.w16(a0 + 0x1c, ((d0 - 0xdf) * m.r16(m.TEMPO)) & 0xffff)
                continue
            if d0 >= 0xc0:
                a5 = m.INST + (d0 - 0xc0) * 12
                m.w32(a0 + 0x18, a5)
                continue
            if d0 >= 0xb0:
                a2 = (A3 + sx16(m.r16(m.ENVTAB + (d0 - 0xb0) * 2))) & 0xffffffff
                m.w32(a0 + 0x22, a2)
                m.w8(a0 + 0x2a, m.r8(a2 - 1))
                continue
            if d0 >= 0xa0:
                a2 = (A3 + sx16(m.r16(m.ARPTAB + (d0 - 0xa0) * 2))) & 0xffffffff
                m.w32(a0 + 0xc, a2); m.w32(a0 + 0x10, a2)
                continue
            c = d0 & 0x7f
            if c == 0:        # $80 next sequence entry
                d0 = m.r16(a0 + 0xa)
                a2 = (m.r16(a0 + 8) + d0) & 0xffff
                d0 = (d0 + 2) & 0xffff
                if m.r16((A3 + sx16(a2)) & 0xffffffff) == 0:
                    a2 = m.r16(a0 + 8); d0 = 2
                    m.seq_wraps[d7] += 1
                a1 = (A3 + sx16(m.r16((A3 + sx16(a2)) & 0xffffffff))) & 0xffffffff
                m.w16(a0 + 0xa, d0)
            elif c == 1:      # $81 portamento: speed, delay
                m.w16(a0 + 0x20, 0)
                m.w8(a0 + 0x14, m.r8(a1)); m.w8(a0 + 0x15, m.r8(a1 + 1)); a1 += 2
                m.w8(a0 + 0, m.r8(a0 + 0) | 2)
            elif c == 2:      # $82 rest
                m.w16(a0 + 0x1e, m.r16(a0 + 0x1c))
                m.w32(a0 + 4, a1)
                sil = m.r32(m.SILENT)
                m.w32(a4 + 0, sil); m.w16(a4 + 4, 0x20)
                if not sfx_owns():
                    m.cwl(hw + 0, sil); m.cw(hw + 4, 0x20)
                return
            elif c == 3:      # $83 tie / hold
                m.w32(a0 + 4, a1)
                m.w16(a0 + 0x1e, m.r16(a0 + 0x1c))
                m.cw(0x96, 0x8200 | (1 << d7))
                return
            elif c == 4:      # $84 end of song
                m.w8(m.LOADED, 0)
                m.stop()
                return 'stop'
            elif c == 5:      # $85 global transpose
                m.w8(m.GTRANS, m.r8(a1)); a1 += 1
            elif c == 6:      # $86 vibrato on: speed, depth
                m.w8(a0 + 1, 0xff)
                m.w8(a0 + 0x2c, m.r8(a1)); m.w8(a0 + 0x2e, m.r8(a1 + 1)); a1 += 2
                m.w8(a0 + 0x2d, 0)
            elif c == 7:      # $87 vibrato off
                m.w8(a0 + 1, 0)
            elif c == 8:      # $88 channel transpose
                m.w8(a0 + 3, m.r8(a1)); a1 += 1
            elif c == 9:      # $89 new sequence (word, big-endian bytes)
                m.w8(a0 + 8, m.r8(a1)); m.w8(a0 + 9, m.r8(a1 + 1)); a1 += 2
                m.w16(a0 + 0xa, 0)
            elif c == 10:     # $8a tempo
                m.w16(m.TEMPO, sx8(m.r8(a1)) & 0xffff); a1 += 1
            else:
                raise RuntimeError('undefined pattern command %02x at %06x' % (d0, a1 - 1))

    def effects(self, d7, a0, a4, a5, hw):
        m = self
        d0 = (m.r8(a0 + 2) + m.r8(m.GTRANS) + m.r8(a0 + 3)) & 0xff
        a1 = m.r32(a0 + 0x10)
        d1 = m.r8(a1); a1 += 1
        if d1 & 0x80:
            d1 &= 0x7f
            a1 = m.r32(a0 + 0xc)
        m.w32(a0 + 0x10, a1)
        d0 = (d0 + d1) & 0xff
        d0 = m.period(d0, a5) & 0xffff          # word arithmetic from here on
        if m.r8(a0 + 0) & 2:
            if m.r8(a0 + 0x15):
                m.w8(a0 + 0x15, m.r8(a0 + 0x15) - 1)
            else:
                acc = (m.r16(a0 + 0x20) + sx8(m.r8(a0 + 0x14))) & 0xffff
                m.w16(a0 + 0x20, acc)
                d0 = (d0 - acc) & 0xffff
        vib = m.r8(a0 + 1)
        if vib:
            if vib & 0x80:
                d1 = (m.r8(a0 + 0x2d) + m.r8(a0 + 0x2c)) & 0xff
                m.w8(a0 + 0x2d, d1)
                if d1 == m.r8(a0 + 0x2e):
                    m.w8(a0 + 1, m.r8(a0 + 1) ^ 0x80)
            else:
                d1 = (m.r8(a0 + 0x2d) - m.r8(a0 + 0x2c)) & 0xff
                m.w8(a0 + 0x2d, d1)
                if d1 == 0:
                    m.w8(a0 + 1, m.r8(a0 + 1) ^ 0x80)
            if m.r8(a0 + 0x2d) == 0:
                m.w8(a0 + 1, m.r8(a0 + 1) ^ 0x01)
            v = sx8(d1)
            if m.r8(a0 + 1) & 1: d0 = (d0 + v) & 0xffff
            else: d0 = (d0 - v) & 0xffff
        m.w16(a4 + 6, d0)
        if not m.r8(a4 + 0xb):
            m.cw(hw + 6, d0)
        c = m.r8(a0 + 0x2b)
        m.w8(a0 + 0x2b, c - 1)
        if c != 0:
            return                             # subq.b #1 ; bcc
        m.w8(a0 + 0x2b, m.r8(a0 + 0x2a))
        a2 = m.r32(a0 + 0x26)
        d1 = m.r8(a2); a2 += 1
        if not d1 & 0x80:
            m.w32(a0 + 0x26, a2)
        vol = m.scale_vol(d1 & 0x7f)
        m.w16(a4 + 8, vol)
        if not m.r8(a4 + 0xb):
            m.cw(hw + 8, vol)

    # =====================================================================
    # $3c90 trigger sfx; d0 = (channel<<8)|id
    def sfx(self, d0):
        m = self
        m.log.append((m.frame, -1, 1))            # bset #1,$bfe001
        m.cw(0x9e, 0x00ff)
        d0 &= 0x3ff
        m.w16(m.SFXSEL, d0)
        ch = d0 >> 8
        m.w8(m.SFXCH + ch * 0x22 + 0x18, 0)
        m.init_tables()
        m.w8(m.SHADOW + ch * 12 + 0xb, 0xff)
        idv = sx8(d0)
        if idv < 0:
            return m.sfx_sample(d0 & 0xff)
        if idv > 0xb: idv = 0
        a1 = m.SFXCH + ch * 0x22
        d2 = 1 << ch
        m.w8(a1 + 0x18, 0)
        m.cw(0x96, d2)
        m.cw(0xa4 + ch * 16, 0x40)
        src = m.SFXDEF + idv * 0x16
        m.m[a1:a1 + 0x16] = m.m[src:src + 0x16]
        m.w16(a1 + 0x16, m.r16(a1 + 0xe))
        m.w8(a1 + 0x19, 1)
        e = sx8(m.r8(a1 + 0x14)) * 2
        m.w32(a1 + 0x1a, (A3 + sx16(m.r16(m.SFXENV + e))) & 0xffffffff)
        m.log.append((m.frame, -2, 12))           # busy wait at $3d64
        m.w8(a1 + 0x18, 0xff)

    def sfx_sample(self, idb):
        m = self
        m.init_smp_sfx()
        if sx8(idb) > sx8(0x85):
            return
        if idb == 0x85:          # sample 3 at half rate, double duration
            e = m.SMPSFX + 3 * 16
            m.w16(e + 0xa, (m.r16(e + 0xa) << 1) & 0xffff)
            m.w8(e + 0xc, (m.r8(e + 0xc) * 2) & 0xff)
            m.sfx_sample_play(0x83)
            m.w16(e + 0xa, m.r16(e + 0xa) >> 1)
            m.w8(e + 0xc, m.r8(e + 0xc) >> 1)
            return
        m.sfx_sample_play(idb)

    def sfx_sample_play(self, idb):
        m = self
        m.init_smp_sfx()
        ch = m.r8(m.SFXSEL)
        a1 = m.SFXCH + ch * 0x22
        m.w8(a1 + 0x18, 0)
        m.w8(a1 + 0x15, idb)
        d2 = 1 << ch
        m.cw(0x96, d2)
        a0 = m.SMPSFX + (idb & 0x7f) * 16
        m.w8(a1 + 0x12, m.r8(a0 + 0xc))
        if m.r8(a0 + 0xd):
            m.w8(a1 + 0x12, 0)
        m.log.append((m.frame, -2, 12))           # bsr $3eaa busy wait (~12 raster lines)
        hw = 0xa0 + ch * 16
        m.cw(hw + 4, m.r16(a0 + 8))
        m.cwl(hw + 0, m.r32(a0 + 0))
        m.cw(hw + 6, m.r16(a0 + 0xa))
        m.w16(a1 + 0x1e, m.r16(a0 + 0xa)); m.w16(a1 + 0x20, m.r16(a0 + 0xa))
        m.cw(hw + 8, 0x40)
        m.cw(0x96, 0x8200 | d2)
        m.w8(a1 + 0x18, 0xff)
        m.log.append((m.frame, -2, 12))           # bsr $3eaa busy wait
        d0 = m.r32(a0 + 4)
        if d0 & 0x80000000:
            m.cwl(hw + 0, m.r32(m.SILENT))
            m.cw(hw + 4, 0x20)
            return
        a2 = (m.r32(a0) + d0) & 0xffffffff
        d1 = (m.r16(a0 + 8) - (d0 >> 1)) & 0xffff
        m.cw(hw + 4, d1)
        m.cwl(hw + 0, a2)

    # $3eb4 per-frame sfx update
    def sfx_update(self):
        for ch in range(4):
            a1 = self.SFXCH + ch * 0x22
            if self.r8(a1 + 0x18):
                self.sfx_chan(ch, a1)

    def sfx_chan(self, ch, a1):
        m = self
        hw = 0xa0 + ch * 16
        d2 = 1 << ch
        a4 = m.SHADOW + ch * 12
        c = (m.r8(a1 + 0x12) - 1) & 0xff
        m.w8(a1 + 0x12, c)
        if c == 0:
            m.w8(a1 + 0x18, 0)
            m.cw(0x96, d2)
            m.w8(a4 + 0xb, 0)
            if m.r8(a4 + 0xa):
                m.cwl(hw + 0, m.r32(a4 + 0))
                m.cw(hw + 4, m.r16(a4 + 4))
                m.cw(hw + 6, m.r16(a4 + 6))
                m.cw(hw + 8, m.r16(a4 + 8))
                m.cw(0x96, 0x8200 | d2)
            return
        if m.r8(a1 + 0x15):
            return
        if m.r8(a1 + 0xf):
            c = (m.r8(a1 + 0x17) - 1) & 0xff
            m.w8(a1 + 0x17, c)
            if c == 0:
                m.w8(a1 + 0x17, m.r8(a1 + 0xf))
                d0 = m.r32(a1 + 4)
                b = m.r8(a1 + 0x10)
                carry = b & 1
                b = ((b >> 1) | (carry << 7)) & 0xff
                if not carry: d0 = ((d0 << 16) | (d0 >> 16)) & 0xffffffff
                m.w8(a1 + 0x10, b)
                m.w16(a1 + 8, m.r16(a1 + 8) + (d0 & 0xffff))
        m.w16(a1 + 8, m.r16(a1 + 8) + m.r16(a1 + 0))
        if m.r8(a1 + 0xe):
            c = (m.r8(a1 + 0x16) - 1) & 0xff
            m.w8(a1 + 0x16, c)
            if c == 0:
                m.w8(a1 + 0x16, m.r8(a1 + 0xe))
                m.w16(a1 + 8, m.r16(a1 + 2))
        c = (m.r8(a1 + 0x19) - 1) & 0xff
        m.w8(a1 + 0x19, c)
        if c == 0:
            m.w8(a1 + 0x19, m.r8(a1 + 0x13))
            a2 = m.r32(a1 + 0x1a)
            v = m.r8(a2); a2 += 1
            if not v & 0x80:
                m.w32(a1 + 0x1a, a2)
                m.cw(hw + 8, sx8(v) & 0xffff)
        d1 = m.r16(a1 + 8)
        if sx16(d1) < 0x7c: d1 = 0x7c
        m.cw(hw + 6, d1)
        d1 = m.r32(a1 + 0xa)
        b = m.r8(a1 + 0x11)
        carry = b & 1
        b = ((b >> 1) | (carry << 7)) & 0xff
        if not carry: d1 = ((d1 << 16) | (d1 >> 16)) & 0xffffffff
        m.w8(a1 + 0x11, b)
        m.cwl(hw + 0, (m.r32(m.SFXWAVE) + sx16(d1 & 0xffff)) & 0xffffffff)
        m.cw(0x96, 0x8200 | d2)

    # =====================================================================
    # kernel wrappers. opts = byte $66(a6) = $12e44 : bit0 music on, bit1 fx on (default 3)
    def k_music(self, d0, opts=3):
        if opts & 1:
            self.init_song(d0)
        else:
            self.stop()
        self.w16(self.MVOL, 0x40)

    def k_music_off(self):
        self.stop()
        self.w16(self.MVOL, 0)

    def k_fade(self):
        v = self.r16(self.MVOL)
        if v: self.w16(self.MVOL, v - 1)

    def k_sfx(self, d0, opts=3):
        if not opts & 2:
            return
        d0 &= 0xff
        if not d0 & 0x80:
            if self.r8(0x4012):
                d0 |= 0x200
            self.sfx(d0)
        elif d0 >= 0x82:
            self.sfx(d0)
            self.sfx(d0 | 0x200)
        else:
            self.sfx(d0 | 0x100)
            self.sfx(d0 | 0x300)


# ---------------------------------------------------------------------------
class Paula:
    """Mixer identical to tools/amiga/emu.c audio_line() (for sample-exact comparison with --wav).
    Driver.log entries with reg -1 (CIA LED bit) and -2 (busy-wait of N raster lines) are not register writes.
    313 lines/frame, 50 frames/s, 44100 Hz output, clock 3546895, ch0+3 left, ch1+2 right, *3 gain."""
    LINES = 313

    def __init__(self, ram):
        self.m = ram
        self.regs = [0] * 0x100
        self.dmacon = 0
        self.acc = 0.0
        self.ch = [dict(lc=0, ptr=0, len=0, cnt=0, active=0, phase=0.0, cur=0) for _ in range(4)]
        self.bytepos = [0, 0, 0, 0]
        self.out = bytearray()

    def write(self, reg, v):
        if reg < 0: return
        if reg == 0x96:
            if v & 0x8000: self.dmacon |= v & 0x7ff
            else: self.dmacon &= ~(v & 0x7ff)
            return
        self.regs[reg >> 1] = v & 0xffff

    def ptr(self, base):
        return ((self.regs[base >> 1] << 16) | self.regs[(base + 2) >> 1]) & 0x7fffe

    def line(self):
        import struct
        self.acc += 44100.0 / (50.0 * self.LINES)
        while self.acc >= 1.0:
            self.acc -= 1.0
            l = r = 0
            for c in range(4):
                a = self.ch[c]
                base = 0xa0 + c * 16
                en = (self.dmacon & 0x200) and (self.dmacon & (1 << c))
                if not en:
                    a['active'] = 0
                    continue
                if not a['active']:
                    a['lc'] = self.ptr(base); a['ptr'] = a['lc']
                    a['len'] = self.regs[(base + 4) >> 1]; a['cnt'] = a['len']
                    a['active'] = 1; a['phase'] = 0.0
                per = self.regs[(base + 6) >> 1]
                if per < 64: per = 64
                a['phase'] += 3546895.0 / per / 44100.0
                while a['phase'] >= 1.0:
                    a['phase'] -= 1.0
                    self.bytepos[c] += 1
                    if self.bytepos[c] >= 2:
                        self.bytepos[c] = 0
                        a['ptr'] += 2
                        a['cnt'] = (a['cnt'] - 1) & 0xffff
                        if a['cnt'] == 0:
                            a['ptr'] = self.ptr(base); a['cnt'] = self.regs[(base + 4) >> 1]
                    b = self.m[(a['ptr'] + self.bytepos[c]) & 0x7ffff]
                    a['cur'] = b - 256 if b & 0x80 else b
                vol = self.regs[(base + 8) >> 1] & 0x7f
                if vol > 64: vol = 64
                s = a['cur'] * vol
                if c == 0 or c == 3: l += s
                else: r += s
            def clip(x):
                x *= 3
                x &= 0xffff  # emulator casts to int16 (wraps)
                return x
            self.out += struct.pack('<HH', clip(l), clip(r))
