// Kernel core: interrupts (level 3 vblank, level 6 raster split), display/copper, double buffering, waits,
// RNG, fills, palettes and fades, music/fx wrappers. Spec: re/kernel/NOTES.md §(e), §(b).

extension Platoon {
    // MARK: - level 3 vblank ($10eac)

    /// $10eac level3_vblank: restart CIA-B TOD (raster counter), RNG update, TAB pause state machine, BCD timer,
    /// frame flag, music tick, logo colour cycle, F10 music/fx option cycling.
    func level3_vblank() {
        irqDepth += 1; defer { irqDepth -= 1 }
        tickPoint(KA.level3)
        irqCharge(vblankHandlerCycles)
        let b = chip.ciaB
        b.write(15, b.read(15) & ~0x80)                        // CRB bit7 = 0: TOD writes set the clock
        b.write(10, 0); b.write(9, 0); b.write(8, 0)
        b.write(15, b.read(15) | 0x80)                         // later TOD writes set the alarm
        mem.w16(0x74, 0)                                       // clr.w $74 (high word of the level-5 vector)
        if !config.deterministicRNG {
            mem.w32(KA.rng, mem.r32(KA.rng) &+ interruptedD1)  // add.l d1,$12d70
            mem.w32(KA.rng, mem.r32(KA.rng) &+ 1)              // addi.l #1,$12d70
        }
        let pause = mem.r16(KA.pause)
        if pause != 0 {
            k_pause_sm(negative: Int16(bitPattern: pause) < 0)
        } else if r_keytest(0x42) {                            // TAB pressed
            mem.w16(KA.pause, 1)
            k_pause_sm(negative: false)
        } else {
            vbl_timer()
        }
        vbl_common()
    }

    /// $10f0e vbl_timer: 50 vblanks per tick, then seconds/minutes BCD countdown (sbcd from a zero byte).
    /// X-flag quirk: X = 1 only when the vblank countdown just went 0 -> -1; when it was already negative the
    /// X flag left by the preceding res_keytest (lsr.b #3 of $42 -> 0) is used, so that tick subtracts 0.
    func vbl_timer() {
        var x = false
        let t = Int16(bitPattern: mem.r16(a6 + KV.timerVbl))
        if t >= 0 {
            let n = t &- 1
            mem.w16(a6 + KV.timerVbl, UInt16(bitPattern: n))
            if n >= 0 { return }
            x = true
        }
        if mem.r16(a6 + KV.timerOn) == 0 { return }
        mem.w16(a6 + KV.timerVbl, 0x31)
        if enhancements.cheats.freezeTimer { return }                  // ENHANCEMENT CHEAT-TIMER (default off)
        // ENHANCEMENT S9h (kernel.timerStopsAtZero, default off): no wrap from 00:00 to 59:59
        if enhancements.kernel.timerStopsAtZero && mem.r16(a6 + KV.timerMin) == 0 { return }
        let (s, c) = Platoon.sbcd(mem.r8(a6 + KV.timerSec), mem.r8(KA.bcdZero + 3), x: x)
        mem.w8(a6 + KV.timerSec, s)
        if !c { return }
        mem.w8(a6 + KV.timerSec, 0x59)
        let (mn, c2) = Platoon.sbcd(mem.r8(a6 + KV.timerMin), mem.r8(KA.bcdZero + 2), x: true)
        mem.w8(a6 + KV.timerMin, mn)
        if !c2 { return }
        mem.w8(a6 + KV.timerMin, 0x59)
    }

    /// $10f4a vbl_common (+ $10f92 / $10f98): frame flag, music tick, logo cycle, F10, acknowledge.
    func vbl_common() {
        mem.w8(a6 + KV.frameFlag, 0xff)
        md_play()
        k_logo_cycle()
        if r_keytest(0x59) {                                    // F10
            if mem.r16(KA.f10Debounce) == 0 {
                mem.w8(KA.f10Debounce, 0xff)
                mem.w8(a6 + KV.soundFlags, (mem.r8(a6 + KV.soundFlags) &+ 1) & 3)
                inF10 = true                                        // (host flag: F2 does not report this fx)
                k_music_impl(mem.r16(KA.curTune))
                k_fx_impl(0)
                inF10 = false
                if config.probe != nil { probeSoundFlags() }
            }
        } else {
            mem.w16(KA.f10Debounce, 0)
        }
        chip.write(0x09c, 0x0020)
    }

