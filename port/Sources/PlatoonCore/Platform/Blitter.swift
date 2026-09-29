// Software implementation of the OCS blitter (area + line mode), operating on chip RAM.
// Blits complete instantly when BLTSIZE is written; pointer/data registers are updated exactly
// as the hardware leaves them so code that chains blits keeps working.

extension Chipset {
    @inline(__always) func minterm(_ a: UInt16, _ b: UInt16, _ c: UInt16, _ lf: UInt8) -> UInt16 {
        var r: UInt16 = 0
        if lf & 0x01 != 0 { r |= ~a & ~b & ~c }
        if lf & 0x02 != 0 { r |= ~a & ~b & c }
        if lf & 0x04 != 0 { r |= ~a & b & ~c }
        if lf & 0x08 != 0 { r |= ~a & b & c }
        if lf & 0x10 != 0 { r |= a & ~b & ~c }
        if lf & 0x20 != 0 { r |= a & ~b & c }
        if lf & 0x40 != 0 { r |= a & b & ~c }
        if lf & 0x80 != 0 { r |= a & b & c }
        return r
    }

    func blitLine(height h: Int) {
        let con0 = regs[0x40 >> 1], con1 = regs[0x42 >> 1]
        var ash = Int(con0 >> 12), bsh = Int(con1 >> 12)
        let lf = UInt8(con0 & 0xff)
        let amod = Int32(Int16(bitPattern: regs[0x64 >> 1])), bmod = Int32(Int16(bitPattern: regs[0x62 >> 1]))
        let cmod = UInt32(bitPattern: Int32(Int16(bitPattern: regs[0x60 >> 1])))
        var cpt = ptr(0x48), dpt = ptr(0x54)
        var apt = Int32(Int16(bitPattern: regs[0x52 >> 1]))
        let adat = regs[0x74 >> 1], bdat = regs[0x72 >> 1]
        let sing = con1 & 2 != 0
        var sign = con1 & 0x40 != 0
        var onedot = false, any = false
        for _ in 0..<h {
            let a = (adat & regs[0x44 >> 1]) >> UInt16(ash)
            let b: UInt16 = (bdat >> UInt16(bsh)) & 1 != 0 ? 0xffff : 0
            let c = mem.r16(cpt)
            let d = minterm(a, b, c, lf)
            if !sing || !onedot { mem.w16(dpt, d); if d != 0 { any = true } }
            onedot = true
            bsh = (bsh - 1) & 15
            if sign { apt &+= bmod } else { apt &+= amod }
            if !sign {
                if con1 & 0x10 != 0 {
                    if con1 & 0x8 != 0 { cpt &-= cmod } else { cpt &+= cmod }
                    onedot = false
                } else {
                    if con1 & 0x8 != 0 { if ash == 0 { ash = 15; cpt &-= 2 } else { ash -= 1 } }
                    else { ash += 1; if ash == 16 { ash = 0; cpt &+= 2 } }
                }
            }
            if con1 & 0x10 != 0 {
                if con1 & 0x4 != 0 { if ash == 0 { ash = 15; cpt &-= 2 } else { ash -= 1 } }
                else { ash += 1; if ash == 16 { ash = 0; cpt &+= 2 } }
            } else {
                if con1 & 0x4 != 0 { cpt &-= cmod } else { cpt &+= cmod }
                onedot = false
            }
            sign = Int16(truncatingIfNeeded: apt) < 0
            dpt = cpt
        }
        regs[0x40 >> 1] = (con0 & 0x0fff) | UInt16(ash << 12)
        regs[0x42 >> 1] = (con1 & 0x0fbf) | UInt16(bsh << 12) | (sign ? 0x40 : 0)
        regs[0x52 >> 1] = UInt16(truncatingIfNeeded: apt)
        setPtr(0x48, cpt); setPtr(0x54, dpt)
        bzero = !any
    }

    func doBlit(width w: Int, height h: Int) {
        blitCount &+= 1
        let con0 = regs[0x40 >> 1], con1 = regs[0x42 >> 1]
        blitLog?(self, w, h)
        if con1 & 1 != 0 { blitLine(height: h); raise(0x0040); return }
        let ash = UInt32(con0 >> 12), bsh = UInt32(con1 >> 12)
        let useA = con0 & 0x800 != 0, useB = con0 & 0x400 != 0, useC = con0 & 0x200 != 0, useD = con0 & 0x100 != 0
        let lf = UInt8(con0 & 0xff)
        let desc = con1 & 2 != 0
        let fill = con1 & 0x18 != 0, efe = con1 & 0x10 != 0
        let fci: UInt16 = (con1 >> 2) & 1
        var apt = ptr(0x50), bpt = ptr(0x4c), cpt = ptr(0x48), dpt = ptr(0x54)
        func smod(_ r: Int) -> UInt32 {
            let m = Int32(Int16(bitPattern: regs[r >> 1]))
            return UInt32(bitPattern: desc ? -m : m)
        }
        let amod = smod(0x64), bmod = smod(0x62), cmod = smod(0x60), dmod = smod(0x66)
        let fwm = regs[0x44 >> 1], lwm = regs[0x46 >> 1]
        var adat = regs[0x74 >> 1], bdat = regs[0x72 >> 1], cdat = regs[0x70 >> 1]
        var preva: UInt32 = 0, prevb: UInt32 = 0
        var any = false
        let step: UInt32 = desc ? UInt32(bitPattern: -2) : 2
        for _ in 0..<h {
            var carry = fci
            for x in 0..<w {
                if useA { adat = mem.r16(apt); apt &+= step }
                if useB { bdat = mem.r16(bpt); bpt &+= step }
                if useC { cdat = mem.r16(cpt); cpt &+= step }
                var am = adat
                if x == 0 { am &= fwm }
                if x == w - 1 { am &= lwm }
                let ash16: UInt16, bsh16: UInt16
                if !desc {
                    ash16 = UInt16(truncatingIfNeeded: ((preva << 16) | UInt32(am)) >> ash)
                    bsh16 = UInt16(truncatingIfNeeded: ((prevb << 16) | UInt32(bdat)) >> bsh)
                } else {
                    ash16 = UInt16(truncatingIfNeeded: (((UInt64(am) << 16) | UInt64(preva)) << UInt64(ash)) >> 16)
                    bsh16 = UInt16(truncatingIfNeeded: (((UInt64(bdat) << 16) | UInt64(prevb)) << UInt64(bsh)) >> 16)
                }
                preva = UInt32(am); prevb = UInt32(bdat)
                var d = minterm(ash16, bsh16, cdat, lf)
                if fill {
                    var out: UInt16 = 0
                    for i in 0..<16 {
                        let bit = (d >> UInt16(i)) & 1
                        if efe { carry ^= bit; if carry != 0 { out |= 1 << UInt16(i) } }
                        else { if (carry | bit) != 0 { out |= 1 << UInt16(i) }; carry ^= bit }
                    }
                    d = out
                }
                if d != 0 { any = true }
                if useD { mem.w16(dpt, d); dpt &+= step }
            }
            if useA { apt &+= amod }
            if useB { bpt &+= bmod }
            if useC { cpt &+= cmod }
            if useD { dpt &+= dmod }
        }
        setPtr(0x50, apt); setPtr(0x4c, bpt); setPtr(0x48, cpt); setPtr(0x54, dpt)
        regs[0x74 >> 1] = adat; regs[0x72 >> 1] = bdat; regs[0x70 >> 1] = cdat
        bzero = !any
        raise(0x0040)
    }
}
