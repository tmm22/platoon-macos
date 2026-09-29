// David Whittaker music + sound-effect driver, main program $2800-$3ff8 (Platoon, Ocean 1988).
// Spec: re/audio/NOTES.md; annotated listing re/audio/audio.s; reference implementation re/audio/replayer.py.
//
// Translation notes
// - All state lives at its original address (a3 = $2800 base): globals $2d96-$2dab, channel structs $2dac,
//   instrument table $2f48, sfx structs $3ffa, shadow registers $4084 ... Song data, envelopes, arpeggios,
//   samples and synth waveforms are read in place from the resident image loaded from the ADF.
// - Paula is written through `chip.write` in exactly the original order (move.l to AUDxLC = two word writes,
//   high word first). The virtual Paula restarts a voice on every DMA off->on transition and latches LC/LEN
//   when DMA is switched on, so the original's busy-wait loops ($3d64, $3eaa: "let Paula see the DMA off") are
//   dropped: a trigger is atomic and the restart still happens at the DMACON write.
// - The pattern command jump table at $2d80 is read from RAM and dispatched on the original handler address.
// - Command $84 leaves `play` through `bra api_stop` (non-local return to play's caller): modelled by
//   `md_channelTick` returning false.

/// Host-side instrumentation (not game logic): receives every custom-register write made by the driver,
/// in order (used by platoon-headless --reglog to compare with the emulator / Python replayer).
public enum MusicDriverTrace {
    public static var write: ((_ reg: Int, _ value: UInt16) -> Void)?
}

/// Original RAM addresses used by the driver (absolute; a3 = $2800).
enum MD {
    static let base: UInt32 = 0x2800          // a3
    static let cmdJumpTable: UInt32 = 0x2d80  // 11 words rel $2800: handlers of pattern commands $80-$8a
    static let tempo: UInt32 = 0x2d96         // w  duration unit
    static let masterVol: UInt32 = 0x2d98     // w  0..64
    static let speed: UInt32 = 0x2d9a         // b
    static let speedCopy: UInt32 = 0x2d9b     // b  (never read)
    static let speedAcc: UInt32 = 0x2d9c      // b
    static let songLoaded: UInt32 = 0x2d9d    // b
    static let tablesBuilt: UInt32 = 0x2d9e   // b
    static let playing: UInt32 = 0x2d9f       // b
    static let gTranspose: UInt32 = 0x2da0    // b
    static let ntscCount: UInt32 = 0x2da1     // b
    static let ntscEnable: UInt32 = 0x2da2    // b
    static let silencePtr: UInt32 = 0x2da4    // l  -> 64 zero bytes ($89c0)
    static let pwmDir: UInt32 = 0x2da8        // w
    static let pwmOfs: UInt32 = 0x2daa        // w
    static let chan: UInt32 = 0x2dac          // 4 x $30 channel structs
    static let periodTable: UInt32 = 0x2e6c   // words (not range checked: continues into $2efc)
    static let arpTable: UInt32 = 0x2efc      // 13 words rel $2800
    static let arpDefault: UInt32 = 0x2f16    // "00 80" = no arpeggio
    static let instruments: UInt32 = 0x2f48   // 8 x 12: l ptr, l loop, w len words, w period mult
    static let inst5Ptr: UInt32 = 0x2f84      // instrument 5 sample pointer (PWM waveform)
    static let inst5Len: UInt32 = 0x2f8c      // instrument 5 length (words)
    static let songTable: UInt32 = 0x2fa8     // 7 x 10
    static let smpSfxBuilt: UInt32 = 0x3c8e   // b
    static let smpSfxTable: UInt32 = 0x3d72   // 5 x 16: l ptr, l loop, w len, w period, b frames, b long
    static let sfxChan: UInt32 = 0x3ffa       // 4 x $22 sfx channel structs
    static let sfxRequest: UInt32 = 0x4082    // w  (channel<<8)|id; byte $4082 = channel
    static let shadow: UInt32 = 0x4084        // 4 x 12: l ptr, w len, w per, w vol, b music-active, b sfx-owns
    static let sfxDefs: UInt32 = 0x40b4       // 12 x 22 synth sfx definitions
    static let sfxEnvTable: UInt32 = 0x41bc   // 3 words rel $2800
    static let sfxWavePtr: UInt32 = 0x41fc    // l  -> $8a00
    static let envTable: UInt32 = 0x4200      // 16 words rel $2800
    static let samples: UInt32 = 0x430a       // 8 chained instrument samples (l len, w rate, data)
    static let smpSfxSamples: UInt32 = 0x8d02 // 5 chained sfx samples
    static let ntscClock: UInt32 = 0x369e99   // 3579545

    @inline(__always) static func chanStruct(_ ch: Int) -> UInt32 { chan + UInt32(ch * 0x30) }
    @inline(__always) static func sfxStruct(_ ch: Int) -> UInt32 { sfxChan + UInt32(ch * 0x22) }
    @inline(__always) static func shadowRegs(_ ch: Int) -> UInt32 { shadow + UInt32(ch * 12) }
}

extension Platoon {
    // MARK: helpers

