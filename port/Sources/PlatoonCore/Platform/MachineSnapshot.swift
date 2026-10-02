import Foundation

// Savestate support for the virtual hardware (roadmap F5/L1). Captures and restores the complete state of the
// Machine's components: chip RAM, custom registers, copper, sprites, the display canvas, both CIAs (timers,
// TOD, alarm, ICR, latches), Paula's voices and filter, and the input state. Only the host-installed closures
// (interrupt handlers, Paula output, frame hook) are not part of the state: the game layer reinstalls the
// interrupt handlers from the RAM vectors after a restore (Game/Snapshot).
//
// Nothing here is used by the normal frame path; capture reads fields directly (never through register reads,
// which have side effects), so taking a snapshot does not change the emulation.

/// Complete state of a Machine at a point where the game thread runs (see Machine.captureState).
public struct MachineState {
    public var frameCount: UInt64
    /// Beam line at which the host was parked, and whether after the line's endLine (pending-jump resumption).
    public var line: Int
    public var afterEndLine: Bool
    public var memory: [UInt8]
    public var chip: ChipsetState
    public var input: InputState
}

public struct ChipsetState {
    var regs: [UInt16]
    var dmacon: UInt16, intena: UInt16, intreq: UInt16, adkcon: UInt16
    var vpos: Int, frame: UInt64
    var bzero: Bool, blitCount: UInt64
    var joy0dat: UInt16, joy1dat: UInt16
    var copPC: UInt32, copWaiting: Bool, copW1: UInt16, copW2: UInt16, copHalt: Bool
    var sprites: [Chipset.Sprite]
    var ipl: Int
    var ciaTickAcc: Double
    public var canvas: [UInt32]
    var ciaA: CIAState, ciaB: CIAState
    var paula: PaulaState
}

public struct CIAState {
    var pra: UInt8, prb: UInt8, ddra: UInt8, ddrb: UInt8
    var ta: UInt16, tb: UInt16, taLatch: UInt16, tbLatch: UInt16
    var cra: UInt8, crb: UInt8, icr: UInt8, icrMask: UInt8, sdr: UInt8
    var tod: UInt32, todLatch: UInt32, alarm: UInt32
    var todLatched: Bool
    var tickAcc: Double
}

public struct PaulaState {
    var ch: [Paula.Channel]
    var dmacon: UInt16
    var lpL: Float, lpR: Float
    var sampleAcc: Double
    /// A500 LED filter history (in-memory snapshots only; a file restore starts it from silence, like vAmiga).
    var led = PaulaLEDFilter()
}

public struct InputState {
    public var up: Bool, down: Bool, left: Bool, right: Bool, fire: Bool, fire0: Bool
    public var keyQueue: [UInt8]
    public var keyDelay: Int
}

// MARK: - capture / restore

extension Chipset {
    func captureState() -> ChipsetState {
        ChipsetState(regs: regs, dmacon: dmacon, intena: intena, intreq: intreq, adkcon: adkcon, vpos: vpos, frame: frame,
                     bzero: bzero, blitCount: blitCount, joy0dat: joy0dat, joy1dat: joy1dat,
                     copPC: copPC, copWaiting: copWaiting, copW1: copW1, copW2: copW2, copHalt: copHalt,
                     sprites: spr, ipl: ipl, ciaTickAcc: ciaTickAcc,
                     canvas: Array(UnsafeBufferPointer(start: canvas, count: Chipset.canvasWidth * Chipset.canvasHeight)),
                     ciaA: ciaA.captureState(), ciaB: ciaB.captureState(), paula: paula.captureState())
    }

    /// Restores the state without side effects (no interrupt dispatch, no Paula DMA settling).
    func restoreState(_ s: ChipsetState) {
        regs = s.regs
        dmacon = s.dmacon; intena = s.intena; intreq = s.intreq; adkcon = s.adkcon
        vpos = s.vpos; frame = s.frame
        bzero = s.bzero; blitCount = s.blitCount
        joy0dat = s.joy0dat; joy1dat = s.joy1dat
        copPC = s.copPC; copWaiting = s.copWaiting; copW1 = s.copW1; copW2 = s.copW2; copHalt = s.copHalt
        spr = s.sprites
        ipl = s.ipl
        inDispatch = false
        ciaTickAcc = s.ciaTickAcc
        s.canvas.withUnsafeBufferPointer { canvas.update(from: $0.baseAddress!, count: min($0.count, Chipset.canvasWidth * Chipset.canvasHeight)) }
        ciaA.restoreState(s.ciaA); ciaB.restoreState(s.ciaB)
        paula.restoreState(s.paula)
    }
}