    /// $10dc2 k_pause_sm (word $10eaa): $0001 TAB still held -> on release $ffff (paused) -> on press $ff00 ->
    /// on release $0000 (running). Entered with the N flag of the pause word.
    func k_pause_sm(negative: Bool) {
        if !negative {
            if r_keytest(0x42) { return }
            mem.w16(KA.pause, 0xffff)
        } else if mem.r8(KA.pause + 1) != 0 {
            if !r_keytest(0x42) { return }
            mem.w16(KA.pause, 0xff00)
        } else {
            if r_keytest(0x42) { return }
            mem.w16(KA.pause, 0)
        }
    }

    // MARK: - level 6 raster split ($10faa)

    /// $10faa level6_raster (CIA-B TOD alarm at the split line): latch the scheduled copper list, pause colour
    /// cycling of COLOR00, copy the game-window scroll $72(a6) into the copper list for the next frame.
    func level6_raster() {
        irqDepth += 1; defer { irqDepth -= 1 }
        irqCharge(Platoon.level6Cycles)
        _ = chip.ciaB.read(13)
        if mem.r8(KA.swapPending) != 0 {
            chip.writeL(0x080, mem.r32(KA.nextCop))
            mem.w8(KA.swapPending, 0)
        }
        if mem.r16(KA.pause) != 0 && !enhancements.kernel.steadyPauseColour {   // ENHANCEMENT S17 (default: strobe)
            chip.write(0x180, mem.r16(KA.pauseColour))
            mem.w16(KA.pauseColour, mem.r16(KA.pauseColour) &+ 1)
        }
        mem.w16(KA.copTopBplcon1, mem.r16(a6 + KV.scroll))
        chip.write(0x09c, 0x2000)
    }

    /// Installs the kernel interrupt vectors ($6c level 3, $78 level 6) as k_init does.
    func k_install_vectors() {
        mem.w32(0x78, KA.level6)
        chip.interruptHandlers[6] = { [unowned self] in self.level6_raster() }
        mem.w32(0x6c, KA.level3)
        chip.interruptHandlers[3] = { [unowned self] in self.level3_vblank() }
    }

    // MARK: - waits (jt17, jt18, jt23)

    /// $10ad6 k_wait_vbl (jt18): clr.b $56(a6); wait until the vblank handler sets it.
    func k_wait_vbl_impl() {
        tickPoint(0x10ad6)
        settleCPU()
        mem.w8(a6 + KV.frameFlag, 0)
        while mem.r8(a6 + KV.frameFlag) == 0 { m.waitVBlank() }
        irqCatchUp()
        if textScreenPending { probeVbl() }                              // F2 (host state only)
    }

    /// $10acc k_wait_frames (jt17): d0+1 vblanks (dbra).
    func k_wait_frames_impl(_ d0in: UInt16) {
        var d0 = d0in
        repeat { k_wait_vbl_impl(); d0 &-= 1 } while d0 != 0xffff
    }

    /// $10b14 k_wait_swap (jt23): spin until the level-6 handler latched the scheduled copper list. The handler
    /// fires when CIA-B TOD (restarted at each vblank, counting lines) reaches the alarm $58(a6)+1.
    func k_wait_swap_impl() {
        tickPoint(0x10b14)
        settleCPU()
        if mem.r8(KA.swapPending) == 0 { return }
        while mem.r8(KA.swapPending) != 0 {
            m.waitLine(Int(mem.r8(a6 + KV.splitPlus3c) &+ 1))
        }
        irqCatchUp()
    }

    // MARK: - double buffering / display (jt19, jt24, jt32)

    /// $10ae2 k_swap (jt19): flip the draw buffer and schedule the copper list of the buffer just drawn.
    func k_swap_impl() {
        tickPoint(0x10ae2)
        settleCPU()                                                      // the level-6 handler latches the request
        mem.w32(a6 + KV.drawBuf, mem.r32(a6 + KV.drawBuf) ^ 0x8000)
        if mem.r32(KA.nextCop) == KA.copperA { mem.w32(KA.nextCop, KA.copperB) } else { mem.w32(KA.nextCop, KA.copperA) }
        mem.w8(KA.swapPending, 0xff)
    }

