// Paula audio: 4 DMA channels (LC/LEN/PER/VOL), block-start interrupts, stereo mixing.
import Foundation
// Produces float stereo samples at `sampleRate`, delivered through `output`.
//
// Hardware model: `accurate` (default) = a real A500 (audio DMA slot limit, A500 + LED filters, port/verify/timing.md);
// false = tools/amiga/emu's Paula, the original port's output (referenceEmulator=1).
//
// Enhancement mixer (OWNER: audio; roadmap S10, M12, M25). With every mixer setting at its default the line is
// rendered by `runLineLegacy`, the original code (bit-identical output with `accurate` off, see port/verify/audio). Any
// non-default setting switches to `runLineMixer`, which steps the voices' DMA state machine in exactly the same
// order and at the same sample points (block-end interrupts and DMA timing are unchanged, so the game cannot
// notice) and only computes the output differently:
//   S10  music / SFX gain per voice (voice tagged by its owner through `voiceIsSfx`, installed by the game layer)
//        and per-voice pan (`pan`, -1 = left ... +1 = right, scaled by `stereoSeparation`).
//   M12  ghost voices: 4 host-only voices fed by the music driver with the music writes an SFX suppressed
//        (`ghostWrite`, never through chip.write; no interrupts). A ghost is heard only while an SFX owns its
//        hardware channel, so the full arrangement survives firefights.
//   M25  band-limited (BLEP) synthesis, ambience reverb on the SFX stem, muting the music voices for a
//        replacement soundtrack played by the host (`musicReplaced`).

public final class Paula {
    public static let clock = 3546895.0   // PAL
    public var sampleRate = 48000.0
    let mem: Memory

    struct Channel {
        var lc: UInt32 = 0, len: UInt16 = 0, per: UInt16 = 0, vol: UInt16 = 0
        var active = false
        var ptr: UInt32 = 0, wordsLeft = 0
        var word: UInt16 = 0, byteIndex = 0
        var phase = 0.0
        var current: Float = 0, previous: Float = 0
        var pendingIRQ = false
        /// A500 model: time (colour clocks from the start of the current line, usually negative) of the oldest DMA
        /// request not yet served by the channel's slot (raised when Paula loaded its last word); -inf = none pending.
        var reqTime = -Double.infinity
    }
    var ch = [Channel](repeating: Channel(), count: 4)
    var dmacon: UInt16 = 0
    var raiseInterrupt: ((UInt16) -> Void)?

    // enhancement settings
    public var interpolate = false          // linear interpolation between samples (off = authentic)
    public var stereoSeparation: Float = 1  // 1 = hard Amiga panning, 0 = mono
    public var filterEnabled = true         // A500 output filters (fixed low-pass; + LED filter in the A500 model)
    /// Real-A500 model (default): at most one audio DMA word per channel and raster line (periods below ~113 can't
    /// be fed: the voice replays its word and the loop runs slower, capping the pitch, as on the hardware), the
    /// A500's fixed 4.42 kHz RC low-pass, and the 3.09 kHz "LED" filter while CIA-A PRA bit 1 drives the power LED
    /// on (`ledOn`, set by the chipset every line). false = tools/amiga/emu's simplified Paula (64-period clamp
    /// only, 4.9 kHz low-pass, no LED filter) for the audio gate (port/verify/audio/wavcmp.sh).
    public var accurate = true
    /// CIA-A PRA bit 1 low (and driven): power LED on = LED filter in (A500 model only).
    public var ledOn = false
    public var volume: Float = 1
    public var musicMuted = false           // (legacy switch: silences all four voices)

    // MARK: enhancement mixer settings (host presentation; defaults = the original output)