extension CIA {
    func captureState() -> CIAState {
        CIAState(pra: pra, prb: prb, ddra: ddra, ddrb: ddrb, ta: ta, tb: tb, taLatch: taLatch, tbLatch: tbLatch,
                 cra: cra, crb: crb, icr: icr, icrMask: icrMask, sdr: sdr, tod: tod, todLatch: todLatch, alarm: alarm,
                 todLatched: todLatched, tickAcc: tickAcc)
    }
    func restoreState(_ s: CIAState) {
        pra = s.pra; prb = s.prb; ddra = s.ddra; ddrb = s.ddrb
        ta = s.ta; tb = s.tb; taLatch = s.taLatch; tbLatch = s.tbLatch
        cra = s.cra; crb = s.crb; icr = s.icr; icrMask = s.icrMask; sdr = s.sdr
        tod = s.tod; todLatch = s.todLatch; alarm = s.alarm
        todLatched = s.todLatched; tickAcc = s.tickAcc
    }
}

extension Paula {
    func captureState() -> PaulaState { PaulaState(ch: ch, dmacon: dmacon, lpL: lpL, lpR: lpR, sampleAcc: sampleAcc, led: ledFilter) }
    func restoreState(_ s: PaulaState) {
        ch = s.ch; dmacon = s.dmacon; lpL = s.lpL; lpR = s.lpR; sampleAcc = s.sampleAcc; ledFilter = s.led
    }
}

extension Input {
    func captureState() -> InputState {
        InputState(up: up, down: down, left: left, right: right, fire: fire, fire0: fire0, keyQueue: keyQueue, keyDelay: keyDelay)
    }
    func restoreState(_ s: InputState) {
        up = s.up; down = s.down; left = s.left; right = s.right; fire = s.fire; fire0 = s.fire0
        keyQueue = s.keyQueue; keyDelay = s.keyDelay
    }
    /// Drops queued key events (a restored game in the app starts from the player's current input).
    public func clearQueuedKeys() { keyQueue.removeAll(); keyDelay = 0 }
}

// MARK: - binary encoding (little-endian, versioned by the Game/Snapshot container)

/// Byte writer for snapshot encoding.
public struct SnapWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    public mutating func int(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func bytes(_ b: [UInt8]) { u32(UInt32(b.count)); data.append(contentsOf: b) }
    public mutating func raw(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
    public mutating func string(_ s: String) { bytes(Array(s.utf8)) }
}

/// Byte reader for snapshot decoding; throws on truncated input.
public struct SnapReader {
    public enum Failure: Error { case truncated }
    let data: [UInt8]
    public private(set) var pos = 0
    public init(_ d: Data) { data = [UInt8](d) }
    public init(_ b: [UInt8]) { data = b }
    public var atEnd: Bool { pos >= data.count }
    mutating func need(_ n: Int) throws { if n < 0 || pos + n > data.count { throw Failure.truncated } }
    public mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return data[pos] }
    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 { try need(2); defer { pos += 2 }; return UInt16(data[pos]) | UInt16(data[pos + 1]) << 8 }
    public mutating func u32() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        return UInt32(data[pos]) | UInt32(data[pos + 1]) << 8 | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
    }
    public mutating func u64() throws -> UInt64 { let lo = try u32(), hi = try u32(); return UInt64(lo) | UInt64(hi) << 32 }
    public mutating func int() throws -> Int { Int(Int64(bitPattern: try u64())) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func bytes() throws -> [UInt8] {
        let n = Int(try u32()); try need(n); defer { pos += n }; return Array(data[pos..<(pos + n)])
    }
    public mutating func raw() throws -> Data { Data(try bytes()) }
    public mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
}