    /// $10b1e k_display_init (jt24): 4-plane display with copper list B, window/HUD copper values reset.
    func k_display_init_impl() {
        settleCPU()
        mem.w32(a6 + KV.drawBuf, 0x70000)
        mem.w32(KA.nextCop, 0x78000)
        mem.w8(KA.swapPending, 0)
        for s in 0..<8 { chip.write(0x142 + 8 * s, 0) }
        chip.write(0x100, 0x4200)
        chip.write(0x102, 0)
        mem.w16(KA.copTopDiwstrt, 0x3c71)
        mem.w16(KA.copHudBplcon1, 0)
        mem.w16(KA.copTopBplcon1, 0)
        mem.w16(a6 + KV.scroll, 0)
        chip.write(0x104, 0); chip.write(0x108, 0); chip.write(0x10a, 0)
        chip.write(0x092, 0x30); chip.write(0x094, 0xc8)
        chip.write(0x090, 0x04b1)
        chip.write(0x02e, 0)                                     // COPCON
        chip.writeL(0x080, KA.copperB)
        chip.writeL(0x084, KA.copperCommon)
        chip.write(0x088, 0)                                     // move.w $88(a0),d0: COPJMP1 strobe
        chip.write(0x096, 0x83c0)
        chip.write(0x044, 0xffff); chip.write(0x046, 0xffff)
        cpu(400)
    }

    /// $fd4e k_set_split (jt32): HUD bitplane pointers = $78000 + (d0+1)*40, split WAIT line d0+$3d, CIA-B TOD
    /// alarm = d0+$3c+1 (raster interrupt), TOD restarted at 0.
    func k_set_split_impl(_ d0: UInt8) {
        settleCPU()
        var p = (UInt32(d0) &+ 1 & 0xff) * 0x28 &+ 0x78000
        var a0 = KA.copHudBplpt
        for _ in 0..<4 {                                         // $fdd8 k_put_bplpt
            mem.w16(a0, UInt16(p >> 16)); a0 &+= 4
            mem.w16(a0, UInt16(truncatingIfNeeded: p)); a0 &+= 4
            p &+= 0x2000
        }
        mem.w8(a6 + KV.splitPlus3c, d0 &+ 0x3c)
        mem.w8(KA.copSplitWait, d0 &+ 0x3d)
        let b = chip.ciaB
        b.write(15, b.read(15) | 0x80)
        b.write(10, 0); b.write(9, 0)
        b.write(8, mem.r8(a6 + KV.splitPlus3c) &+ 1)
        b.write(15, b.read(15) & ~0x80)
        b.write(10, 0); b.write(9, 0); b.write(8, 0)
        cpu(500)
    }

    // MARK: - RNG, fills (jt20, jt21, jt22)

    /// $10bcc k_random (jt20): 8 steps of a Galois LFSR (taps $0076b553, rol) on $12d70; returns the top byte.
    func k_random_impl() -> UInt32 {
        tickPoint(0x10bcc)
        var d0 = mem.r32(KA.rng)
        for _ in 0..<8 {
            if Int32(bitPattern: d0) < 0 { d0 ^= 0x0076b553 }
            d0 = (d0 << 1) | (d0 >> 31)
        }
        mem.w32(KA.rng, d0)
        return UInt32(mem.r8(KA.rng))
    }

    /// $11062 k_fill_longs (jt21): (a0)+ = d0; d0 += d2; d1+1 times.
    func k_fill_longs_impl(dest a0in: UInt32, start d0in: UInt32, countMinus1 d1: UInt16, step d2: UInt32) -> (a0: UInt32, d0: UInt32) {
        var a0 = a0in, d0 = d0in, n = d1
        repeat { mem.w32(a0, d0); a0 &+= 4; d0 &+= d2; n &-= 1 } while n != 0xffff
        cpu((Int(d1) + 1) * 30)
        return (a0, d0)
    }