    /// M25: synthesis of the voices' output (`.legacy` = the original port's output).
    public var synthesis = PaulaSynthesis.legacy
    /// S10: gain of the voices playing music / sound effects (1 = original).
    public var musicGain: Float = 1
    public var sfxGain: Float = 1
    /// S10: pan of the four voices, -1 = left ... +1 = right (Amiga: 0 and 3 left, 1 and 2 right).
    public static let amigaPan: [Float] = [-1, 1, 1, -1]
    public var pan: [Float] = Paula.amigaPan
    /// S10: owner tag of hardware voice c (true = a sound effect owns it). Installed by the game layer
    /// (Game/Audio/AudioEnhance.swift reads the music driver's shadow block), so Paula knows no game RAM. Sampled
    /// once per beam line. nil = everything is music.
    public var voiceIsSfx: ((Int) -> Bool)?
    /// M12: ghost voices on (the music driver feeds them only while this is set).
    public var ghostVoices = false
    /// M25: a host replacement soundtrack plays: the music-tagged voices and the ghosts are silent.
    public var musicReplaced = false
    /// M25: ambience reverb on the SFX stem; `.auto` uses `ambienceArea` (set by the game layer every vblank).
    public var ambience = PaulaAmbience.off
    public var ambienceArea = PaulaAmbience.off
    /// Ambience amount (1 = the preset's level).
    public var ambienceLevel: Float = 1
    /// M25 replacement soundtrack: the music driver counts song starts here while `cueSongs` is set (host
    /// bookkeeping only; the host polls `songCues` / `cuedSong`).
    public var cueSongs = false
    public internal(set) var songCues = 0
    public internal(set) var cuedSong = -1
    /// Game-layer bookkeeping: the run (Platoon object) that last configured this Paula (Game/Audio).
    var configuredRun: ObjectIdentifier?

    /// True when the next line is rendered by the enhancement mixer instead of the original code.
    public var mixerActive: Bool {
        synthesis != .legacy || musicGain != 1 || sfxGain != 1 || pan != Paula.amigaPan || ghostVoices || musicReplaced
            || effectiveAmbience != .off || reverbTail > 0
    }
    var effectiveAmbience: PaulaAmbience { ambience == .auto ? ambienceArea : ambience }

    var lpL: Float = 0, lpR: Float = 0
    var ledFilter = PaulaLEDFilter()
    /// A500 audio DMA model: time of the output sample being computed (colour clocks from the start of its line).
    var sampleTime = 0.0
    static let lineClocks = 227.0

    /// A500 model, called when voice `c` has played both bytes of its word: Agnus serves an audio DMA request in the
    /// channel's slot (once per line, colour clock 13 + 2c), so the next word is there only if a slot passed since
    /// the request (= the previous word load). Periods of 114 and more always get it; below, Paula replays the old
    /// word and the loop advances at most one word per line (the pitch is capped, as on the hardware).
    @inline(__always) func dmaWordReady(_ v: inout Channel, _ c: Int) -> Bool {
        var per = Double(v.per); if per < 64 { per = 64 }
        let t = sampleTime - v.phase * per                  // when the word ran out (phase = periods since then)
        let slot = 13 + 2 * Double(c)
        let served = (t - slot) / Paula.lineClocks
        let requested = (v.reqTime - slot) / Paula.lineClocks
        guard v.reqTime == -Double.infinity || served.rounded(.down) > requested.rounded(.down) else { return false }
        v.reqTime = t                                       // this load raises the next request
        return true
    }
    var sampleAcc = 0.0

    /// Coefficient of the fixed one-pole low-pass (1 = off). A500 model: the 360 ohm / 0.1 uF RC (4421 Hz), discretised
    /// like vAmiga's OnePoleFilter; emulator model: the original port's 4.9 kHz.
    var outputAlpha: Float {
        guard filterEnabled else { return 1 }
        if !accurate { return Float(1 - exp(-2 * Double.pi * 4900 / sampleRate)) }
        if alphaRate != sampleRate {
            let fc = 1 / (2 * Double.pi * 360 * 1e-7)
            let a = 2 - cos(2 * Double.pi * fc / sampleRate)
            alphaCache = Float(1 - (a - (a * a - 1).squareRoot()))
            alphaRate = sampleRate
        }
        return alphaCache
    }
    private var alphaRate = 0.0, alphaCache: Float = 1
    /// Receives interleaved stereo samples for each rendered line.
    public var output: ((UnsafeBufferPointer<Float>) -> Void)?
    var lineBuf = [Float](repeating: 0, count: 64)