extension MachineState {
    public func encode(into w: inout SnapWriter) {
        w.u64(frameCount); w.int(line); w.bool(afterEndLine)
        w.bytes(memory)
        chip.encode(into: &w)
        w.bool(input.up); w.bool(input.down); w.bool(input.left); w.bool(input.right); w.bool(input.fire); w.bool(input.fire0)
        w.bytes(input.keyQueue); w.int(input.keyDelay)
    }
    public static func decode(_ r: inout SnapReader) throws -> MachineState {
        let fc = try r.u64(), line = try r.int(), after = try r.bool()
        let mem = try r.bytes()
        guard mem.count == Memory.size else { throw SnapReader.Failure.truncated }
        let chip = try ChipsetState.decode(&r)
        let inp = InputState(up: try r.bool(), down: try r.bool(), left: try r.bool(), right: try r.bool(), fire: try r.bool(),
                             fire0: try r.bool(), keyQueue: try r.bytes(), keyDelay: try r.int())
        return MachineState(frameCount: fc, line: line, afterEndLine: after, memory: mem, chip: chip, input: inp)
    }
}

extension ChipsetState {
    func encode(into w: inout SnapWriter) {
        w.u32(UInt32(regs.count)); for r in regs { w.u16(r) }
        w.u16(dmacon); w.u16(intena); w.u16(intreq); w.u16(adkcon)
        w.int(vpos); w.u64(frame); w.bool(bzero); w.u64(blitCount); w.u16(joy0dat); w.u16(joy1dat)
        w.u32(copPC); w.bool(copWaiting); w.u16(copW1); w.u16(copW2); w.bool(copHalt)
        w.u32(UInt32(sprites.count))
        for s in sprites {
            w.int(s.state); w.u16(s.pos); w.u16(s.ctl); w.u16(s.data); w.u16(s.datb)
            w.int(s.vstart); w.int(s.vstop); w.int(s.hstart); w.bool(s.attached); w.bool(s.armed)
        }
        w.int(ipl); w.f64(ciaTickAcc)
        var c = [UInt8](); c.reserveCapacity(canvas.count * 4)
        for p in canvas { c.append(UInt8(p & 0xff)); c.append(UInt8((p >> 8) & 0xff)); c.append(UInt8((p >> 16) & 0xff)); c.append(UInt8(p >> 24)) }
        w.bytes(c)
        ciaA.encode(into: &w); ciaB.encode(into: &w)
        paula.encode(into: &w)
    }
    static func decode(_ r: inout SnapReader) throws -> ChipsetState {
        let nr = Int(try r.u32()); guard nr == 0x100 else { throw SnapReader.Failure.truncated }
        var regs = [UInt16](); regs.reserveCapacity(nr)
        for _ in 0..<nr { regs.append(try r.u16()) }
        let dmacon = try r.u16(), intena = try r.u16(), intreq = try r.u16(), adkcon = try r.u16()
        let vpos = try r.int(), frame = try r.u64(), bzero = try r.bool(), blitCount = try r.u64()
        let j0 = try r.u16(), j1 = try r.u16()
        let copPC = try r.u32(), copWaiting = try r.bool(), copW1 = try r.u16(), copW2 = try r.u16(), copHalt = try r.bool()
        let ns = Int(try r.u32()); guard ns == 8 else { throw SnapReader.Failure.truncated }
        var sprites: [Chipset.Sprite] = []
        for _ in 0..<ns {
            var s = Chipset.Sprite()
            s.state = try r.int(); s.pos = try r.u16(); s.ctl = try r.u16(); s.data = try r.u16(); s.datb = try r.u16()
            s.vstart = try r.int(); s.vstop = try r.int(); s.hstart = try r.int(); s.attached = try r.bool(); s.armed = try r.bool()
            sprites.append(s)
        }
        let ipl = try r.int(), acc = try r.f64()
        let c = try r.bytes()
        let n = Chipset.canvasWidth * Chipset.canvasHeight
        guard c.count == n * 4 else { throw SnapReader.Failure.truncated }
        var canvas = [UInt32](repeating: 0, count: n)
        for i in 0..<n { canvas[i] = UInt32(c[4 * i]) | UInt32(c[4 * i + 1]) << 8 | UInt32(c[4 * i + 2]) << 16 | UInt32(c[4 * i + 3]) << 24 }
        let a = try CIAState.decode(&r), b = try CIAState.decode(&r)
        let p = try PaulaState.decode(&r)
        return ChipsetState(regs: regs, dmacon: dmacon, intena: intena, intreq: intreq, adkcon: adkcon, vpos: vpos, frame: frame,
                            bzero: bzero, blitCount: blitCount, joy0dat: j0, joy1dat: j1, copPC: copPC, copWaiting: copWaiting,
                            copW1: copW1, copW2: copW2, copHalt: copHalt, sprites: sprites, ipl: ipl, ciaTickAcc: acc,
                            canvas: canvas, ciaA: a, ciaB: b, paula: p)
    }
}