    /// $1106c k_fill_words (jt22, unused by the game): word version of jt21.
    @discardableResult
    func k_fill_words(dest a0in: UInt32, start d0in: UInt16, countMinus1 d1: UInt16, step d2: UInt16) -> (a0: UInt32, d0: UInt16) {
        var a0 = a0in, d0 = d0in, n = d1
        repeat { mem.w16(a0, d0); a0 &+= 2; d0 &+= d2; n &-= 1 } while n != 0xffff
        return (a0, d0)
    }

    // MARK: - palettes (jt30, jt31) and fades (jt28, $fdee, $fe38, $fea8)

    /// $11000 k_set_hud_pal (jt31): $5e(a6) := a0; 16 colours into the HUD part of the copper list.
    func k_set_hud_pal_impl(_ a0: UInt32) {
        settleCPU()
        mem.w32(a6 + KV.hudPalPtr, a0)
        k_pal_to_copper(a0, KA.copHudPalette)
    }

    /// $11010 k_set_top_pal (jt30): $5a(a6) := a0; 16 colours into the game-window part of the copper list.
    func k_set_top_pal_impl(_ a0: UInt32) {
        settleCPU()
        mem.w32(a6 + KV.topPalPtr, a0)
        k_pal_to_copper(a0, KA.copTopPalette)
    }

    /// $1101e k_pal_to_copper: 16 words into every second word of the copper MOVEs.
    func k_pal_to_copper(_ a0: UInt32, _ a1: UInt32) {
        for i in 0..<16 { mem.w16(a1 + UInt32(4 * i), mem.r16(a0 + UInt32(2 * i))) }
        cpu(16 * 20 + 60)
    }

    func k_set_pal(_ setter: PaletteSetter, _ a0: UInt32) {
        switch setter {
        case .top: k_set_top_pal_impl(a0)
        case .hud: k_set_hud_pal_impl(a0)
        }
    }

    /// $fade k_fade_in (jt28): from black up to `target` in 16 steps of 2 vblanks (nibble += 1 while below target)
    /// using the buffer $12cf0; (a3) points at the buffer during the fade and at `target` at the end.
    func k_fade_in_impl(target a0: UInt32, palVar a3: UInt32, setter a4: PaletteSetter) {
        for i in 0..<8 { mem.w32(KA.fadeBufHud + UInt32(4 * i), mem.r32(KA.palBlack + UInt32(4 * i))) }
        let a1 = a0
        mem.w32(a3, KA.fadeBufHud)
        for _ in 0..<16 {
            k_wait_vbl_impl(); k_wait_vbl_impl()
            for i in 0..<16 {
                let t = mem.r16(a1 + UInt32(2 * i))
                let c = mem.r16(KA.fadeBufHud + UInt32(2 * i))
                var d1 = c & 0x00f, d2 = c & 0x0f0, d3 = c & 0xf00
                if d1 != t & 0x00f { d1 &+= 0x001 }
                if d2 != t & 0x0f0 { d2 &+= 0x010 }
                if d3 != t & 0xf00 { d3 &+= 0x100 }
                mem.w16(KA.fadeBufHud + UInt32(2 * i), d1 | d2 | d3)
            }
            cpu(16 * 110)
            k_set_pal(a4, KA.fadeBufHud)
        }
        mem.w32(a3, a1)
        k_set_pal(a4, a1)
    }

    /// $fdee k_fade_out_hud: copy ($5e) to $12cf0 and fade it to black (16 x 2 vblanks).
    func k_fade_out_hud() {
        let src = mem.r32(a6 + KV.hudPalPtr)
        for i in 0..<8 { mem.w32(KA.fadeBufHud + UInt32(4 * i), mem.r32(src + UInt32(4 * i))) }
        mem.w32(a6 + KV.hudPalPtr, KA.fadeBufHud)
        for _ in 0..<16 {
            k_wait_vbl_impl(); k_wait_vbl_impl()
            k_pal_dec_step(KA.fadeBufHud, countMinus1: 0x0f)
            k_set_hud_pal_impl(KA.fadeBufHud)
        }
    }