    init(memory: Memory) { mem = memory }

    public func reset() { ch = [Channel](repeating: Channel(), count: 4); dmacon = 0 }

    func registerWritten(channel c: Int, offset: Int, value v: UInt16) {
        switch offset {
        case 0: ch[c].lc = (ch[c].lc & 0xffff) | UInt32(v & 0x1f) << 16
        case 2: ch[c].lc = (ch[c].lc & 0x1f0000) | UInt32(v & 0xfffe)
        case 4: ch[c].len = v
        case 6: ch[c].per = v
        case 8: ch[c].vol = v
        default: break
        }
    }

    /// DMACON written. Like the real Paula (and tools/amiga/emu), a voice's state machine only notices the DMA
    /// enable bit when it next runs (here: at the next beam line, see `runLine`), so a DMA off/on pair written
    /// within a few instructions does NOT restart the voice. Code that relies on a busy-wait between DMA off
    /// and on (the music driver's sample-sfx trigger) calls `settleDMA()` where the original waits.
    func dmaconChanged(_ d: UInt16) {
        dmacon = d
    }

    /// Lets the voices see the current DMACON state now: DMA off stops a voice, DMA on (re)starts an idle voice
    /// and latches AUDxLC/AUDxLEN. Called at every beam line and by translated busy-wait delays.
    public func settleDMA() {
        let d = dmacon
        for c in 0..<4 {
            let on = d & 0x200 != 0 && d & (1 << UInt16(c)) != 0
            if on && !ch[c].active { start(c) }
            if !on && ch[c].active { ch[c].active = false; ch[c].current = 0; ch[c].previous = 0 }
        }
    }

    func start(_ c: Int) {
        ch[c].active = true
        ch[c].ptr = ch[c].lc
        ch[c].wordsLeft = ch[c].len == 0 ? 0x10000 : Int(ch[c].len)
        ch[c].word = mem.r16(ch[c].ptr)
        ch[c].byteIndex = 0
        ch[c].phase = 0
        ch[c].reqTime = -Double.infinity
        ch[c].pendingIRQ = true
        ch[c].current = Float(Int8(bitPattern: UInt8(ch[c].word >> 8)))
    }

    @inline(__always) func advance(_ c: Int) {
        if ch[c].byteIndex == 0 {
            ch[c].byteIndex = 1
        } else if accurate && !dmaWordReady(&ch[c], c) {
            ch[c].byteIndex = 0                 // the slot hasn't fetched the next word yet: Paula reloads the old one
        } else {
            ch[c].byteIndex = 0
            ch[c].wordsLeft -= 1
            if ch[c].wordsLeft <= 0 {
                ch[c].ptr = ch[c].lc
                ch[c].wordsLeft = ch[c].len == 0 ? 0x10000 : Int(ch[c].len)
                raiseInterrupt?(0x80 << UInt16(c))
            } else {
                ch[c].ptr &+= 2
            }
            ch[c].word = mem.r16(ch[c].ptr)
        }
        ch[c].previous = ch[c].current
        let b = ch[c].byteIndex == 0 ? UInt8(ch[c].word >> 8) : UInt8(truncatingIfNeeded: ch[c].word)
        ch[c].current = Float(Int8(bitPattern: b))
    }

    /// Generates the audio for one beam line (1/15625 s).
    func runLine() {
        if mixerActive { runLineMixer() } else { mixerWasActive = false; runLineLegacy() }
    }