    /// `base + (w).w` : address plus sign-extended word index (68k `(a3,a2.w)`, `movea.w` + `adda.l`).
    @inline(__always) private func md_ix(_ base: UInt32, _ w: UInt16) -> UInt32 {
        base &+ UInt32(bitPattern: Int32(Int16(bitPattern: w)))
    }
    /// Custom register write by the driver (`move.w x,$dffxxx`).
    @inline(__always) private func md_hw(_ reg: Int, _ v: UInt16) {
        MusicDriverTrace.write?(reg, v)
        chip.write(reg, v)
    }
    /// `move.l x,$dffxxx` = two word writes, high word first.
    @inline(__always) private func md_hwL(_ reg: Int, _ v: UInt32) {
        md_hw(reg, UInt16(v >> 16))
        md_hw(reg + 2, UInt16(truncatingIfNeeded: v))
    }
    /// `divu.w src,dst`: remainder in the high word, quotient in the low word; on overflow dst is unchanged.
    @inline(__always) private func md_divu(_ d: UInt32, _ s: UInt16) -> UInt32 {
        guard s != 0 else { fatalError("music driver: divu by zero") }
        let q = d / UInt32(s), r = d % UInt32(s)
        if q > 0xffff { return d }
        return r << 16 | q
    }
    /// `bset #1,$bfe001`: CIA-A PRA bit 1 (power LED off = audio filter off). Read-modify-write of the port.
    private func md_ledOff() {
        chip.ciaA.write(0, chip.ciaA.read(0) | 0x02)
    }
    /// `mulu.w d2,d1 ; lsr.w #6,d1`: volume * master volume / 64 (the shift acts on the low word only).
    @inline(__always) private func md_scaleVolume(_ d1: UInt16) -> UInt16 {
        UInt16(truncatingIfNeeded: UInt32(d1) &* UInt32(mem.r16(MD.masterVol))) >> 6
    }
    /// $2afc/$2b6c: period = pertab[note] * instrument multiplier >> 10 (32-bit product and shift, low word kept).
    @inline(__always) private func md_period(_ note: UInt8, _ a5: UInt32) -> UInt16 {
        let d1 = mem.r16(a5 &+ 0xa)
        let d0 = UInt32(mem.r16(MD.periodTable &+ UInt32(note) * 2))
        return UInt16(truncatingIfNeeded: (d0 &* UInt32(d1)) >> 10)
    }

    // MARK: API jump block $2800 (the movem save/restore of the entries has no Swift equivalent)

    /// $2800 api_init_song -> $2854.
    func md_initSong_impl(_ d0: UInt8) { md_init_song(d0) }
    /// $280e api_play -> $2990.
    func md_play_impl() { md_play_tick() }
    /// $281c api_stop -> $28e8.
    func md_stop_impl() { md_stop_all() }
    /// $2838 api_sfx -> $3c90.
    func md_sfx_impl(_ d0: UInt16) { md_sfx_trigger(d0) }
    /// $282a api_resume -> $2960 (never called by the game).
    func md_resume() { md_resume_impl() }
    /// $2846 api_sfx_stop_all -> $2942 (never called by the game).
    func md_sfxStopAll() { md_sfx_stop_all() }

    // MARK: song control

    /// $2854 init_song: LED/filter off, stop, build tables, set tempo/speed, reset the 4 channel structs.
    private func md_init_song(_ song: UInt8) {
        md_ledOff()
        md_stop_impl()                                    // bsr api_stop
        md_init_tables()
        mem.w8(MD.gTranspose, 0)
        // ext.w d0 ; mulu.w #$a,d0 -> used as a signed word index
        var d0 = UInt16(truncatingIfNeeded: UInt32(UInt16(bitPattern: Int16(Int8(bitPattern: song)))) &* 10)
        mem.w16(MD.tempo, UInt16(bitPattern: Int16(mem.s8(md_ix(MD.songTable, d0)))))
        mem.w8(MD.speed, mem.r8(md_ix(MD.songTable &+ 1, d0)))
        mem.w8(MD.speedCopy, mem.r8(MD.speed))
        for d7 in 0..<4 {                                 // $2892 init_song_chan
            let a1 = MD.chanStruct(d7)
            mem.w16(a1 &+ 0x1e, 1)                        // counter := 1 -> first tick reads the pattern
            mem.w8(a1 &+ 0x00, 0)                         // flags
            mem.w8(a1 &+ 0x01, 0)                         // vibrato
            mem.w8(a1 &+ 0x03, 0)                         // channel transpose
            mem.w8(a1 &+ 0x16, 0xff)                      // loop-pending := $ff
            mem.w32(a1 &+ 0x0c, MD.arpDefault)
            mem.w32(a1 &+ 0x10, MD.arpDefault)
            let seq = mem.r16(md_ix(MD.songTable &+ 2, d0)) // movea.w 2(a0,d0.w),a0
            mem.w16(a1 &+ 0x08, seq)
            mem.w16(a1 &+ 0x0a, 2)                        // entry 0 is loaded now
            mem.w32(a1 &+ 0x04, md_ix(MD.base, mem.r16(md_ix(MD.base, seq))))
            d0 = d0 &+ 2
        }
        mem.w8(MD.playing, 0xff)
        mem.w8(MD.songLoaded, 0xff)
    }