    /// $fe38 k_fade_out_both: copy ($5a) -> $12cd0 and ($5e) -> $12cf0, fade all 32 to black (16 x 2 vblanks).
    func k_fade_out_both() {
        let top = mem.r32(a6 + KV.topPalPtr)
        for i in 0..<8 { mem.w32(KA.fadeBufTop + UInt32(4 * i), mem.r32(top + UInt32(4 * i))) }
        let hud = mem.r32(a6 + KV.hudPalPtr)
        for i in 0..<8 { mem.w32(KA.fadeBufHud + UInt32(4 * i), mem.r32(hud + UInt32(4 * i))) }
        mem.w32(a6 + KV.topPalPtr, KA.fadeBufTop)
        mem.w32(a6 + KV.hudPalPtr, KA.fadeBufHud)
        for _ in 0..<16 {
            k_wait_vbl_impl(); k_wait_vbl_impl()
            k_pal_dec_step(KA.fadeBufTop, countMinus1: 0x1f)       // both buffers (they are contiguous)
            k_set_top_pal_impl(KA.fadeBufTop)
            k_set_hud_pal_impl(KA.fadeBufHud)
        }
    }

    /// $fea8 k_pal_dec_step: every nonzero nibble of d0+1 colours at a0 -1.
    func k_pal_dec_step(_ a0: UInt32, countMinus1 d0: Int) {
        for i in 0...d0 {
            let a = a0 + UInt32(2 * i)
            let c = mem.r16(a)
            var d2 = c & 0x00f, d3 = c & 0x0f0, d4 = c & 0xf00
            if d2 != 0 { d2 &-= 0x001 }
            if d3 != 0 { d3 &-= 0x010 }
            if d4 != 0 { d4 &-= 0x100 }
            mem.w16(a, d2 | d3 | d4)
        }
        cpu((d0 + 1) * 90)
    }

    // MARK: - music / fx (jt26, jt27)

    /// $10c00 k_music (jt26): current tune := d0; start it if music is on ($66 bit0) else stop; volume := $40.
    func k_music_impl(_ d0: UInt16) {
        tickPoint(0x10c00)
        cpu(2300)                                                        // movem + driver init_song (emu: ~5 lines)
        mem.w16(KA.curTune, d0)
        if mem.r8(a6 + KV.soundFlags) & 1 != 0 { md_initSong(UInt8(truncatingIfNeeded: d0)); musicPlaying = true } else { md_stop(); musicPlaying = false }
        mem.w16(KA.musVolume, 0x40)
    }

    /// $10c3a k_music_stop.
    func k_music_stop() {
        md_stop(); musicPlaying = false
        mem.w16(KA.musVolume, 0)
    }

    /// $fed6 k_music_fade_step: master volume -1 if not 0.
    func k_music_fade_step() {
        let v = mem.r16(KA.musVolume)
        if v == 0 { return }
        mem.w16(KA.musVolume, v &- 1)
    }

    /// $10c50 k_fx (jt27): if fx are on ($66 bit1): effects < $80 on channel 0 (2 if the music uses channel 0),
    /// $80/$81 on channels 1+3, >= $82 on channels 0+2 (bits 8-9 of the driver's d0 = channel).
    func k_fx_impl(_ d0in: UInt16) {
        tickPoint(0x10c50)
        if config.probe != nil { probeFx(d0in) }                         // F2 observer (read-only)
        cpu(40)                                                          // btst/beq (+ andi/btst/tst below)
        if mem.r8(a6 + KV.soundFlags) & 2 == 0 { return }
        var d0 = d0in & 0xff
        if d0 & 0x80 == 0 {
            if mem.r8(KA.musCh0Busy) != 0 { d0 |= 0x200 }
            k_fx_call(d0)
        } else if d0 >= 0x82 {
            k_fx_call(d0)
            k_fx_call(d0 | 0x200)
        } else {
            k_fx_call(d0 | 0x100)
            k_fx_call(d0 | 0x300)
        }
    }

    /// $10c92 k_fx_call: movem.l d0-d7/a0-a6,-(a7) ; jsr $2838 ; movem.l (a7)+,d0-d7/a0-a6 ; rts.
    func k_fx_call(_ d0: UInt16) {
        cpu(150)                                                         // movem (15 regs) + jsr
        md_sfx(d0)
        cpu(150)                                                         // movem back + rts
        tickPoint(0x10ca0)
    }
}