    /// The original port's line renderer (unchanged; all enhancement mixer settings at their defaults).
    func runLineLegacy() {
        settleDMA()
        for c in 0..<4 { ch[c].reqTime -= Paula.lineClocks }             // A500 DMA model: times are line-relative
        for c in 0..<4 where ch[c].pendingIRQ { ch[c].pendingIRQ = false; raiseInterrupt?(0x80 << UInt16(c)) }
        sampleAcc += sampleRate / (50.0 * Double(Chipset.linesPerFrame))
        var n = 0
        let alpha: Float = outputAlpha
        let led = accurate && filterEnabled
        if led { ledFilter.prepare(rate: sampleRate) }
        let spl = sampleRate / (50.0 * Double(Chipset.linesPerFrame))
        while sampleAcc >= 1 {
            sampleAcc -= 1
            sampleTime = (1 - sampleAcc / spl) * Paula.lineClocks
            var l: Float = 0, r: Float = 0
            for c in 0..<4 where ch[c].active {
                var per = Double(ch[c].per); if per < 64 { per = 64 }
                ch[c].phase += Paula.clock / per / sampleRate
                while ch[c].phase >= 1 { ch[c].phase -= 1; advance(c) }
                var v = Float(min(64, ch[c].vol & 0x7f)) / 64
                if musicMuted { v = 0 }
                let s = interpolate ? ch[c].previous + (ch[c].current - ch[c].previous) * Float(ch[c].phase) : ch[c].current
                let o = s * v / 128
                if c == 0 || c == 3 { l += o } else { r += o }
            }
            let sep = stereoSeparation
            let ml = l * (0.5 + 0.5 * sep) + r * (0.5 - 0.5 * sep)
            let mr = r * (0.5 + 0.5 * sep) + l * (0.5 - 0.5 * sep)
            lpL += (ml - lpL) * alpha; lpR += (mr - lpR) * alpha
            var oL = lpL, oR = lpR
            if led { (oL, oR) = ledFilter.process(lpL, lpR, on: ledOn) }
            if n + 2 <= lineBuf.count { lineBuf[n] = oL * 0.5 * volume; lineBuf[n + 1] = oR * 0.5 * volume; n += 2 }
        }
        if n > 0, let out = output { lineBuf.withUnsafeBufferPointer { out(UnsafeBufferPointer(rebasing: $0[0..<n])) } }
    }

    // MARK: - enhancement mixer (S10 / M12 / M25)

    /// M12 ghost voices: the music part of each channel as the driver wrote it (host-only, no interrupts).
    var ghost = [Channel](repeating: Channel(), count: 4)
    /// Ghost DMA enable bits 0-3 as last written by the music driver.
    var ghostDMA: UInt16 = 0
    var mixerWasActive = false
    // per-line voice routing (index 0-3 hardware voices, 4-7 ghosts)
    private var isSfx = [Bool](repeating: false, count: 4)
    /// M12 hand-over: the sound effect on hardware voice c has ended but the voice has not yet been retriggered by
    /// the music (the driver's restore is a DMA off/on pair that doesn't restart the voice, so the hardware plays the
    /// rest of the effect's repeat and then the shadow sample from its start, out of step with the tune). Until the
    /// music next (re)starts the ghost - at the same beam line as the hardware voice, which is then identical
    /// again - the ghost stays audible and the hardware voice is muted.
    private var ghostHold = [Bool](repeating: false, count: 4)
    private var wasSfx = [Bool](repeating: false, count: 4)
    private var vGain = [Float](repeating: 0, count: 8)
    private var vBusOf = [Int](repeating: 0, count: 8)
    private var gL = [Float](repeating: 0.5, count: 4), gR = [Float](repeating: 0.5, count: 4)
    // BLEP: the last emitted level of each voice (L/R) and the bus it went to
    private var lastL = [Float](repeating: 0, count: 8), lastR = [Float](repeating: 0, count: 8)
    private var lastBus = [Int](repeating: 0, count: 8)
    private var buses = [BlepBus(), BlepBus()]          // 0 = music, 1 = sfx
    private var reverb: Reverb?
    private var reverbPreset = PaulaAmbience.off
    private var reverbLevel: Float = -1
    /// Samples the reverb keeps running after the ambience was switched off (tail).
    var reverbTail = 0

    /// M12: a music-channel register write of the music driver, mirrored into the ghost voices
    /// (DMACON $096 bits 0-3 and AUDxLC/LEN/PER/VOL). Game layer only (Game/Audio/MusicDriver.swift).
    public func ghostWrite(_ reg: Int, _ v: UInt16) {
        if reg == 0x096 {
            if v & 0x8000 != 0 { ghostDMA |= v & 0xf } else { ghostDMA &= ~(v & 0xf) }
            return
        }
        guard reg >= 0xa0 && reg < 0xe0 else { return }
        let c = (reg - 0xa0) >> 4
        switch reg & 15 {
        case 0: ghost[c].lc = (ghost[c].lc & 0xffff) | UInt32(v & 0x1f) << 16
        case 2: ghost[c].lc = (ghost[c].lc & 0x1f0000) | UInt32(v & 0xfffe)
        case 4: ghost[c].len = v
        case 6: ghost[c].per = v
        case 8: ghost[c].vol = v
        default: break
        }
    }