    /// $28e8 stop: playing off, all sfx inactive, shadow +$a/+$b cleared, audio DMA off, volumes 0.
    private func md_stop_all() {
        mem.w8(MD.playing, 0)
        for ch in 0..<4 { mem.w8(MD.sfxStruct(ch) &+ 0x18, 0) }
        for ch in 0..<4 { mem.w16(MD.shadowRegs(ch) &+ 0xa, 0) }   // clr.w: music-active AND sfx-owns
        md_hw(0x096, 0x000f)
        md_hw(0x09e, 0x00ff)
        md_hw(0x0a8, 0)
        md_hw(0x0b8, 0)
        md_hw(0x0c8, 0)
        md_hw(0x0d8, 0)
    }

    /// $2942 sfx_stop_all: every sfx ends at the next sfx_update.
    private func md_sfx_stop_all() {
        for ch in 0..<4 { mem.w8(MD.sfxStruct(ch) &+ 0x12, 1) }
    }

    /// $2960 resume: if a song is loaded, re-enable the 4 audio DMA channels and the playing flag.
    private func md_resume_impl() {
        guard mem.r8(MD.songLoaded) != 0 else { return }
        md_hw(0x09e, 0x00ff)
        var d1: UInt16 = 0x8200
        for d7 in (0...3).reversed() { d1 |= 1 << UInt16(d7) }  // bset d7,d1 ; dbra
        md_hw(0x096, d1)
        mem.w8(MD.playing, 0xff)
    }

    // MARK: per-vblank tick

    /// $2990 play: NTSC skip, speed accumulator, PWM waveform step, 4 music channels, then sfx_update.
    private func md_play_tick() {
        if mem.r8(MD.playing) == 0 { md_sfx_update(); return }
        if mem.r8(MD.ntscEnable) != 0 {                   // never enabled by the game
            let c = mem.r8(MD.ntscCount) &- 1
            mem.w8(MD.ntscCount, c)
            if c == 0 { mem.w8(MD.ntscCount, 6); return } // skips the sfx update too
        }
        let (acc, carry) = mem.r8(MD.speedAcc).addingReportingOverflow(mem.r8(MD.speed))
        mem.w8(MD.speedAcc, acc)
        if carry { md_sfx_update(); return }
        // PWM: instrument 5 waveform duty cycle sweep (Paula reads the modified RAM live)
        let a0 = mem.r32(MD.inst5Ptr)
        let d0 = mem.r16(MD.pwmOfs)
        if Int16(bitPattern: mem.r16(MD.pwmDir)) >= 0 {
            mem.w16(md_ix(a0, d0), 0xc0c0)
            mem.w16(MD.pwmOfs, mem.r16(MD.pwmOfs) &+ 2)
            if mem.r16(MD.pwmOfs) == 0x2c { mem.w16(MD.pwmDir, ~mem.r16(MD.pwmDir)) }
        } else {                                          // $29de pwm_narrow
            mem.w16(md_ix(a0, d0), 0x3f3f)
            mem.w16(MD.pwmOfs, mem.r16(MD.pwmOfs) &- 2)
            if mem.r16(MD.pwmOfs) == 0x20 { mem.w16(MD.pwmDir, ~mem.r16(MD.pwmDir)) }
        }
        for d7 in 0..<4 {
            if !md_channelTick(d7) { return }             // cmd $84: stop, leave play without sfx update
        }
        md_sfx_update()
    }

