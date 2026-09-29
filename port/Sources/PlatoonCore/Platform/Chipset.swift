// Virtual OCS chipset: custom register file, interrupts, copper, sprite DMA and the Denise
// display (bitplanes, dual playfield, EHB, sprites with priorities) rendering into an RGB canvas.
//
// The translated game code talks to it the way the original talked to $DFF000:
//   chip.write(0x096, 0x8020)      // move.w #$8020,$dff096
//   chip.writeL(0x080, copperList) // move.l #list,$dff080
//   let v = chip.read(0x00c)       // move.w $dff00c,d0

public final class Chipset {
    public static let linesPerFrame = 313
    public static let canvasWidth = 768      // hires pixels; lowres pixels are doubled
    public static let canvasHeight = 290
    public static let canvasH0 = 0x60        // DIW horizontal position of canvas x=0 (lowres units)
    public static let canvasV0 = 0x18        // beam line of canvas y=0

    let mem: Memory
    public var regs = [UInt16](repeating: 0, count: 0x100)
    public var dmacon: UInt16 = 0, intena: UInt16 = 0, intreq: UInt16 = 0, adkcon: UInt16 = 0
    public internal(set) var vpos = 0
    public internal(set) var frame: UInt64 = 0
    public var bzero = false
    public var blitCount: UInt64 = 0
    public var blitLog: ((Chipset, Int, Int) -> Void)?

    public let ciaA = CIA(isB: false)
    public let ciaB = CIA(isB: true)
    public let paula: Paula

    // copper
    var copPC: UInt32 = 0, copWaiting = false, copW1: UInt16 = 0, copW2: UInt16 = 0, copHalt = false

    // sprites
    struct Sprite { var state = 0; var pos: UInt16 = 0, ctl: UInt16 = 0, data: UInt16 = 0, datb: UInt16 = 0
        var vstart = 0, vstop = 0, hstart = 0; var attached = false, armed = false }
    var spr = [Sprite](repeating: Sprite(), count: 8)

    /// RGB canvas (0xFFRRGGBB), canvasWidth x canvasHeight.
    public let canvas: UnsafeMutablePointer<UInt32>

    // interrupts: handlers per CPU level (1...6). The Machine installs translated handlers here.
    public var interruptHandlers = [(() -> Void)?](repeating: nil, count: 8)
    /// Current CPU interrupt priority mask (SR bits 8-10). Handlers run with the mask raised to their level.
    public var ipl = 0
    var inDispatch = false

    init(memory: Memory) {
        mem = memory
        paula = Paula(memory: memory)
        canvas = .allocate(capacity: Chipset.canvasWidth * Chipset.canvasHeight)
        canvas.initialize(repeating: 0xff000000, count: Chipset.canvasWidth * Chipset.canvasHeight)
        paula.raiseInterrupt = { [unowned self] bits in self.raise(bits) }
        ciaA.onChange = { [unowned self] in self.ciaCheck() }
        ciaB.onChange = { [unowned self] in self.ciaCheck() }
    }

    // MARK: pointers
    @inline(__always) func ptr(_ r: Int) -> UInt32 { (UInt32(regs[r >> 1]) << 16 | UInt32(regs[(r >> 1) + 1])) & 0x1ffffe }
    @inline(__always) func setPtr(_ r: Int, _ v: UInt32) { regs[r >> 1] = UInt16((v >> 16) & 0x1f); regs[(r >> 1) + 1] = UInt16(v & 0xfffe) }

    // MARK: interrupts
    public func raise(_ bits: UInt16) { intreq |= bits; checkInterrupts() }

    public var pendingLevel: Int {
        guard intena & 0x4000 != 0 else { return 0 }
        let p = intena & intreq & 0x3fff
        if p & 0x2000 != 0 { return 6 }
        if p & 0x1800 != 0 { return 5 }
        if p & 0x0780 != 0 { return 4 }
        if p & 0x0070 != 0 { return 3 }
        if p & 0x0008 != 0 { return 2 }
        if p & 0x0007 != 0 { return 1 }
        return 0
    }