    /// M25 replacement soundtrack: the music driver started `song` (host bookkeeping).
    public func cueSong(_ song: Int) { songCues &+= 1; cuedSong = song }

    private func settleGhosts() {
        for c in 0..<4 {
            let on = ghostDMA & (1 << UInt16(c)) != 0
            if on && !ghost[c].active {
                ghostHold[c] = false                     // retriggered together with the hardware voice
                ghost[c].active = true
                ghost[c].ptr = ghost[c].lc
                ghost[c].wordsLeft = ghost[c].len == 0 ? 0x10000 : Int(ghost[c].len)
                ghost[c].word = mem.r16(ghost[c].ptr)
                ghost[c].byteIndex = 0
                ghost[c].phase = 0
                ghost[c].current = Float(Int8(bitPattern: UInt8(ghost[c].word >> 8)))
                ghost[c].previous = ghost[c].current
            }
            if !on && ghost[c].active { ghost[c].active = false; ghost[c].current = 0; ghost[c].previous = 0; ghostHold[c] = false }
        }
    }

    @inline(__always) private func advanceGhost(_ c: Int) {
        if ghost[c].byteIndex == 0 {
            ghost[c].byteIndex = 1
        } else if accurate && !dmaWordReady(&ghost[c], c) {
            ghost[c].byteIndex = 0
        } else {
            ghost[c].byteIndex = 0
            ghost[c].wordsLeft -= 1
            if ghost[c].wordsLeft <= 0 {
                ghost[c].ptr = ghost[c].lc
                ghost[c].wordsLeft = ghost[c].len == 0 ? 0x10000 : Int(ghost[c].len)
            } else {
                ghost[c].ptr &+= 2
            }
            ghost[c].word = mem.r16(ghost[c].ptr)
        }
        ghost[c].previous = ghost[c].current
        let b = ghost[c].byteIndex == 0 ? UInt8(ghost[c].word >> 8) : UInt8(truncatingIfNeeded: ghost[c].word)
        ghost[c].current = Float(Int8(bitPattern: b))
    }

    /// BLEP: voice `v` now has mono level `level` on bus `bus`; the change happened `d` samples ago.
    @inline(__always) private func blepLevel(_ v: Int, _ level: Float, _ d: Double) {
        let bus = vBusOf[v]
        if bus != lastBus[v] {
            if lastL[v] != 0 || lastR[v] != 0 { buses[lastBus[v]].addStep(-lastL[v], -lastR[v], d) }
            lastL[v] = 0; lastR[v] = 0; lastBus[v] = bus
        }
        let l = level * gL[v & 3], r = level * gR[v & 3]
        let dl = l - lastL[v], dr = r - lastR[v]
        if dl != 0 || dr != 0 { buses[bus].addStep(dl, dr, d); lastL[v] = l; lastR[v] = r }
    }

    private func resetMixerState() {
        for v in 0..<8 { lastL[v] = 0; lastR[v] = 0; lastBus[v] = 0 }
        for c in 0..<4 { ghostHold[c] = false; wasSfx[c] = false }
        buses[0].reset(); buses[1].reset()
    }

