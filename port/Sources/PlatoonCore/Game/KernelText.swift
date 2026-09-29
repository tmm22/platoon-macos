// Kernel text system: queued messages with colour fades (jt11), hex printing (jt07-jt10).
// Spec: re/kernel/NOTES.md §(b) "Text system"; listing re/kernel/kernel.s $106d0-$10848.

extension Platoon {
    // MARK: - hex printing (jt07-jt10)

    /// $106d0 k_hex32 (jt07): 8 hex digits of d0.l at the text cursor (BCD values print as decimal).
    func k_hex32_impl(_ d0: UInt32) {
        k_hex16_impl(UInt16(truncatingIfNeeded: d0 >> 16))   // swap d0; bsr k_hex16
        k_hex16_impl(UInt16(truncatingIfNeeded: d0))
    }

    /// $106da k_hex16 (jt08): 4 hex digits of d0.w.
    func k_hex16_impl(_ d0: UInt16) {
        k_hex8_impl(UInt8(truncatingIfNeeded: d0 >> 8))
        k_hex8_impl(UInt8(truncatingIfNeeded: d0))
    }

    /// $106e4 k_hex8 (jt09): 2 hex digits of d0.b.
    func k_hex8_impl(_ d0: UInt8) {
        k_hex4_impl(d0 >> 4)
        k_hex4_impl(d0)
    }

    /// $106ee k_hex4 (jt10): one digit ($111f7 "0123456789ABCDEF"[d0 & $f]) via res_putchar ($404).
    func k_hex4_impl(_ d0: UInt8) {
        cpu(60)
        r_putchar(mem.r8(KA.hexDigits &+ UInt32(d0 & 0x0f)))
    }

    // MARK: - message queue (jt11) and fades

    /// $1070c k_queue_text (jt11): append message d0 (& $ff) to the queue $3c(a6) (max 4 pending, else ignored);
    /// if the queue was empty the message starts at once.
    func k_queue_text_impl(_ d0in: UInt16) {
        let d1 = mem.r16(a6 + KV.textN)
        if d1 == 4 { return }
        let d0 = d0in & 0xff                                          // andi.l #$ff,d0
        mem.w16(a6 + KV.textQueue + UInt32(d1) * 2, d0)
        mem.w16(a6 + KV.textN, mem.r16(a6 + KV.textN) &+ 1)
        cpu(80)
        if d1 != 0 { return }
        k_text_start(d0)
    }

    /// $10732 k_text_start: message d0 of the table ($4a): reset the fade (step 0, period 2, dir +1, countdown 1),
    /// set colours 8/9 for step 0, clear its 8-line text row in both buffers, print the colour header $11229
    /// (slot0=0, slot1=8, slot2=9) and the message.
    func k_text_start(_ d0: UInt16) {
        let a0 = mem.r32(mem.r32(a6 + KV.textTable) &+ UInt32(d0 << 2))   // (a0, d0.w) - d0 < $40 always
        mem.w16(a6 + KV.textStep, 0)
        mem.w16(a6 + KV.textPeriod, 2)
        mem.w16(a6 + KV.textDir, 1)
        mem.w16(a6 + KV.textCount, 1)
        k_text_colour()
        let row = UInt32(mem.r8(a0 &+ 1))
        let off = mem.r32(KA.rowTab &+ row * 4)
        var p0 = off &+ 0x70000, p1 = off &+ 0x78000
        for _ in 0...0x4f {                                            // 8 lines x 40 bytes, 4 planes, both buffers
            mem.w32(p0 &+ 0x2000, 0); mem.w32(p1 &+ 0x2000, 0)
            mem.w32(p0 &+ 0x4000, 0); mem.w32(p1 &+ 0x4000, 0)
            mem.w32(p0 &+ 0x6000, 0); mem.w32(p1 &+ 0x6000, 0)
            mem.w32(p0, 0); mem.w32(p1, 0)
            p0 &+= 4; p1 &+= 4
        }
        cpu(0x50 * 194 + 200)
        r_print(KA.strTextHdr)
        r_print(a0)
    }

    /// $107b4 k_text_tick (once per game frame via jt13; every 2 vblanks in the kernel's own loops):
    /// fade in 7 steps x 2 ticks, hold 25 ticks (only when it is the last queued message, else 1), fade out
    /// 7 x 1 tick, then start the next queued message.
    func k_text_tick() {
        cpu(60)
        if mem.r16(a6 + KV.textN) == 0 { return }
        let cnt = mem.r16(a6 + KV.textCount) &- 1
        mem.w16(a6 + KV.textCount, cnt)
        if cnt != 0 { return }
        mem.w16(a6 + KV.textCount, mem.r16(a6 + KV.textPeriod))
        let step = mem.r16(a6 + KV.textStep) &+ mem.r16(a6 + KV.textDir)
        mem.w16(a6 + KV.textStep, step)
        if step == 7 {
            mem.w16(a6 + KV.textCount, 1)
            if mem.r16(a6 + KV.textN) == 1 { mem.w16(a6 + KV.textCount, 0x19) }
            mem.w16(a6 + KV.textPeriod, 1)
            mem.w16(a6 + KV.textDir, 0xffff)
            k_text_colour()
            return
        }
        if step != 0 { k_text_colour(); return }
        // faded out: shift the queue up one entry (5 words)
        for i in 0...4 { mem.w16(a6 + KV.textQueue + UInt32(2 * i), mem.r16(a6 + KV.textQueue + UInt32(2 * i + 2))) }
        let d0 = mem.r16(a6 + KV.textQueue)
        let n = mem.r16(a6 + KV.textN) &- 1
        mem.w16(a6 + KV.textN, n)
        if n == 0 { k_text_colour(); return }
        k_text_start(d0)
    }

    /// $10824 k_text_colour: c = ($34)[step] (long colour8:colour9) -> into the current HUD palette data at
    /// ($5e)+$10 and into the copper list's COLOR08/COLOR09 values.
    func k_text_colour() {
        let d0 = mem.r32(mem.r32(a6 + KV.textRamp) &+ UInt32(truncatingIfNeeded: Int(Int16(bitPattern: mem.r16(a6 + KV.textStep) << 2))))
        mem.w32(mem.r32(a6 + KV.hudPalPtr) &+ 0x10, d0)
        mem.w16(KA.copCol9, UInt16(truncatingIfNeeded: d0))
        mem.w16(KA.copCol8, UInt16(truncatingIfNeeded: d0 >> 16))
        cpu(90)
    }
}
