// Paula enhancement mixer building blocks (OWNER: audio). Host presentation only: nothing here touches RAM,
// custom registers, interrupts or the voices' DMA state machine, so the game runs identically whatever is chosen.
//   BlepBus   band-limited step synthesis (M25 "BLEP"): Paula's output is a zero-order hold per voice; every level
//             change is added as a windowed-sinc band-limited step instead of a hard edge (no aliasing).
//   Reverb    Freeverb-style stereo reverb + pre-delay + echo for the per-area ambience on the SFX stem (M25).
import Foundation

/// Paula synthesis mode (M25). `.legacy` = the output of the original port (nearest sample, optional linear
/// interpolation), bit-identical to before; `.blep` = band-limited steps.
public enum PaulaSynthesis: String, CaseIterable {
    case legacy, blep
}

/// Ambience (M25): reverb on the sound-effect stem. `.auto` follows the area being played (Game/Audio sets
/// `Paula.ambienceArea` from the F1 context every vblank); the others are fixed presets.
public enum PaulaAmbience: String, CaseIterable {
    case off, auto, jungle, hut, tunnels, night, bunker

    struct Params { var room: Float, damp: Float, wet: Float, width: Float, preDelayMs: Float, echoMs: Float, echoFeedback: Float, echoMix: Float }
    var params: Params? {
        switch self {
        case .off, .auto: return nil
        case .jungle:  return Params(room: 0.42, damp: 0.75, wet: 0.16, width: 1.0, preDelayMs: 12, echoMs: 0, echoFeedback: 0, echoMix: 0)
        case .hut:     return Params(room: 0.30, damp: 0.45, wet: 0.22, width: 0.8, preDelayMs: 4, echoMs: 0, echoFeedback: 0, echoMix: 0)
        case .tunnels: return Params(room: 0.72, damp: 0.30, wet: 0.30, width: 0.7, preDelayMs: 18, echoMs: 95, echoFeedback: 0.32, echoMix: 0.22)
        case .night:   return Params(room: 0.86, damp: 0.62, wet: 0.24, width: 1.0, preDelayMs: 38, echoMs: 0, echoFeedback: 0, echoMix: 0)
        case .bunker:  return Params(room: 0.55, damp: 0.20, wet: 0.26, width: 0.6, preDelayMs: 6, echoMs: 0, echoFeedback: 0, echoMix: 0)
        }
    }
}

// MARK: - BLEP

/// Stereo bus with band-limited step synthesis. Output is delayed by `BlepBus.half` samples (0.5 ms at 48 kHz):
/// y[n] = naive[n - half] + sum of step residuals (band-limited step minus ideal step), so no level drift can build up.
struct BlepBus {
    static let half = 24                 // kernel half-width in output samples
    static let os = 64                   // table oversampling
    static let size = 64                 // ring size (power of 2, > 2*half)
    static let mask = size - 1
    /// Band-limited step H(x) for x = -half + j/os, j = 0 ... 2*half*os (+1 guard); H(-half) = 0, H(+half) = 1.
    static let table: [Float] = {
        let n = 2 * half * os
        let fc = 0.40                    // cutoff (fraction of the output rate): flat to ~0.32 fs, stopband from ~0.48 fs (below Nyquist)
        let sub = 8                      // integration sub-steps per table step
        func h(_ x: Double) -> Double {
            let t = x / Double(half)
            if abs(t) >= 1 { return 0 }
            let w = 0.35875 + 0.48829 * cos(Double.pi * t) + 0.14128 * cos(2 * Double.pi * t) + 0.01168 * cos(3 * Double.pi * t)
            let a = 2 * Double.pi * fc * x
            let s = abs(a) < 1e-9 ? 1 : sin(a) / a
            return 2 * fc * s * w
        }
        var acc = [Double](repeating: 0, count: n + 2)
        var sum = 0.0
        let dx = 1.0 / Double(os * sub)
        for j in 0..<n {
            for k in 0..<sub {
                let x0 = -Double(half) + (Double(j * sub + k)) * dx
                sum += 0.5 * (h(x0) + h(x0 + dx)) * dx
            }
            acc[j + 1] = sum
        }
        acc[n + 1] = sum
        return acc.map { Float($0 / sum) }
    }()

    var resL = [Float](repeating: 0, count: size), resR = [Float](repeating: 0, count: size)
    var delL = [Float](repeating: 0, count: size), delR = [Float](repeating: 0, count: size)
    var pos = 0

    mutating func reset() {
        for i in 0..<BlepBus.size { resL[i] = 0; resR[i] = 0; delL[i] = 0; delR[i] = 0 }
        pos = 0
    }

    /// A step of (dl, dr) that happened `d` output samples (0 <= d < 1) before the current output instant.
    mutating func addStep(_ dl: Float, _ dr: Float, _ d: Double) {
        let t = BlepBus.table
        let f = d * Double(BlepBus.os)
        let i0 = Int(f), fr = Float(f - Double(i0))
        let h = BlepBus.half, os = BlepBus.os, m = BlepBus.mask
        t.withUnsafeBufferPointer { tp in
            resL.withUnsafeMutableBufferPointer { rl in
                resR.withUnsafeMutableBufferPointer { rr in
                    for k in 0..<(2 * h) {
                        let j = k * os + i0
                        var v = tp[j] + (tp[j + 1] - tp[j]) * fr
                        if k >= h { v -= 1 }           // the naive (delayed) signal already contains the step
                        let p = (pos + k) & m
                        rl[p] += dl * v; rr[p] += dr * v
                    }
                }
            }
        }
    }