    /// The enhancement mixer's line renderer. The hardware voices are stepped exactly like `runLineLegacy`
    /// (same DMA settling, same phase arithmetic, same order, same block-end interrupts).
    func runLineMixer() {
        if !mixerWasActive { resetMixerState(); mixerWasActive = true }
        settleDMA()
        for c in 0..<4 { ch[c].reqTime -= Paula.lineClocks; ghost[c].reqTime -= Paula.lineClocks }
        for c in 0..<4 where ch[c].pendingIRQ { ch[c].pendingIRQ = false; raiseInterrupt?(0x80 << UInt16(c)) }
        let ghosts = ghostVoices
        if ghosts { settleGhosts() }
        // routing of this line: tag, gain, bus, pan
        let tag = voiceIsSfx
        let sep = stereoSeparation
        let mute = musicMuted
        for c in 0..<4 {
            let sfx = tag?(c) ?? false
            isSfx[c] = sfx
            if !ghosts || sfx || !ghost[c].active { ghostHold[c] = false } else if wasSfx[c] { ghostHold[c] = true }
            wasSfx[c] = sfx
            let hold = ghostHold[c]
            let p = max(-1, min(1, c < pan.count ? pan[c] : Paula.amigaPan[c]))
            gL[c] = 0.5 - 0.5 * p * sep; gR[c] = 0.5 + 0.5 * p * sep
            vGain[c] = mute || hold ? 0 : sfx ? sfxGain : (musicReplaced ? 0 : musicGain)
            vBusOf[c] = sfx ? 1 : 0
            vGain[4 + c] = (ghosts && (sfx || hold) && !musicReplaced && !mute) ? musicGain : 0
            vBusOf[4 + c] = 0
        }
        // ambience
        let amb = effectiveAmbience
        if amb != .off {
            if reverb == nil || reverb!.rate != sampleRate { reverb = Reverb(rate: sampleRate) }
            reverbTail = Int(sampleRate * 4)
        }
        if amb != reverbPreset || ambienceLevel != reverbLevel {
            reverb?.configure(amb.params, level: ambienceLevel)
            reverbPreset = amb; reverbLevel = ambienceLevel
        }
        let useReverb = reverb != nil && reverbTail > 0
        let blep = synthesis == .blep

        sampleAcc += sampleRate / (50.0 * Double(Chipset.linesPerFrame))
        var n = 0
        let alpha: Float = outputAlpha
        let led = accurate && filterEnabled
        if led { ledFilter.prepare(rate: sampleRate) }
        let spl = sampleRate / (50.0 * Double(Chipset.linesPerFrame))
        while sampleAcc >= 1 {
            sampleAcc -= 1
            sampleTime = (1 - sampleAcc / spl) * Paula.lineClocks
            var mL: Float = 0, mR: Float = 0, sL: Float = 0, sR: Float = 0
            for c in 0..<4 {
                if ch[c].active {
                    var per = Double(ch[c].per); if per < 64 { per = 64 }
                    let inc = Paula.clock / per / sampleRate
                    ch[c].phase += inc
                    let k = Float(min(64, ch[c].vol & 0x7f)) / 64 / 128 * vGain[c]
                    if blep {
                        blepLevel(c, ch[c].current * k, 0.999)
                        while ch[c].phase >= 1 { ch[c].phase -= 1; advance(c); blepLevel(c, ch[c].current * k, ch[c].phase / inc) }
                    } else {
                        while ch[c].phase >= 1 { ch[c].phase -= 1; advance(c) }
                        let s = interpolate ? ch[c].previous + (ch[c].current - ch[c].previous) * Float(ch[c].phase) : ch[c].current
                        let o = s * k
                        if isSfx[c] { sL += o * gL[c]; sR += o * gR[c] } else { mL += o * gL[c]; mR += o * gR[c] }
                    }
                } else if blep {
                    blepLevel(c, 0, 0.999)
                }
            }
            if ghosts {
                for c in 0..<4 {
                    let v = 4 + c
                    if ghost[c].active {
                        var per = Double(ghost[c].per); if per < 64 { per = 64 }
                        let inc = Paula.clock / per / sampleRate
                        ghost[c].phase += inc
                        let k = Float(min(64, ghost[c].vol & 0x7f)) / 64 / 128 * vGain[v]
                        if blep {
                            blepLevel(v, ghost[c].current * k, 0.999)
                            while ghost[c].phase >= 1 { ghost[c].phase -= 1; advanceGhost(c); blepLevel(v, ghost[c].current * k, ghost[c].phase / inc) }
                        } else {
                            while ghost[c].phase >= 1 { ghost[c].phase -= 1; advanceGhost(c) }
                            let s = interpolate ? ghost[c].previous + (ghost[c].current - ghost[c].previous) * Float(ghost[c].phase) : ghost[c].current
                            let o = s * k
                            mL += o * gL[c]; mR += o * gR[c]
                        }
                    } else if blep {
                        blepLevel(v, 0, 0.999)
                    }
                }
            } else if blep {
                for v in 4..<8 where lastL[v] != 0 || lastR[v] != 0 { blepLevel(v, 0, 0.999) }
            }
            if blep {
                var nm: (Float, Float) = (0, 0), ns: (Float, Float) = (0, 0)
                for v in 0..<8 {
                    if lastBus[v] == 0 { nm.0 += lastL[v]; nm.1 += lastR[v] } else { ns.0 += lastL[v]; ns.1 += lastR[v] }
                }
                (mL, mR) = buses[0].output(nm.0, nm.1)
                (sL, sR) = buses[1].output(ns.0, ns.1)
            }
            var ol = mL + sL, orr = mR + sR
            if useReverb {
                let (wl, wr) = reverb!.process(sL, sR)
                ol += wl; orr += wr
            }
            lpL += (ol - lpL) * alpha; lpR += (orr - lpR) * alpha
            var oL = lpL, oR = lpR
            if led { (oL, oR) = ledFilter.process(lpL, lpR, on: ledOn) }
            if n + 2 <= lineBuf.count { lineBuf[n] = oL * 0.5 * volume; lineBuf[n + 1] = oR * 0.5 * volume; n += 2 }
        }
        if useReverb && amb == .off {
            reverbTail -= n / 2
            if reverbTail <= 0 { reverbTail = 0 }
        }
        if n > 0, let out = output { lineBuf.withUnsafeBufferPointer { out(UnsafeBufferPointer(rebasing: $0[0..<n])) } }
    }
}

