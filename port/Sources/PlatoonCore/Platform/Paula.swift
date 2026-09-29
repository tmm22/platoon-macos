// Paula audio: 4 DMA channels (LC/LEN/PER/VOL), block-start interrupts, stereo mixing.
import Foundation
// Produces float stereo samples at `sampleRate`, delivered through `output`.

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
    }
    var ch = [Channel](repeating: Channel(), count: 4)
    var dmacon: UInt16 = 0
    var raiseInterrupt: ((UInt16) -> Void)?

    // enhancement settings
    public var interpolate = false          // linear interpolation between samples (off = authentic)
    public var stereoSeparation: Float = 1  // 1 = hard Amiga panning, 0 = mono
    public var filterEnabled = true         // A500 fixed low-pass (~4.9 kHz)
    public var volume: Float = 1
    public var musicMuted = false

    var lpL: Float = 0, lpR: Float = 0
    var sampleAcc = 0.0
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

    func dmaconChanged(_ d: UInt16) {
        dmacon = d
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
        ch[c].pendingIRQ = true
        ch[c].current = Float(Int8(bitPattern: UInt8(ch[c].word >> 8)))
    }

    @inline(__always) func advance(_ c: Int) {
        if ch[c].byteIndex == 0 {
            ch[c].byteIndex = 1
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
        for c in 0..<4 where ch[c].pendingIRQ { ch[c].pendingIRQ = false; raiseInterrupt?(0x80 << UInt16(c)) }
        sampleAcc += sampleRate / (50.0 * Double(Chipset.linesPerFrame))
        var n = 0
        let alpha: Float = filterEnabled ? Float(1 - exp(-2 * Double.pi * 4900 / sampleRate)) : 1
        while sampleAcc >= 1 {
            sampleAcc -= 1
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
            if n + 2 <= lineBuf.count { lineBuf[n] = lpL * 0.5 * volume; lineBuf[n + 1] = lpR * 0.5 * volume; n += 2 }
        }
        if n > 0, let out = output { lineBuf.withUnsafeBufferPointer { out(UnsafeBufferPointer(rebasing: $0[0..<n])) } }
    }
}