extension CIAState {
    func encode(into w: inout SnapWriter) {
        w.u8(pra); w.u8(prb); w.u8(ddra); w.u8(ddrb); w.u16(ta); w.u16(tb); w.u16(taLatch); w.u16(tbLatch)
        w.u8(cra); w.u8(crb); w.u8(icr); w.u8(icrMask); w.u8(sdr); w.u32(tod); w.u32(todLatch); w.u32(alarm)
        w.bool(todLatched); w.f64(tickAcc)
    }
    static func decode(_ r: inout SnapReader) throws -> CIAState {
        CIAState(pra: try r.u8(), prb: try r.u8(), ddra: try r.u8(), ddrb: try r.u8(), ta: try r.u16(), tb: try r.u16(),
                 taLatch: try r.u16(), tbLatch: try r.u16(), cra: try r.u8(), crb: try r.u8(), icr: try r.u8(),
                 icrMask: try r.u8(), sdr: try r.u8(), tod: try r.u32(), todLatch: try r.u32(), alarm: try r.u32(),
                 todLatched: try r.bool(), tickAcc: try r.f64())
    }
}

extension PaulaState {
    /// Real-A500 Paula state (pending audio DMA requests, LED filter history), written as a trailer after the game
    /// snapshot payload so files stay readable both ways; files without it restore these at rest.
    func encodeA500(into w: inout SnapWriter) {
        w.string("paula-a500")
        for c in ch { w.f64(c.reqTime) }
        led.encode(into: &w)
    }
    mutating func decodeA500(_ r: inout SnapReader) throws {
        guard try r.string() == "paula-a500" else { return }
        for i in 0..<ch.count { ch[i].reqTime = try r.f64() }
        try led.decode(&r)
    }

    func encode(into w: inout SnapWriter) {
        w.u32(UInt32(ch.count))
        for c in ch {
            w.u32(c.lc); w.u16(c.len); w.u16(c.per); w.u16(c.vol); w.bool(c.active); w.u32(c.ptr); w.int(c.wordsLeft)
            w.u16(c.word); w.int(c.byteIndex); w.f64(c.phase); w.f32(c.current); w.f32(c.previous); w.bool(c.pendingIRQ)
        }
        w.u16(dmacon); w.f32(lpL); w.f32(lpR); w.f64(sampleAcc)
    }
    static func decode(_ r: inout SnapReader) throws -> PaulaState {
        let n = Int(try r.u32()); guard n == 4 else { throw SnapReader.Failure.truncated }
        var ch: [Paula.Channel] = []
        for _ in 0..<n {
            var c = Paula.Channel()
            c.lc = try r.u32(); c.len = try r.u16(); c.per = try r.u16(); c.vol = try r.u16(); c.active = try r.bool()
            c.ptr = try r.u32(); c.wordsLeft = try r.int(); c.word = try r.u16(); c.byteIndex = try r.int()
            c.phase = try r.f64(); c.current = try r.f32(); c.previous = try r.f32(); c.pendingIRQ = try r.bool()
            ch.append(c)
        }
        return PaulaState(ch: ch, dmacon: try r.u16(), lpL: try r.f32(), lpR: try r.f32(), sampleAcc: try r.f64())
    }
}