    /// Produces the output for the current instant from the naive (hard-step) bus level and advances.
    mutating func output(_ naiveL: Float, _ naiveR: Float) -> (Float, Float) {
        let m = BlepBus.mask
        delL[pos] = naiveL; delR[pos] = naiveR
        let dp = (pos - BlepBus.half) & m
        let l = delL[dp] + resL[pos], r = delR[dp] + resR[pos]
        resL[pos] = 0; resR[pos] = 0
        pos = (pos + 1) & m
        return (l, r)
    }
}

// MARK: - Reverb (Freeverb, Jezar at Dreampoint, public domain design)

struct Reverb {
    private struct Comb {
        var buf: [Float], idx = 0, store: Float = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: max(1, n)) }
        @inline(__always) mutating func process(_ x: Float, _ fb: Float, _ d1: Float, _ d2: Float) -> Float {
            let out = buf[idx]
            store = out * d2 + store * d1
            if abs(store) < 1e-18 { store = 0 }
            buf[idx] = x + store * fb
            idx += 1; if idx == buf.count { idx = 0 }
            return out
        }
    }
    private struct Allpass {
        var buf: [Float], idx = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: max(1, n)) }
        @inline(__always) mutating func process(_ x: Float) -> Float {
            let b = buf[idx]
            var nb = x + b * 0.5
            if abs(nb) < 1e-18 { nb = 0 }
            buf[idx] = nb
            idx += 1; if idx == buf.count { idx = 0 }
            return b - x
        }
    }
    private var combL: [Comb], combR: [Comb], apL: [Allpass], apR: [Allpass]
    private var pre: [Float], preIdx = 0
    private var echoL: [Float], echoR: [Float], echoIdx = 0
    let rate: Double

    // current (smoothed) parameters
    private var fb: Float = 0.84, d1: Float = 0.2, d2: Float = 0.8
    private var wet: Float = 0, width: Float = 1, preLen = 0
    private var echoLen = 0, echoFb: Float = 0, echoMix: Float = 0
    /// Level of the last output (for the tail detector).
    private(set) var energy: Float = 0

    init(rate: Double) {
        self.rate = rate
        let s = rate / 44100
        let ct = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], at = [556, 441, 341, 225]
        combL = ct.map { Comb(Int(Double($0) * s)) }
        combR = ct.map { Comb(Int(Double($0 + 23) * s)) }
        apL = at.map { Allpass(Int(Double($0) * s)) }
        apR = at.map { Allpass(Int(Double($0 + 23) * s)) }
        pre = [Float](repeating: 0, count: Int(rate * 0.1) + 1)
        echoL = [Float](repeating: 0, count: Int(rate * 0.25) + 1)
        echoR = echoL
    }

    /// Sets the preset (nil = fade out); `level` scales the wet amount.
    mutating func configure(_ p: PaulaAmbience.Params?, level: Float) {
        guard let p else { wet = 0; echoGain = 0; return }
        fb = p.room * 0.28 + 0.7
        d1 = p.damp * 0.4; d2 = 1 - d1
        wet = p.wet * level * 3        // Freeverb's wet scale
        width = p.width
        preLen = min(pre.count - 1, Int(Double(p.preDelayMs) * rate / 1000))
        if p.echoMs > 0 { echoLen = min(echoL.count - 1, Int(Double(p.echoMs) * rate / 1000)); echoIdx = min(echoIdx, max(0, echoLen - 1)) }
        echoFb = p.echoFeedback; echoMix = p.echoMix; echoGain = p.echoMix * level
    }

    private var wetNow: Float = 0, echoGain: Float = 0, echoNow: Float = 0

    /// One stereo sample of the send (the SFX stem) -> wet output.
    mutating func process(_ inL: Float, _ inR: Float) -> (Float, Float) {
        wetNow += (wet - wetNow) * 0.0005               // ~40 ms parameter glide at 48 kHz
        var x = (inL + inR) * 0.015
        if preLen > 0 {
            let o = pre[preIdx]; pre[preIdx] = x; preIdx += 1; if preIdx >= preLen { preIdx = 0 }
            x = o
        }
        var l: Float = 0, r: Float = 0
        for i in 0..<combL.count { l += combL[i].process(x, fb, d1, d2); r += combR[i].process(x, fb, d1, d2) }
        for i in 0..<apL.count { l = apL[i].process(l); r = apR[i].process(r) }
        let w1 = wetNow * (width / 2 + 0.5), w2 = wetNow * ((1 - width) / 2)
        var ol = l * w1 + r * w2, or = r * w1 + l * w2
        if echoLen > 0 {
            let el = echoL[echoIdx], er = echoR[echoIdx]
            echoL[echoIdx] = inL + el * echoFb; echoR[echoIdx] = inR + er * echoFb
            if abs(echoL[echoIdx]) < 1e-18 { echoL[echoIdx] = 0 }
            if abs(echoR[echoIdx]) < 1e-18 { echoR[echoIdx] = 0 }
            echoIdx += 1; if echoIdx >= echoLen { echoIdx = 0 }
            echoNow += (echoGain - echoNow) * 0.0005
            ol += el * echoNow; or += er * echoNow
        }
        energy = energy * 0.9995 + (abs(ol) + abs(or)) * 0.0005
        return (ol, or)
    }
}
