import XCTest
import Accelerate
@testable import PlatoonCore

// Owner: audio. Paula enhancement mixer (S10 / M12 / M25 BLEP) and the host audio stream (M22).
final class AudioTests: XCTestCase {
    /// A Paula playing a 32-byte square wave (16 x +127, 16 x -128) on voice 0 at period `per`, rendered for `lines`.
    private func renderSquare(per: UInt16, lines: Int, configure: (Paula) -> Void = { _ in }) -> [Float] {
        let mem = Memory()
        for i in 0..<32 { mem.w8(0x1000 + UInt32(i), i < 16 ? 0x7f : 0x80) }
        let p = Paula(memory: mem)
        p.filterEnabled = false
        configure(p)
        var out: [Float] = []
        p.output = { b in out.append(contentsOf: b) }
        p.registerWritten(channel: 0, offset: 0, value: 0)
        p.registerWritten(channel: 0, offset: 2, value: 0x1000)
        p.registerWritten(channel: 0, offset: 4, value: 16)
        p.registerWritten(channel: 0, offset: 6, value: per)
        p.registerWritten(channel: 0, offset: 8, value: 64)
        p.dmaconChanged(0x8201)
        for _ in 0..<lines { p.runLine() }
        return out
    }

    /// Power outside the harmonics of f0 relative to the harmonic power, in dB (left channel).
    private func aliasRatioDB(_ stereo: [Float], f0: Double, rate: Double) -> Double {
        let n = 32768
        var x = [Float](repeating: 0, count: n)
        let off = stereo.count / 2 - n - 100
        for i in 0..<n {
            let t = 2 * Double.pi * Double(i) / Double(n)                   // 4-term Blackman-Harris (-92 dB sidelobes:
            let w = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2 * t) - 0.01168 * cos(3 * t)   // Hann leakage floors at ~-42 dB)
            x[i] = stereo[2 * (off + i)] * Float(w)
        }
        let log2n = vDSP_Length(15)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&sc, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = rate / Double(n)
        var harmonic = 0.0, alias = 0.0
        for b in 4..<(n / 2) {                          // skip DC
            let f = Double(b) * binHz
            let k = (f / f0).rounded()
            if k >= 1 && abs(f - k * f0) <= 6 * binHz { harmonic += Double(power[b]) } else { alias += Double(power[b]) }
        }
        return 10 * log10(alias / harmonic)
    }

    func testBlepTable() {
        let t = BlepBus.table
        XCTAssertEqual(t.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(t[2 * BlepBus.half * BlepBus.os], 1, accuracy: 1e-6)
        XCTAssertEqual(t[BlepBus.half * BlepBus.os], 0.5, accuracy: 1e-3)   // symmetric kernel: half the step at x = 0
    }

    /// BLEP removes most of the aliasing of a high square wave (legacy = hard sample steps).
    func testBlepReducesAliasing() {
        let per: UInt16 = 124
        let f0 = Paula.clock / Double(per) / 32
        let legacy = renderSquare(per: per, lines: 15650 * 2)
        let blep = renderSquare(per: per, lines: 15650 * 2) { $0.synthesis = .blep }
        let a = aliasRatioDB(legacy, f0: f0, rate: 48000), b = aliasRatioDB(blep, f0: f0, rate: 48000)
        print("alias/harmonic: legacy \(a) dB, blep \(b) dB")
        XCTAssertLessThan(b, a - 30, "BLEP should cut aliasing by > 30 dB (legacy \(a) dB, blep \(b) dB)")
    }

    /// The mixer path with (almost) neutral settings renders what the original path renders.
    func testMixerNeutralMatchesLegacy() {
        let legacy = renderSquare(per: 300, lines: 4000)
        let mixer = renderSquare(per: 300, lines: 4000) { $0.sfxGain = 0.9999999 }
        XCTAssertEqual(legacy.count, mixer.count)
        var maxd: Float = 0
        for i in 0..<legacy.count { maxd = max(maxd, abs(legacy[i] - mixer[i])) }
        XCTAssertLessThan(maxd, 1e-5)
    }

    func testMusicAndSfxGainAndPan() {
        // voice 0 tagged music: musicGain 0 silences it, sfxGain doesn't
        let muted = renderSquare(per: 300, lines: 2000) { $0.musicGain = 0 }
        XCTAssertEqual(muted.map(abs).max()!, 0)
        let sfx = renderSquare(per: 300, lines: 2000) { p in p.musicGain = 0; p.voiceIsSfx = { $0 == 0 } }
        XCTAssertGreaterThan(sfx.map(abs).max()!, 0.1)
        // pan voice 0 hard right with full separation: left channel silent
        let right = renderSquare(per: 300, lines: 2000) { p in p.pan = [1, 1, 1, -1] }
        var l: Float = 0, r: Float = 0
        for i in stride(from: 0, to: right.count, by: 2) { l = max(l, abs(right[i])); r = max(r, abs(right[i + 1])) }
        XCTAssertEqual(l, 0); XCTAssertGreaterThan(r, 0.1)
    }

    /// M12: a ghost voice plays the music writes and is heard only while an SFX owns its hardware channel.
    func testGhostVoice() {
        let mem = Memory()
        for i in 0..<32 { mem.w8(0x2000 + UInt32(i), i < 16 ? 0x60 : 0xa0) }
        let p = Paula(memory: mem)
        p.filterEnabled = false
        p.ghostVoices = true
        var owned = false
        p.voiceIsSfx = { $0 == 1 && owned }
        var out: [Float] = []
        p.output = { b in out.append(contentsOf: b) }
        for (r, v) in [(0xb0, 0), (0xb2, 0x2000), (0xb4, 16), (0xb6, 200), (0xb8, 64), (0x096, 0x8202)] { p.ghostWrite(r, UInt16(v)) }
        for _ in 0..<500 { p.runLine() }
        XCTAssertEqual(out.map(abs).max()!, 0, "ghost must be silent while the channel belongs to the music")
        XCTAssertTrue(p.ghost[1].active)
        out.removeAll(); owned = true
        for _ in 0..<500 { p.runLine() }
        XCTAssertGreaterThan(out.map(abs).max()!, 0.1, "ghost audible while an SFX owns the channel")
        out.removeAll(); p.ghostWrite(0x096, 0x0002)          // music DMA off -> ghost stops
        for _ in 0..<5 { p.runLine() }
        out.removeAll()
        for _ in 0..<200 { p.runLine() }
        XCTAssertEqual(out.map(abs).max()!, 0)
        XCTAssertFalse(p.ch[1].active, "ghost writes never touch the hardware voice")
    }

    /// Changing mixer settings never changes the voices' state machine (block-end interrupt timing).
    func testMixerKeepsInterruptTiming() {
        func irqs(_ configure: (Paula) -> Void) -> [Int] {
            let mem = Memory()
            let p = Paula(memory: mem)
            configure(p)
            var line = 0, log: [Int] = []
            p.raiseInterrupt = { bits in log.append(line << 4 | Int(bits >> 7)) }
            p.registerWritten(channel: 2, offset: 2, value: 0x1000)
            p.registerWritten(channel: 2, offset: 4, value: 37)
            p.registerWritten(channel: 2, offset: 6, value: 181)
            p.registerWritten(channel: 2, offset: 8, value: 40)
            p.dmaconChanged(0x8204)
            for l in 0..<20000 { line = l; p.runLine() }
            return log
        }
        let a = irqs { _ in }
        let b = irqs { p in p.synthesis = .blep; p.ghostVoices = true; p.ambience = .tunnels; p.pan = [0, 0, 0, 0] }
        XCTAssertGreaterThan(a.count, 100)
        XCTAssertEqual(a, b)
    }

    // MARK: host audio stream (M22)

    /// Simulates a producer pushing one emulated frame (rate/50 frames) every 20 ms / speed, jittered, and a device
    /// consuming 512 frames per callback; returns the stream after `seconds` of virtual time.
    private func simulate(mode: HostAudioStream.Mode, speed: Double, drift: Double = 1, seconds: Double, latency: Double = 0.06,
                          stallEvery: Double = 0, stall: Double = 0) -> (HostAudioStream, [Int], [Double]) {
        let s = HostAudioStream(rate: 48000, seconds: 1, mode: mode)
        s.latency = latency
        var now = 0.0
        s.clock = { now }
        let chunk = [Float](repeating: 0.1, count: 960 * 2)
        var nextPush = 0.0, nextPull = 0.0
        var fills: [Int] = [], ratios: [Double] = []
        var l = [Float](repeating: 0, count: 512), r = l
        var rng = SystemRandomNumberGenerator()
        while now < seconds {
            if nextPush <= nextPull {
                now = nextPush
                chunk.withUnsafeBufferPointer { s.push($0) }
                nextPush += 0.02 / speed / drift + Double.random(in: -0.004...0.004, using: &rng) * 0.5
                if stallEvery > 0 && Int(nextPush / stallEvery) != Int(now / stallEvery) { nextPush += stall }
            } else {
                now = nextPull
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in s.render(512, lp.baseAddress!, rp.baseAddress!) } }
                fills.append(s.stats.fillFrames); ratios.append(s.stats.ratio)
                nextPull += 512.0 / 48000
            }
        }
        return (s, fills, ratios)
    }

    func testAdaptiveSteadyState() {
        // producer 0.3 % fast (its push times also random-walk: independent jitter per push, a harsh case)
        let (s, fills, ratios) = simulate(mode: .adaptive, speed: 1, drift: 1.003, seconds: 90)
        let st = s.stats
        XCTAssertLessThanOrEqual(st.underruns, 1, "\(st)")
        XCTAssertEqual(st.overruns, 0, "\(st)")
        let tail = fills.suffix(4000)
        let mean = Double(tail.reduce(0, +)) / Double(tail.count)
        XCTAssertEqual(mean, 2880, accuracy: 700, "fill should settle around the 60 ms target (PI control): \(mean)")
        let rt = ratios.suffix(4000)
        let meanRatio = rt.reduce(0, +) / Double(rt.count)
        XCTAssertEqual(meanRatio, 1.003, accuracy: 0.0012, "the consumer follows the producer's clock on average")
        XCTAssertLessThanOrEqual(rt.max()!, 1.0051)
        XCTAssertGreaterThanOrEqual(rt.min()!, 0.9949)
    }

    func testLegacyDropsWhenAhead() {
        let (s, _, _) = simulate(mode: .legacy, speed: 1, drift: 1.02, seconds: 30)       // producer 2 % fast
        XCTAssertGreaterThan(s.stats.droppedBlocks, 0)
    }

    /// Slow motion without a hint: the stream detects the sustained producer rate (2 s windows) and follows it.
    func testAdaptiveSlowMotion() {
        let (s, _, _) = simulate(mode: .adaptive, speed: 0.6, seconds: 40)
        let st = s.stats
        XCTAssertEqual(st.producerSpeed, 0.6, accuracy: 0.05, "\(st)")
        XCTAssertLessThanOrEqual(st.underruns, 10, "slow motion must not keep underrunning: \(st)")
        XCTAssertEqual(st.ratio, 0.6, accuracy: 0.05)
    }

    /// Slow motion announced by the host (speedHint): no underruns at all.
    func testAdaptiveSlowMotionWithHint() {
        let s = HostAudioStream(rate: 48000, seconds: 1, mode: .adaptive)
        s.speedHint = 0.7
        var now = 0.0; s.clock = { now }
        let chunk = [Float](repeating: 0.1, count: 960 * 2)
        var nextPush = 0.0, nextPull = 0.0
        var l = [Float](repeating: 0, count: 512), r = l
        while now < 30 {
            if nextPush <= nextPull { now = nextPush; chunk.withUnsafeBufferPointer { s.push($0) }; nextPush += 0.02 / 0.7 }
            else {
                now = nextPull
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in s.render(512, lp.baseAddress!, rp.baseAddress!) } }
                nextPull += 512.0 / 48000
            }
        }
        XCTAssertEqual(s.stats.underruns, 0, "\(s.stats)")
        XCTAssertEqual(s.stats.ratio, 0.7, accuracy: 0.004)
    }

    /// Catch-up bursts never let the latency grow beyond 4x the target.
    func testAdaptiveLatencyCap() {
        let s = HostAudioStream(rate: 48000, seconds: 1, mode: .adaptive)
        s.latency = 0.04
        var now = 0.0; s.clock = { now }
        let chunk = [Float](repeating: 0.1, count: 960 * 2)
        for _ in 0..<40 { chunk.withUnsafeBufferPointer { s.push($0) } }   // 0.8 s of audio at once
        XCTAssertLessThanOrEqual(s.stats.fillFrames, 1920 * 4 + 960)
        XCTAssertGreaterThan(s.stats.overruns, 0)
        now += 1
    }

    /// Host hitches (a 0.3 s stall every 5 s) are not slow motion: the pitch stays at 1 and the stream recovers.
    func testAdaptiveStallsAreNotSlowMotion() {
        let (s, _, _) = simulate(mode: .adaptive, speed: 1, seconds: 40, stallEvery: 5, stall: 0.3)
        let st = s.stats
        XCTAssertEqual(st.producerSpeed, 1, accuracy: 0.08, "\(st)")
        XCTAssertEqual(st.ratio, 1, accuracy: 0.006, "\(st)")
    }

    func testAdaptiveResamplerIsTransparentAtUnity() {
        // a sine pushed and pulled at exactly the nominal rate comes out (delayed) unchanged
        let s = HostAudioStream(rate: 48000, seconds: 1, mode: .adaptive)
        s.latency = 0.02
        var now = 0.0; s.clock = { now }
        var t = 0
        var outL: [Float] = []
        var l = [Float](repeating: 0, count: 480), r = l
        for _ in 0..<300 {
            var buf = [Float](repeating: 0, count: 960)
            for i in 0..<480 { let v = Float(sin(Double(t) * 2 * Double.pi * 440 / 48000)) * 0.5; buf[2 * i] = v; buf[2 * i + 1] = v; t += 1 }
            buf.withUnsafeBufferPointer { s.push($0) }
            now += 0.01
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in s.render(480, lp.baseAddress!, rp.baseAddress!) } }
            outL += l
        }
        // after priming the output is a clean 440 Hz sine: frequency (zero crossings), amplitude, smoothness
        let seg = Array(outL[48000..<96000])
        var crossings = 0, peak: Float = 0, jump: Float = 0
        for i in 1..<seg.count {
            if (seg[i - 1] < 0) != (seg[i] < 0) { crossings += 1 }
            peak = max(peak, abs(seg[i]))
            if i > 1 { jump = max(jump, abs(seg[i] - 2 * seg[i - 1] + seg[i - 2])) }
        }
        XCTAssertEqual(Double(crossings) / 2, 440, accuracy: 3)
        XCTAssertEqual(peak, 0.5, accuracy: 0.01)
        XCTAssertLessThan(jump, 0.01, "no discontinuities")   // 2nd difference of a 440 Hz sine at 0.5 is ~0.0021
        XCTAssertEqual(s.stats.underruns, 0)
    }
}