    /// $29f6-$2b42 one music channel tick (d7 = channel). Returns false when pattern command $84 stopped
    /// the song (the original leaves `play` directly through `bra api_stop`).
    private func md_channelTick(_ d7: Int) -> Bool {
        let a4 = MD.shadowRegs(d7)
        mem.w8(a4 &+ 0xa, 0xff)                           // music is using this channel
        let a6 = 0xa0 + d7 * 16                           // AUDxLC register of the channel
        let a0 = MD.chanStruct(d7)
        var a1 = mem.r32(a0 &+ 4)                         // pattern pointer
        var a5 = mem.r32(a0 &+ 0x18)                      // instrument
        @inline(__always) func sfxOwns() -> Bool { mem.r8(a4 &+ 0xb) != 0 }

        if mem.r8(a0 &+ 0x16) == 0 {                      // note started last tick: write the repeat part
            mem.w8(a0 &+ 0x16, 0xff)
            var d0 = mem.r32(a5 &+ 4)                     // loop offset in bytes
            if Int32(bitPattern: d0) < 0 {                // $2a5c one-shot: repeat = silence buffer
                mem.w32(a4, mem.r32(MD.silencePtr))
                mem.w16(a4 &+ 4, 0x20)
                if !sfxOwns() {
                    md_hwL(a6, mem.r32(MD.silencePtr))
                    md_hw(a6 + 4, 0x20)
                }
            } else {
                let a2 = mem.r32(a5) &+ d0
                d0 >>= 1
                let d1 = mem.r16(a5 &+ 8) &- UInt16(truncatingIfNeeded: d0)
                mem.w32(a4, a2)
                mem.w16(a4 &+ 4, d1)
                if !sfxOwns() {
                    md_hwL(a6, a2)
                    md_hw(a6 + 4, d1)
                }
            }
        }
        // $2a7a chan_count
        let cnt = mem.r16(a0 &+ 0x1e) &- 1
        mem.w16(a0 &+ 0x1e, cnt)
        if cnt != 0 {
            if cnt != 1 { md_effects(d7, a0: a0, a4: a4, a5: a5, a6: a6); return true }
            // last tick of the event: DMA off (1-tick gap) unless the next byte is a tie
            if !sfxOwns() && mem.r8(a1) != 0x83 { md_hw(0x096, 1 << UInt16(d7)) }
            return true
        }
        // $2aa4 chan_event: read pattern bytes until an event
        mem.w8(a0, 0)
        while true {
            let b = mem.r8(a1); a1 &+= 1
            if b < 0x80 {
                // note
                mem.w8(a0 &+ 2, b)
                let note = b &+ mem.r8(MD.gTranspose) &+ mem.r8(a0 &+ 3)
                let a2 = mem.r32(a0 &+ 0x22)              // volume envelope: first byte = initial volume
                let d1b = mem.r8(a2)
                mem.w32(a0 &+ 0x26, a2 &+ 1)
                mem.w8(a0 &+ 0x2b, mem.r8(a0 &+ 0x2a))
                let d1 = UInt16(bitPattern: Int16(Int8(bitPattern: d1b)))   // ext.w
                mem.w32(a4, mem.r32(a5))
                mem.w16(a4 &+ 4, mem.r16(a5 &+ 8))
                let vol = md_scaleVolume(d1)
                mem.w16(a4 &+ 8, vol)
                if !sfxOwns() {
                    md_hwL(a6, mem.r32(a5))
                    md_hw(a6 + 4, mem.r16(a5 &+ 8))
                    md_hw(a6 + 8, vol)
                }
                // $2afc note_period
                let per = md_period(note, a5)
                mem.w16(a4 &+ 6, per)
                if !sfxOwns() { md_hw(a6 + 6, per) }
                mem.w8(a0 &+ 0x16, 0)                     // loop pending
                md_noteCommitTie(d7, a0: a0, a1: a1)
                return true
            }
            // $2c3c cmd_dispatch (signed byte compares: b is in $80..$ff)
            if b >= 0xe0 {                                // duration = (b - $df) * tempo
                mem.w16(a0 &+ 0x1c, UInt16(truncatingIfNeeded: UInt32(b &- 0xdf) &* UInt32(mem.r16(MD.tempo))))
                continue
            }
            if b >= 0xc0 {                                // instrument
                a5 = MD.instruments &+ UInt32(b &- 0xc0) * 12
                mem.w32(a0 &+ 0x18, a5)
                continue
            }
            if b >= 0xb0 {                                // volume envelope; speed = byte before the data
                let a2 = md_ix(MD.base, mem.r16(MD.envTable &+ UInt32(b &- 0xb0) * 2))
                mem.w32(a0 &+ 0x22, a2)
                mem.w8(a0 &+ 0x2a, mem.r8(a2 &- 1))
                continue
            }
            if b >= 0xa0 {                                // arpeggio table
                let a2 = md_ix(MD.base, mem.r16(MD.arpTable &+ UInt32(b &- 0xa0) * 2))
                mem.w32(a0 &+ 0x0c, a2)
                mem.w32(a0 &+ 0x10, a2)
                continue
            }
            // $2cb4 cmd_80_jump: add.b d0,d0 ; movea.w (jumptab,d0.w),a2 ; jmp (a3,a2.w)
            let target = md_ix(MD.base, mem.r16(MD.cmdJumpTable &+ UInt32(b &<< 1)))
            switch target {
            case 0x2cc2:                                  // $80 end of pattern: next sequence entry
                var d0 = mem.r16(a0 &+ 0xa)
                var a2 = mem.r16(a0 &+ 8) &+ d0
                d0 &+= 2
                if mem.r16(md_ix(MD.base, a2)) == 0 {     // 0 word: restart the sequence at entry 0
                    a2 = mem.r16(a0 &+ 8)
                    d0 = 2
                }
                a1 = md_ix(MD.base, mem.r16(md_ix(MD.base, a2)))
                mem.w16(a0 &+ 0xa, d0)
            case 0x2ce8:                                  // $81 portamento: speed, delay
                mem.w16(a0 &+ 0x20, 0)
                mem.w8(a0 &+ 0x14, mem.r8(a1)); a1 &+= 1
                mem.w8(a0 &+ 0x15, mem.r8(a1)); a1 &+= 1
                mem.w8(a0, mem.r8(a0) | 0x02)
            case 0x2cfe:                                  // $82 rest (DMA was switched off at counter == 1)
                mem.w16(a0 &+ 0x1e, mem.r16(a0 &+ 0x1c))
                mem.w32(a0 &+ 4, a1)
                mem.w32(a4, mem.r32(MD.silencePtr))
                mem.w16(a4 &+ 4, 0x20)
                if !sfxOwns() {
                    md_hwL(a6, mem.r32(MD.silencePtr))
                    md_hw(a6 + 4, 0x20)
                }
                return true
            case 0x2d2a:                                  // $83 tie: extend, no retrigger
                md_noteCommitTie(d7, a0: a0, a1: a1)
                return true
            case 0x2d2e:                                  // $84 end of song (unused by the data)
                mem.w8(MD.songLoaded, 0)
                md_stop_impl()                            // bra api_stop -> returns out of play
                return false
            case 0x2d36:                                  // $85 global transpose
                mem.w8(MD.gTranspose, mem.r8(a1)); a1 &+= 1
            case 0x2d3e:                                  // $86 vibrato on: speed, depth
                mem.w8(a0 &+ 1, 0xff)
                mem.w8(a0 &+ 0x2c, mem.r8(a1)); a1 &+= 1
                mem.w8(a0 &+ 0x2e, mem.r8(a1)); a1 &+= 1
                mem.w8(a0 &+ 0x2d, 0)
            case 0x2d52:                                  // $87 vibrato off
                mem.w8(a0 &+ 1, 0)
            case 0x2d5a:                                  // $88 channel transpose
                mem.w8(a0 &+ 3, mem.r8(a1)); a1 &+= 1
            case 0x2d62:                                  // $89 new sequence (unused by the data)
                mem.w8(a0 &+ 8, mem.r8(a1)); a1 &+= 1
                mem.w8(a0 &+ 9, mem.r8(a1)); a1 &+= 1
                mem.w16(a0 &+ 0xa, 0)
            case 0x2d74:                                  // $8a tempo (unused by the data)
                mem.w16(MD.tempo, UInt16(bitPattern: Int16(mem.s8(a1)))); a1 &+= 1
            default:
                // $8b-$9f overrun the jump table in the original (never used by the song data)
                fatalError(String(format: "music driver: undefined pattern command $%02X at $%06X", b, a1 &- 1))
            }
        }
    }