/// The A500's switchable "LED" filter: a 2-pole Sallen-Key low-pass (10k/10k, 6.8 nF/3.9 nF: 3090 Hz, Q 0.660),
/// discretised like vAmiga's TwoPoleFilter. It always runs (no click when the LED changes) and is heard while on.
struct PaulaLEDFilter {
    private var rate = 0.0
    private var a1 = 0.0, a2 = 0.0, b1 = 0.0, b2 = 0.0
    private var xl = (0.0, 0.0), yl = (0.0, 0.0), xr = (0.0, 0.0), yr = (0.0, 0.0)

    mutating func prepare(rate r: Double) {
        guard r != rate else { return }
        rate = r
        let rc = 1e4 * (6.8e-9 * 3.9e-9).squareRoot()
        let fc = 1 / (2 * Double.pi * rc), q = rc / (3.9e-9 * 2e4)
        let a = 1 / tan(2 * Double.pi * min(fc, r / 2 - 1e-4) / r), b = 1 / q
        a1 = 1 / (1 + b * a + a * a); a2 = 2 * a1
        b1 = 2 * (1 - a * a) * a1; b2 = (1 - b * a + a * a) * a1
    }

    func encode(into w: inout SnapWriter) {
        for v in [xl.0, xl.1, yl.0, yl.1, xr.0, xr.1, yr.0, yr.1] { w.f64(v) }
    }
    mutating func decode(_ r: inout SnapReader) throws {
        xl = (try r.f64(), try r.f64()); yl = (try r.f64(), try r.f64())
        xr = (try r.f64(), try r.f64()); yr = (try r.f64(), try r.f64())
    }

    mutating func process(_ l: Float, _ r: Float, on: Bool) -> (Float, Float) {
        let il = Double(l), ir = Double(r)
        let ol = a1 * il + a2 * xl.0 + a1 * xl.1 - b1 * yl.0 - b2 * yl.1
        let or = a1 * ir + a2 * xr.0 + a1 * xr.1 - b1 * yr.0 - b2 * yr.1
        xl = (il, xl.0); yl = (ol, yl.0); xr = (ir, xr.0); yr = (or, yr.0)
        return on ? (Float(ol), Float(or)) : (l, r)
    }
}