    /// Runs interrupt handlers for any pending level above the current mask (synchronously).
    public func checkInterrupts() {
        var guardCount = 0
        while true {
            let lvl = pendingLevel
            guard lvl > ipl, let h = interruptHandlers[lvl] else { return }
            let saved = ipl
            ipl = lvl
            h()
            ipl = saved
            guardCount += 1
            if guardCount > 8 { return } // handler did not acknowledge; avoid livelock
        }
    }

    func ciaCheck() {
        if ciaA.interruptPending { intreq |= 0x0008 }
        if ciaB.interruptPending { intreq |= 0x2000 }
        checkInterrupts()
    }

    // MARK: register access
    public func read(_ reg: Int) -> UInt16 {
        switch reg & 0x1fe {
        case 0x000: return regs[0]
        case 0x002: return dmacon | (bzero ? 0x2000 : 0)
        case 0x004: return ((frame & 1) != 0 ? 0x8000 : 0) | UInt16((vpos >> 8) & 1)
        case 0x006: return UInt16((vpos & 0xff) << 8) | 0x40
        case 0x00a: return joy0dat
        case 0x00c: return joy1dat
        case 0x010: return adkcon
        case 0x016: return 0xff00
        case 0x018: return 0x3000
        case 0x01c: return intena
        case 0x01e: return intreq
        default: return regs[(reg & 0x1fe) >> 1]
        }
    }
    public var joy0dat: UInt16 = 0, joy1dat: UInt16 = 0

    public func readL(_ reg: Int) -> UInt32 { UInt32(read(reg)) << 16 | UInt32(read(reg + 2)) }

    public func writeL(_ reg: Int, _ v: UInt32) { write(reg, UInt16(v >> 16)); write(reg + 2, UInt16(truncatingIfNeeded: v)) }

    public func write(_ reg: Int, _ v: UInt16, fromCopper: Bool = false) {
        let reg = reg & 0x1fe
        switch reg {
        case 0x058:
            var h = Int(v >> 6), w = Int(v & 63)
            if h == 0 { h = 1024 }
            if w == 0 { w = 64 }
            regs[0x2c] = v
            doBlit(width: w, height: h); return
        case 0x05e:
            var h = Int(regs[0x2e] & 0x7fff), w = Int(v & 0x7ff)
            if h == 0 { h = 0x8000 }
            if w == 0 { w = 0x800 }
            doBlit(width: w, height: h); return
        case 0x088: copPC = ptr(0x80); copWaiting = false; copHalt = false; return
        case 0x08a: copPC = ptr(0x84); copWaiting = false; copHalt = false; return
        case 0x096:
            if v & 0x8000 != 0 { dmacon |= v & 0x7ff } else { dmacon &= ~(v & 0x7ff) }
            paula.dmaconChanged(dmacon)
            return
        case 0x09a:
            if v & 0x8000 != 0 { intena |= v & 0x7fff } else { intena &= ~(v & 0x7fff) }
            checkInterrupts(); return
        case 0x09c:
            if v & 0x8000 != 0 { intreq |= v & 0x7fff } else { intreq &= ~(v & 0x7fff) }
            ciaCheck(); return
        case 0x09e:
            if v & 0x8000 != 0 { adkcon |= v & 0x7fff } else { adkcon &= ~(v & 0x7fff) }
            return
        default: break
        }
        if reg >= 0x140 && reg < 0x180 {
            let i = (reg - 0x140) >> 3, r = (reg >> 1) & 3
            switch r {
            case 0:
                spr[i].pos = v; spr[i].hstart = Int(v & 0xff) << 1 | Int(spr[i].ctl & 1)
                spr[i].vstart = Int(v >> 8) | Int(spr[i].ctl & 4) << 6
            case 1:
                spr[i].ctl = v; spr[i].hstart = Int(spr[i].pos & 0xff) << 1 | Int(v & 1)
                spr[i].attached = v & 0x80 != 0; spr[i].armed = false
            case 2: spr[i].data = v; spr[i].armed = true
            default: spr[i].datb = v
            }
        }
        if reg >= 0xa0 && reg < 0xe0 { paula.registerWritten(channel: (reg - 0xa0) >> 4, offset: reg & 15, value: v) }
        regs[reg >> 1] = (reg >= 0x180 && reg < 0x1c0) ? v & 0xfff : v
    }