    /// $2b26 note_commit_tie: save pattern pointer, reload the counter, DMA on (even if a sfx owns the channel).
    @inline(__always) private func md_noteCommitTie(_ d7: Int, a0: UInt32, a1: UInt32) {
        mem.w32(a0 &+ 4, a1)
        mem.w16(a0 &+ 0x1e, mem.r16(a0 &+ 0x1c))
        md_hw(0x096, 0x8200 | 1 << UInt16(d7))
    }

    /// $2b4a chan_effects (counter >= 2 after the decrement): arpeggio, portamento, vibrato, volume envelope.
    private func md_effects(_ d7: Int, a0: UInt32, a4: UInt32, a5: UInt32, a6: Int) {
        var note = mem.r8(a0 &+ 2) &+ mem.r8(MD.gTranspose) &+ mem.r8(a0 &+ 3)
        var a1 = mem.r32(a0 &+ 0x10)
        var d1 = mem.r8(a1); a1 &+= 1
        if d1 & 0x80 != 0 {                               // bclr #7: last entry -> restart the list
            d1 &= 0x7f
            a1 = mem.r32(a0 &+ 0x0c)
        }
        mem.w32(a0 &+ 0x10, a1)
        note = note &+ d1
        var d0 = md_period(note, a5)
        if mem.r8(a0) & 0x02 != 0 {                       // portamento
            if mem.r8(a0 &+ 0x15) != 0 {
                mem.w8(a0 &+ 0x15, mem.r8(a0 &+ 0x15) &- 1)
            } else {                                      // $2b98 fx_slide
                let s = UInt16(bitPattern: Int16(mem.s8(a0 &+ 0x14)))
                mem.w16(a0 &+ 0x20, mem.r16(a0 &+ 0x20) &+ s)
                d0 = d0 &- mem.r16(a0 &+ 0x20)
            }
        }
        let vib = mem.r8(a0 &+ 1)                         // $2ba6 fx_vibrato
        if vib != 0 {
            var pos: UInt8
            if vib & 0x80 != 0 {                          // up: pos += speed, flip at depth
                pos = mem.r8(a0 &+ 0x2d) &+ mem.r8(a0 &+ 0x2c)
                mem.w8(a0 &+ 0x2d, pos)
                if pos == mem.r8(a0 &+ 0x2e) { mem.w8(a0 &+ 1, mem.r8(a0 &+ 1) ^ 0x80) }
            } else {                                      // $2bc8 down: pos -= speed, flip at 0
                pos = mem.r8(a0 &+ 0x2d) &- mem.r8(a0 &+ 0x2c)
                mem.w8(a0 &+ 0x2d, pos)
                if pos == 0 { mem.w8(a0 &+ 1, mem.r8(a0 &+ 1) ^ 0x80) }
            }
            if mem.r8(a0 &+ 0x2d) == 0 { mem.w8(a0 &+ 1, mem.r8(a0 &+ 1) ^ 0x01) }   // $2bdc sign flip
            let v = UInt16(bitPattern: Int16(Int8(bitPattern: pos)))
            if mem.r8(a0 &+ 1) & 0x01 != 0 { d0 = d0 &+ v } else { d0 = d0 &- v }
        }
        mem.w16(a4 &+ 6, d0)                              // $2bf8 fx_set_period
        if mem.r8(a4 &+ 0xb) == 0 { md_hw(a6 + 6, d0) }
        // $2c06 fx_envelope: subq.b #1 ; bcc -> step only when the counter underflows
        let c = mem.r8(a0 &+ 0x2b)
        mem.w8(a0 &+ 0x2b, c &- 1)
        if c != 0 { return }
        mem.w8(a0 &+ 0x2b, mem.r8(a0 &+ 0x2a))
        let a2 = mem.r32(a0 &+ 0x26)
        let v = mem.r8(a2)
        if v & 0x80 == 0 { mem.w32(a0 &+ 0x26, a2 &+ 1) } // bit 7 = last value: hold
        let vol = md_scaleVolume(UInt16(v & 0x7f))
        mem.w16(a4 &+ 8, vol)
        if mem.r8(a4 &+ 0xb) == 0 { md_hw(a6 + 8, vol) }
    }

