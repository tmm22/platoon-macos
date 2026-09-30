// Host audio stream between the emulation and the sound device (OWNER: audio; roadmap M22). Host-only: the game
// never sees it. Used by PlatoonApp/AudioOutput.swift; kept in PlatoonCore so it can be unit-tested.
//
// The emulation produces Paula's samples in bursts (one frame at a time, paced by the display), the device
// consumes them at its own clock. Two modes:
//   .legacy    the original behaviour: consume one sample per device sample, drop whole pushed blocks while the
//              buffer is more than 3x the target latency ahead, output silence when empty.
//   .adaptive  dynamic rate control: a cubic resampler consumes (speed x (1 +- 0.5 %)) samples per device sample,
//              where the correction follows the buffer fill (so clock drift and VRR pacing never click), and
//              `speed` follows the producer (slow motion plays at lower pitch instead of stuttering; set
//              `speedHint` when the host knows its game speed). Underruns re-prime to the target fill;
//              overruns (more than 4x the target buffered, e.g. catch-up bursts after a stall) drop the oldest audio
//              down to the target once, so the latency never grows.
import Foundation
import os

public final class HostAudioStream {
    public enum Mode: Int, CaseIterable { case legacy = 0, adaptive = 1 }

    public struct Stats: Equatable {
        public var underruns = 0, overruns = 0, droppedBlocks = 0
        public var ratio = 1.0, fillFrames = 0, producerSpeed = 1.0
    }

    public let rate: Double
    public var mode: Mode { get { lock { _mode } } set { lock { if _mode != newValue { _mode = newValue; resetLocked() } } } }
    /// Target latency (seconds of buffered audio).
    public var latency: Double { get { lock { _latency } } set { lock { _latency = max(0.01, min(0.5, newValue)) } } }
    /// Producer speed relative to real time when the host knows it (slow motion 0.6 ...); nil = estimate it.
    public var speedHint: Double? { get { lock { _speedHint } } set { lock { _speedHint = newValue } } }
    public var stats: Stats { lock { var s = _stats; s.fillFrames = fill / 2; return s } }
    /// Monotonic clock in seconds (injectable for tests).
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    private var _mode: Mode
    private var _latency = 0.06
    private var _speedHint: Double?
    private var _stats = Stats()
    private var ring: [Float]
    private var readPos = 0, writePos = 0, fill = 0      // in floats (interleaved stereo)
    private var mutex = os_unfair_lock()
    // adaptive state
    private var priming = true
    private var frac = 0.0
    private var hL: Float = 0, hR: Float = 0              // the frame before readPos (x[-1])
    private var corr = 0.0, integ = 0.0, eFilt = 0.0
    private var estSpeed = 1.0, estFrames = 0, estStart = -1.0, lastPush = -1.0

    public init(rate: Double = 48000, seconds: Double = 1.0, mode: Mode = .legacy) {
        self.rate = rate
        _mode = mode
        ring = [Float](repeating: 0, count: Int(rate * seconds) * 2)
    }

    @inline(__always) private func lock<T>(_ f: () -> T) -> T {
        os_unfair_lock_lock(&mutex); defer { os_unfair_lock_unlock(&mutex) }
        return f()
    }

    private var targetFloats: Int { Int(rate * _latency) * 2 }

    private func resetLocked() {
        fill = 0; readPos = writePos; priming = true; frac = 0; hL = 0; hR = 0; corr = 0; integ = 0; eFilt = 0
        estFrames = 0; estStart = -1
    }

    /// Empties the buffer (pause, reset).
    public func flush() { lock { resetLocked() } }

