// 8520 CIA (timers, TOD with alarm, ICR, serial data register for the keyboard).

public final class CIA {
    public let isB: Bool
    public var pra: UInt8 = 0, prb: UInt8 = 0, ddra: UInt8 = 0, ddrb: UInt8 = 0
    public var ta: UInt16 = 0, tb: UInt16 = 0, taLatch: UInt16 = 0xffff, tbLatch: UInt16 = 0xffff
    public var cra: UInt8 = 0, crb: UInt8 = 0, icr: UInt8 = 0, icrMask: UInt8 = 0, sdr: UInt8 = 0
    public var tod: UInt32 = 0, todLatch: UInt32 = 0, alarm: UInt32 = 0
    var todLatched = false
    var tickAcc = 0.0
    /// Supplies the input bits of port A (CIA-A: fire buttons / disk status). Returns the full byte.
    var portAInput: (() -> UInt8)?
    var onChange: (() -> Void)?

    init(isB: Bool) { self.isB = isB }

    public var interruptPending: Bool { icr & icrMask != 0 }

    public func read(_ r: Int) -> UInt8 {
        switch r & 15 {
        case 0:
            let inp = portAInput?() ?? 0xff
            return (inp & ~ddra) | (pra & ddra)
        case 1: return (prb & ddrb) | (~ddrb)
        case 2: return ddra
        case 3: return ddrb
        case 4: return UInt8(ta & 0xff)
        case 5: return UInt8(ta >> 8)
        case 6: return UInt8(tb & 0xff)
        case 7: return UInt8(tb >> 8)
        case 8: let t = todLatched ? todLatch : tod; todLatched = false; return UInt8(t & 0xff)
        case 9: return UInt8(((todLatched ? todLatch : tod) >> 8) & 0xff)
        case 10: todLatch = tod; todLatched = true; return UInt8((tod >> 16) & 0xff)
        case 12: return sdr
        case 13:
            var v = icr
            if v & icrMask != 0 { v |= 0x80 }
            icr = 0
            onChange?()
            return v
        case 14: return cra
        case 15: return crb
        default: return 0xff
        }
    }

    public func write(_ r: Int, _ v: UInt8) {
        switch r & 15 {
        case 0: pra = v
        case 1: prb = v
        case 2: ddra = v
        case 3: ddrb = v
        case 4: taLatch = (taLatch & 0xff00) | UInt16(v)
        case 5:
            taLatch = (taLatch & 0xff) | UInt16(v) << 8
            if cra & 1 == 0 { ta = taLatch; if cra & 8 != 0 { cra |= 1 } }
        case 6: tbLatch = (tbLatch & 0xff00) | UInt16(v)
        case 7:
            tbLatch = (tbLatch & 0xff) | UInt16(v) << 8
            if crb & 1 == 0 { tb = tbLatch; if crb & 8 != 0 { crb |= 1 } }
        case 8: if crb & 0x80 != 0 { alarm = (alarm & 0xffff00) | UInt32(v) } else { tod = (tod & 0xffff00) | UInt32(v) }
        case 9: if crb & 0x80 != 0 { alarm = (alarm & 0xff00ff) | UInt32(v) << 8 } else { tod = (tod & 0xff00ff) | UInt32(v) << 8 }
        case 10: if crb & 0x80 != 0 { alarm = (alarm & 0x00ffff) | UInt32(v) << 16 } else { tod = (tod & 0x00ffff) | UInt32(v) << 16 }
        case 12: sdr = v
        case 13:
            if v & 0x80 != 0 { icrMask |= v & 0x7f } else { icrMask &= ~(v & 0x7f) }
            onChange?()
        case 14: cra = v & ~0x10; if v & 0x10 != 0 { ta = taLatch }
        case 15: crb = v & ~0x10; if v & 0x10 != 0 { tb = tbLatch }
        default: break
        }
    }

    func todTick() {
        tod = (tod + 1) & 0xffffff
        if tod == alarm { icr |= 4; onChange?() }
    }

    /// Advance timers by `ticks` E-clock cycles.
    func tick(_ ticks: Int) {
        if cra & 1 == 0 && crb & 1 == 0 { return }
        var fired = false
        for _ in 0..<ticks {
            var taUnder = false
            if cra & 1 != 0 {
                if ta == 0 { taUnder = true; icr |= 1; fired = true; ta = taLatch; if cra & 8 != 0 { cra &= ~1 } } else { ta -= 1 }
            }
            if crb & 1 != 0 {
                let inm = (crb >> 5) & 3
                if inm == 0 || (inm == 2 && taUnder) {
                    if tb == 0 { icr |= 2; fired = true; tb = tbLatch; if crb & 8 != 0 { crb &= ~1 } } else { tb -= 1 }
                }
            }
        }
        if fired { onChange?() }
    }
}