    // MARK: tables

    /// $3bce init_tables (once): instrument table from the chained samples at $430a, silence pointer,
    /// synth waveform pointer, initial PWM waveform of instrument 5.
    private func md_init_tables() {
        if mem.r8(MD.tablesBuilt) != 0 { return }
        var a0 = MD.samples
        var a5 = MD.instruments
        for _ in 0...7 {
            var d2 = mem.r32(a0); a0 &+= 4                // length in bytes
            let d3 = mem.r16(a0); a0 &+= 2                // rate in Hz
            mem.w32(a5, a0)
            a0 &+= d2
            d2 >>= 1
            mem.w16(a5 &+ 8, UInt16(truncatingIfNeeded: d2))
            d2 = md_divu(MD.ntscClock, d3)                // period multiplier = 3579545 / rate
            mem.w16(a5 &+ 0xa, UInt16(truncatingIfNeeded: d2))
            a5 &+= 12
        }
        mem.w32(MD.silencePtr, a0)                        // 64 zero bytes after the last sample
        a0 &+= 0x40
        mem.w32(MD.sfxWavePtr, a0)                        // synth sfx waveforms ($8a00)
        a0 = mem.r32(MD.inst5Ptr)                         // PWM square: 32 x $c0, 32 x $3f
        for _ in 0...15 { mem.w16(a0, 0xc0c0); a0 &+= 2 }
        for _ in 0...15 { mem.w16(a0, 0x3f3f); a0 &+= 2 }
        mem.w16(MD.inst5Len, 0x20)
        mem.w16(MD.pwmOfs, 0x20)
        mem.w16(MD.pwmDir, 0)
        mem.w8(MD.tablesBuilt, 0xff)
    }

    /// $3c42 init_smp_sfx (once): sample sfx table from the 5 chained samples at $8d02.
    private func md_init_smp_sfx() {
        if mem.r8(MD.smpSfxBuilt) != 0 { return }
        var a0 = MD.smpSfxSamples
        var a5 = MD.smpSfxTable
        for _ in 0...4 {
            var d2 = UInt32(mem.r16(a0 &+ 2)) &* 0x32      // frames = len_lo * 50 / rate + 1 (byte)
            d2 = md_divu(d2, mem.r16(a0 &+ 4))
            mem.w8(a5 &+ 0xc, UInt8(truncatingIfNeeded: d2) &+ 1)
            d2 = mem.r32(a0); a0 &+= 4
            let d3 = mem.r16(a0); a0 &+= 2
            mem.w32(a5, a0)
            a0 &+= d2
            d2 >>= 1
            mem.w16(a5 &+ 8, UInt16(truncatingIfNeeded: d2))
            d2 = md_divu(MD.ntscClock, d3)
            mem.w16(a5 &+ 0xa, UInt16(truncatingIfNeeded: d2))
            a5 &+= 0x10
        }
        mem.w8(MD.smpSfxBuilt, 0xff)
    }

    // MARK: sound effects