    /// Producer side: interleaved stereo samples, scaled by `gain`.
    public func push(_ s: UnsafeBufferPointer<Float>, gain: Float = 1) {
        let now = _mode == .adaptive ? clock() : 0
        os_unfair_lock_lock(&mutex); defer { os_unfair_lock_unlock(&mutex) }
        let cap = ring.count
        if _mode == .legacy {
            // drift control: drop input when far ahead of target
            if fill > targetFloats * 3 { _stats.droppedBlocks += 1; return }
            for v in s {
                ring[writePos] = gain == 1 ? v : v * gain; writePos = (writePos + 1) % cap
                if fill < cap { fill += 1 } else { readPos = (readPos + 1) % cap }
            }
            return
        }
        // adaptive: producer speed estimate (frames per second of real time over 2 s windows: the app's frame
        // pacing is bursty, only a sustained rate is a speed). A gap of more than 0.2 s between two pushes is a
        // host stall (window restarted), not a speed. Hosts that know their speed set `speedHint` instead.
        if estStart < 0 || now - lastPush > 0.2 { estStart = now; estFrames = 0 }
        else { estFrames += s.count / 2 }
        lastPush = now
        let el = now - estStart
        if el >= 2.0 {
            let inst = min(1.2, max(0.2, Double(estFrames) / (el * rate)))
            // a large change (entering / leaving slow motion) is taken at once, small ones are smoothed
            estSpeed = abs(inst - estSpeed) > 0.1 ? inst : estSpeed * 0.6 + inst * 0.4
            estStart = now; estFrames = 0
        }
        _stats.producerSpeed = estSpeed
        // overrun (the ring is full, or a burst of catch-up frames piled up more than 4x the latency target):
        // keep the newest `target` worth of audio, so the latency never grows
        if fill + s.count > min(cap - 16, max(targetFloats * 4, targetFloats + 4 * s.count)) {
            let keep = min(targetFloats, cap / 2)
            let drop = (fill - keep) & ~1
            if drop > 0 { readPos = (readPos + drop) % cap; fill -= drop }
            _stats.overruns += 1
        }
        for v in s {
            ring[writePos] = gain == 1 ? v : v * gain; writePos = (writePos + 1) % cap
            if fill < cap { fill += 1 } else { readPos = (readPos + 1) % cap }
        }
    }

    /// Consumer side (real-time thread): `n` frames into `l` / `r`.
    public func render(_ n: Int, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) {
        os_unfair_lock_lock(&mutex); defer { os_unfair_lock_unlock(&mutex) }
        let cap = ring.count
        if _mode == .legacy {
            for i in 0..<n {
                if fill >= 2 {
                    l[i] = ring[readPos]; r[i] = ring[readPos + 1]
                    readPos = (readPos + 2) % cap; fill -= 2
                } else { l[i] = 0; r[i] = 0 }
            }
            return
        }
        let target = targetFloats
        if priming {
            if fill >= target { priming = false; frac = 0 } else {
                for i in 0..<n { l[i] = 0; r[i] = 0 }
                return
            }
        }
        // rate: producer speed x fill correction (+-0.5 %)
        // (an estimate within 10 % of real time is jitter / lost frames: the fill control and re-priming handle it)
        var speed = _speedHint ?? (estSpeed < 0.9 ? estSpeed : 1)
        speed = min(1.25, max(0.2, speed))
        // PI control of the fill: the integral term absorbs a constant clock offset (the fill then settles at
        // the target instead of wherever the proportional term alone balances it), both limited to +-0.5 %.
        // The fill is low-passed first (~0.5 s): it jumps by a whole emulated frame at every push.
        let e0 = Double(fill - target) / Double(max(2, target))
        let a = min(1, Double(n) / (rate * 0.5))
        eFilt += (e0 - eFilt) * a
        let e = eFilt
        integ = max(-0.005, min(0.005, integ + e * Double(n) / rate * 0.002))
        let want = max(-0.005, min(0.005, e * 0.01 + integ))
        corr += (want - corr) * 0.05
        let step = speed * (1 + corr)
        _stats.ratio = step
        var i = 0
        while i < n {
            if fill < 6 {                                  // underrun: silence, re-prime
                while i < n { l[i] = 0; r[i] = 0; i += 1 }
                priming = true; _stats.underruns += 1
                break
            }
            let p1 = (readPos + 2) % cap, p2 = (readPos + 4) % cap
            let t = Float(frac)
            l[i] = HostAudioStream.hermite(hL, ring[readPos], ring[p1], ring[p2], t)
            r[i] = HostAudioStream.hermite(hR, ring[readPos + 1], ring[p1 + 1], ring[p2 + 1], t)
            i += 1
            frac += step
            while frac >= 1 && fill >= 6 {
                frac -= 1
                hL = ring[readPos]; hR = ring[readPos + 1]
                readPos = (readPos + 2) % cap; fill -= 2
            }
        }
    }

    @inline(__always) static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }
}