    // MARK: copper
    func copperRun(line: Int, hposLimit: Int) {
        guard dmacon & 0x280 == 0x280 else { return }
        var guardCount = 0
        while !copHalt && guardCount < 4000 {
            guardCount += 1
            if copWaiting {
                let vp = Int(copW1 >> 8), hp = Int(copW1 & 0xfe)
                let ve = Int((copW2 >> 8) & 0x7f) | 0x80, he = Int(copW2 & 0xfe)
                let v = line & 0xff
                let ok = (v & ve) > (vp & ve) || ((v & ve) == (vp & ve) && (hposLimit & he) >= (hp & he))
                if !ok { return }
                copWaiting = false
                continue
            }
            let w1 = mem.r16(copPC), w2 = mem.r16(copPC &+ 2)
            copPC &+= 4
            if w1 & 1 == 0 {
                let reg = Int(w1 & 0x1fe)
                if reg < 0x40 && regs[0x2e >> 1] & 2 == 0 { copHalt = true; return }
                if reg < 0x20 { copHalt = true; return }
                write(reg, w2, fromCopper: true)
            } else if w2 & 1 == 0 {
                copW1 = w1; copW2 = w2; copWaiting = true
                if w1 == 0xffff && w2 == 0xfffe { copHalt = true; return }
            } else {
                let vp = Int(w1 >> 8), hp = Int(w1 & 0xfe)
                let ve = Int((w2 >> 8) & 0x7f) | 0x80, he = Int(w2 & 0xfe)
                let v = line & 0xff
                if (v & ve) > (vp & ve) || ((v & ve) == (vp & ve) && (hposLimit & he) >= (hp & he)) { copPC &+= 4 }
            }
        }
    }

    func startFrame() {
        copPC = ptr(0x80); copWaiting = false; copHalt = false
        for i in 0..<8 { spr[i].armed = false; spr[i].state = 0 }
    }

    // MARK: sprites
    func spriteFetch(_ i: Int, _ pr: Int) {
        let p = ptr(pr)
        spr[i].pos = mem.r16(p); spr[i].ctl = mem.r16(p &+ 2); setPtr(pr, p &+ 4)
        let s = spr[i]
        spr[i].vstart = Int(s.pos >> 8) | Int(s.ctl & 4) << 6
        spr[i].vstop = Int(s.ctl >> 8) | Int(s.ctl & 2) << 7
        spr[i].hstart = Int(s.pos & 0xff) << 1 | Int(s.ctl & 1)
        spr[i].attached = s.ctl & 0x80 != 0
        spr[i].armed = false
    }

    func spritesLine(_ v: Int) {
        guard dmacon & 0x220 == 0x220 else { return }
        for i in 0..<8 {
            let pr = 0x120 + i * 4
            if v == 0x19 { spriteFetch(i, pr); spr[i].state = 1; continue }
            if v < 0x1a { continue }
            if spr[i].state == 1 && v == spr[i].vstart { spr[i].state = 2 }
            if spr[i].state == 2 {
                if v == spr[i].vstop {
                    spriteFetch(i, pr)
                    spr[i].state = (spr[i].pos == 0 && spr[i].ctl == 0) ? 0 : 1
                    if spr[i].state == 1 && v == spr[i].vstart { spr[i].state = 2 }
                } else {
                    let p = ptr(pr)
                    spr[i].data = mem.r16(p); spr[i].datb = mem.r16(p &+ 2); setPtr(pr, p &+ 4)
                    spr[i].armed = true
                }
            } else { spr[i].armed = false }
        }
    }