    /// $3c90 sfx_trigger, d0.w = (channel << 8) | id: id < $80 synth (0..$b, larger -> 0), $80..$85 sample.
    private func md_sfx_trigger(_ d0in: UInt16) {
        md_ledOff()
        md_hw(0x09e, 0x00ff)
        let d0 = d0in & 0x3ff
        mem.w16(MD.sfxRequest, d0)
        // kill any sfx running on that channel
        for ch in 0..<4 where mem.r8(MD.sfxRequest) == UInt8(ch) { mem.w8(MD.sfxStruct(ch) &+ 0x18, 0) }
        md_init_tables()
        let d7 = UInt32(mem.r8(MD.sfxRequest)) * 12
        mem.w8(MD.shadow &+ d7 &+ 0xb, 0xff)              // sfx owns channel: music writes suppressed
        let idw = UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: d0))))   // ext.w d0
        if Int16(bitPattern: idw) < 0 { md_sfx_sample(idw); return }
        var id = idw
        if Int8(bitPattern: UInt8(truncatingIfNeeded: id)) > 0xb { id &= 0xff00 }   // clr.b d0
        // $3d00 sfx_synth
        let off = UInt32(id & 0xffff) * 0x16
        var a1 = MD.sfxChan
        var d2: UInt16 = 1
        var a0reg = 0x0a4
        var d1 = mem.r8(MD.sfxRequest)
        while true {                                      // $3d14 find the channel
            d1 &-= 1
            if Int8(bitPattern: d1) < 0 { break }
            a1 &+= 0x22; d2 &+= d2; a0reg += 0x10
        }
        mem.w8(a1 &+ 0x18, 0)                             // inactive while setting up
        md_hw(0x096, d2)                                  // DMA off
        md_hw(a0reg, 0x40)                                // AUDxLEN := 64 words
        let a2 = a1
        var src = MD.sfxDefs &+ off
        for _ in 0...10 { mem.w16(a1, mem.r16(src)); a1 &+= 2; src &+= 2 }   // copy the 22-byte definition
        mem.w16(a2 &+ 0x16, mem.r16(a2 &+ 0xe))           // counters := intervals
        mem.w8(a2 &+ 0x19, 1)                             // envelope counter
        let e = UInt16(bitPattern: Int16(mem.s8(a2 &+ 0x14))) &* 2
        mem.w32(a2 &+ 0x1a, md_ix(MD.base, mem.r16(md_ix(MD.sfxEnvTable, e))))
        // $3d64: dbra busy wait (dropped: the trigger is atomic, see the file header)
        mem.w8(a2 &+ 0x18, 0xff)                          // active; DMA is started by the next sfx_update
    }

    /// $3dc2 sfx_sample (id >= $80). d0.w = sign-extended id.
    private func md_sfx_sample(_ d0: UInt16) {
        md_init_smp_sfx()
        let b = Int8(bitPattern: UInt8(truncatingIfNeeded: d0))
        if b > Int8(bitPattern: 0x85) { return }          // $86..$ff ignored (channel stays marked sfx-owned)
        if b != Int8(bitPattern: 0x85) { md_sfx_sample_play(d0); return }
        // $85: sample $83 an octave lower with double duration
        let d0b = (d0 & 0xff00) | UInt16(UInt8(truncatingIfNeeded: d0) &- 2)
        let perAddr = MD.smpSfxTable &+ 3 * 16 &+ 0xa     // $3dac
        let framesAddr = MD.smpSfxTable &+ 3 * 16 &+ 0xc  // $3dae
        mem.w16(perAddr, mem.r16(perAddr) << 1)
        mem.w8(framesAddr, mem.r8(framesAddr) &+ mem.r8(framesAddr))
        md_sfx_sample_play(d0b)
        mem.w16(perAddr, mem.r16(perAddr) >> 1)
        mem.w8(framesAddr, mem.r8(framesAddr) >> 1)
    }

    /// $3df4 sfx_sample_play: start sample sfx d0 on the requested channel.
    private func md_sfx_sample_play(_ d0: UInt16) {
        md_init_smp_sfx()
        let d7 = Int(mem.r8(MD.sfxRequest))
        var a1 = MD.sfxChan
        var d1 = UInt8(d7)
        while true {                                      // $3e04 find the channel
            d1 &-= 1
            if Int8(bitPattern: d1) < 0 { break }
            a1 &+= 0x22
        }
        mem.w8(a1 &+ 0x18, 0)
        mem.w8(a1 &+ 0x15, UInt8(truncatingIfNeeded: d0)) // non-zero -> update only counts the duration
        var d2: UInt16 = 1 << UInt16(d7 & 15)
        md_hw(0x096, d2)
        let a0 = MD.smpSfxTable &+ UInt32(d0 & 0x7f) * 0x10
        mem.w8(a1 &+ 0x12, mem.r8(a0 &+ 0xc))             // duration frames
        if mem.r8(a0 &+ 0xd) != 0 { mem.w8(a1 &+ 0x12, 0) } // long flag -> 256 frames
        md_dma_delay()
        let a6 = 0xa0 + ((d7 << 4) & 0xffff)
        md_hw(a6 + 4, mem.r16(a0 &+ 8))                   // AUDxLEN, AUDxLC, AUDxPER, VOL=64, DMA on
        md_hwL(a6, mem.r32(a0))
        md_hw(a6 + 6, mem.r16(a0 &+ 0xa))
        mem.w16(a1 &+ 0x1e, mem.r16(a0 &+ 0xa))
        mem.w16(a1 &+ 0x20, mem.r16(a0 &+ 0xa))
        md_hw(a6 + 8, 0x40)
        d2 |= 0x8200
        md_hw(0x096, d2)
        mem.w8(a1 &+ 0x18, 0xff)
        md_dma_delay()
        let lp = mem.r32(a0 &+ 4)                         // then the repeat: silence (one-shot) or loop
        if Int32(bitPattern: lp) < 0 {
            md_hwL(a6, mem.r32(MD.silencePtr))
            md_hw(a6 + 4, 0x20)
            return
        }
        let a2 = mem.r32(a0) &+ lp                        // $3e92 sfx_sample_loop
        let len = mem.r16(a0 &+ 8) &- UInt16(truncatingIfNeeded: lp >> 1)
        md_hw(a6 + 4, len)
        md_hwL(a6, a2)
    }

    /// $3eaa dma_delay: `dbra` busy wait of ~5100 cycles so that Paula sees the DMA off/on. Not needed with
    /// the virtual Paula (it latches LC/LEN at the DMACON write and restarts on every off->on edge).
    @inline(__always) private func md_dma_delay() {}

    /// $3eb4 sfx_update: per-vblank processing of the active sfx on channels 0..3.
    private func md_sfx_update() {
        for ch in 0..<4 {
            let a1 = MD.sfxStruct(ch)
            if mem.r8(a1 &+ 0x18) != 0 {
                md_sfx_chan(a1: a1, a0: ch * 0x10, d2: 1 << UInt16(ch), a4: MD.shadowRegs(ch))
            }
        }
    }

    /// $3f16 sfx_chan: a1 = sfx struct, a0 = $dff000 + 16*ch (as an offset), d2 = DMA bit, a4 = shadow regs.
    private func md_sfx_chan(a1: UInt32, a0: Int, d2: UInt16, a4: UInt32) {
        let dur = mem.r8(a1 &+ 0x12) &- 1
        mem.w8(a1 &+ 0x12, dur)
        if dur == 0 {                                     // ended: DMA off, release the channel
            mem.w8(a1 &+ 0x18, 0)
            md_hw(0x096, d2)
            mem.w8(a4 &+ 0xb, 0)
            if mem.r8(a4 &+ 0xa) != 0 {                   // music active: restore its registers, DMA on
                md_hwL(a0 + 0xa0, mem.r32(a4))
                md_hw(a0 + 0xa4, mem.r16(a4 &+ 4))
                md_hw(a0 + 0xa6, mem.r16(a4 &+ 6))
                md_hw(a0 + 0xa8, mem.r16(a4 &+ 8))
                md_hw(0x096, d2 | 0x8200)
            }
            return
        }
        if mem.r8(a1 &+ 0x15) != 0 { return }             // sample sfx: nothing else to do
        if mem.r8(a1 &+ 0xf) != 0 {                       // $3f5c alternate period step every +$f frames
            let c = mem.r8(a1 &+ 0x17) &- 1
            mem.w8(a1 &+ 0x17, c)
            if c == 0 {
                mem.w8(a1 &+ 0x17, mem.r8(a1 &+ 0xf))
                var d0 = mem.r32(a1 &+ 4)
                var p = mem.r8(a1 &+ 0x10)
                let carry = p & 1                         // ror.b #1: carry = bit shifted out
                p = p >> 1 | carry << 7
                if carry == 0 { d0 = d0 << 16 | d0 >> 16 }  // swap: use step A (+4)
                mem.w8(a1 &+ 0x10, p)
                mem.w16(a1 &+ 8, mem.r16(a1 &+ 8) &+ UInt16(truncatingIfNeeded: d0))
            }
        }
        mem.w16(a1 &+ 8, mem.r16(a1 &+ 8) &+ mem.r16(a1))  // $3f84 per-frame delta
        if mem.r8(a1 &+ 0xe) != 0 {                       // period reset every +$e frames
            let c = mem.r8(a1 &+ 0x16) &- 1
            mem.w8(a1 &+ 0x16, c)
            if c == 0 {
                mem.w8(a1 &+ 0x16, mem.r8(a1 &+ 0xe))
                mem.w16(a1 &+ 8, mem.r16(a1 &+ 2))
            }
        }
        let ec = mem.r8(a1 &+ 0x19) &- 1                  // $3fa4 volume envelope every +$13 frames
        mem.w8(a1 &+ 0x19, ec)
        if ec == 0 {
            mem.w8(a1 &+ 0x19, mem.r8(a1 &+ 0x13))
            let a2 = mem.r32(a1 &+ 0x1a)
            let v = mem.r8(a2)
            if v & 0x80 == 0 {                            // byte >= $80: hold (no write)
                mem.w32(a1 &+ 0x1a, a2 &+ 1)
                md_hw(a0 + 0xa8, UInt16(v))               // ext.w of a positive byte
            }
        }
        var per = mem.r16(a1 &+ 8)                        // $3fc2 clamp: signed < $7c -> $7c
        if Int16(bitPattern: per) < 0x7c { per = 0x7c }
        md_hw(a0 + 0xa6, per)
        var d1 = mem.r32(a1 &+ 0xa)                       // waveform offset: pattern bit 1 -> +$c, 0 -> +$a
        var p = mem.r8(a1 &+ 0x11)
        let carry = p & 1
        p = p >> 1 | carry << 7
        if carry == 0 { d1 = d1 << 16 | d1 >> 16 }
        mem.w8(a1 &+ 0x11, p)
        md_hwL(a0 + 0xa0, md_ix(mem.r32(MD.sfxWavePtr), UInt16(truncatingIfNeeded: d1)))
        md_hw(0x096, d2 | 0x8200)                         // DMA on every frame (restarts only if it was off)
    }
}