    // MARK: display
    @inline(__always) static func rgb(_ c: UInt16) -> UInt32 {
        let r = UInt32((c >> 8) & 15) * 17, g = UInt32((c >> 4) & 15) * 17, b = UInt32(c & 15) * 17
        return 0xff000000 | r << 16 | g << 8 | b
    }

    var pix = [UInt8](repeating: 0, count: Chipset.canvasWidth)
    var sprPix = [UInt8](repeating: 0, count: Chipset.canvasWidth / 2)
    var sprIdx = [UInt8](repeating: 0, count: Chipset.canvasWidth / 2)
    var words = [UInt16](repeating: 0, count: 6 * 64)

    func renderLine(_ v: Int) {
        let W = Chipset.canvasWidth
        let cy = v - Chipset.canvasV0
        let bplcon0 = regs[0x100 >> 1], bplcon1 = regs[0x102 >> 1], bplcon2 = regs[0x104 >> 1]
        let diwstrt = regs[0x8e >> 1], diwstop = regs[0x90 >> 1]
        let vstart = Int(diwstrt >> 8), vstop = Int(diwstop >> 8) | (diwstop & 0x8000 != 0 ? 0 : 0x100)
        let hstart = Int(diwstrt & 0xff), hstop = Int(diwstop & 0xff) | 0x100
        let nplanes = Int((bplcon0 >> 12) & 7)
        let hires = bplcon0 & 0x8000 != 0
        let dpf = bplcon0 & 0x400 != 0
        let ham = bplcon0 & 0x800 != 0
        let bplDMA = dmacon & 0x300 == 0x300
        let inV = v >= vstart && v < vstop
        for i in 0..<W { pix[i] = 0 }
        for i in 0..<(W / 2) { sprPix[i] = 0 }
        if inV && bplDMA && nplanes > 0 {
            var ddfstrt = Int(regs[0x92 >> 1] & 0xfc), ddfstop = Int(regs[0x94 >> 1] & 0xfc)
            if ddfstrt < 0x18 { ddfstrt = 0x18 }
            if ddfstop > 0xd8 { ddfstop = 0xd8 }
            var nwords = hires ? ((ddfstop - ddfstrt) / 8 + 1) * 2 : (ddfstop - ddfstrt) / 8 + 1
            nwords = max(0, min(64, nwords))
            for p in 0..<nplanes {
                let pt = ptr(0xe0 + p * 4)
                for w in 0..<nwords { words[p * 64 + w] = mem.r16(pt &+ UInt32(w * 2)) }
                let mod = Int32(Int16(bitPattern: (p & 1) != 0 ? regs[0x10a >> 1] : regs[0x108 >> 1]))
                setPtr(0xe0 + p * 4, pt &+ UInt32(nwords * 2) &+ UInt32(bitPattern: mod))
            }
            let delay1 = Int(bplcon1 & 15), delay2 = Int((bplcon1 >> 4) & 15)
            let x0 = (ddfstrt * 2 + 17 - Chipset.canvasH0) * 2
            let npix = nwords * 16
            for p in 0..<nplanes {
                let delay = (p & 1) != 0 ? delay2 : delay1
                let bitv = UInt8(1 << p)
                for k in 0..<npix {
                    let wv = words[p * 64 + (k >> 4)]
                    if (wv >> UInt16(15 - (k & 15))) & 1 == 0 { continue }
                    let x = hires ? x0 + k + delay * 2 : x0 + (k + delay) * 2
                    if x < 0 || x >= W { continue }
                    pix[x] |= bitv
                    if !hires && x + 1 < W { pix[x + 1] |= bitv }
                }
            }
        }
        // sprites
        for i in stride(from: 7, through: 0, by: -1) where spr[i].armed {
            let s = spr[i]
            let att = (i & 1) != 0 && s.attached && spr[i - 1].armed
            if (i & 1) == 0 && spr[i + 1].attached && spr[i + 1].armed { continue } // drawn with its pair
            for k in 0..<16 {
                let b = UInt16(15 - k)
                let c = Int((s.data >> b) & 1) | Int((s.datb >> b) & 1) << 1
                let x = s.hstart + 1 + k - Chipset.canvasH0
                if x < 0 || x >= W / 2 { continue }
                if att {
                    let e = spr[i - 1]
                    let ce = Int((e.data >> b) & 1) | Int((e.datb >> b) & 1) << 1
                    let col = ce | c << 2
                    if col != 0 { sprPix[x] = UInt8(16 + col); sprIdx[x] = UInt8(i >> 1) }
                } else if c != 0 { sprPix[x] = UInt8(16 + (i >> 1) * 4 + c); sprIdx[x] = UInt8(i >> 1) }
            }
        }
        guard cy >= 0 && cy < Chipset.canvasHeight else { return }
        let row = canvas + cy * W
        let pf1p = Int(bplcon2 & 7), pf2p = Int((bplcon2 >> 3) & 7), pf2pri = bplcon2 & 0x40 != 0
        var hamcol = regs[0x180 >> 1]
        let col0 = Chipset.rgb(regs[0x180 >> 1])
        for x in 0..<W {
            let lx = x / 2 + Chipset.canvasH0
            guard inV && lx >= hstart && lx < hstop else { row[x] = col0; continue }
            let p = pix[x]
            var front = 0
            var c: UInt16
            if dpf {
                let p1 = Int(p & 1) | Int((p >> 1) & 2) | Int((p >> 2) & 4)
                let p2 = Int((p >> 1) & 1) | Int((p >> 2) & 2) | Int((p >> 3) & 4)
                var ci = 0
                if pf2pri {
                    if p2 != 0 { ci = 8 + p2; front = 2 } else if p1 != 0 { ci = p1; front = 1 }
                } else {
                    if p1 != 0 { ci = p1; front = 1 } else if p2 != 0 { ci = 8 + p2; front = 2 }
                }
                c = regs[(0x180 >> 1) + ci]
            } else if ham && nplanes >= 5 {
                let val = UInt16(p & 15)
                switch p >> 4 {
                case 0: hamcol = regs[(0x180 >> 1) + Int(val)]
                case 1: hamcol = (hamcol & 0xff0) | val
                case 2: hamcol = (hamcol & 0x0ff) | val << 8
                default: hamcol = (hamcol & 0xf0f) | val << 4
                }
                c = hamcol; front = p != 0 ? 1 : 0
            } else {
                if nplanes == 6 && p & 32 != 0 { c = (regs[(0x180 >> 1) + Int(p & 31)] >> 1) & 0x777 }
                else { c = regs[(0x180 >> 1) + Int(p & 31)] }
                front = p != 0 ? 1 : 0
            }
            let sx = x >> 1
            if sprPix[sx] != 0 {
                let pair = Int(sprIdx[sx])
                var sfront = true
                if front == 1 && !(pair < pf1p) { sfront = false }
                if front == 2 && !(pair < pf2p) { sfront = false }
                if sfront { c = regs[(0x180 >> 1) + Int(sprPix[sx])] }
            }
            row[x] = Chipset.rgb(c)
        }
    }

    /// Emulates one beam line: copper (pre-display), sprite DMA, bitplane output.
    func beginLine(_ v: Int) {
        vpos = v
        if v == 0 { startFrame() }
        copperRun(line: v, hposLimit: 0x30)
        spritesLine(v)
        renderLine(v)
    }
    /// Rest of the line after the CPU slot: copper, CIA clocks, audio.
    func endLine(_ v: Int) {
        copperRun(line: v, hposLimit: 0xe2)
        ciaB.todTick()
        ciaTickAcc += 709379.0 / (50.0 * Double(Chipset.linesPerFrame))
        let t = Int(ciaTickAcc); ciaTickAcc -= Double(t)
        ciaA.tick(t); ciaB.tick(t)
        paula.runLine()
    }
    var ciaTickAcc = 0.0
}
