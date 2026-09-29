// Kernel init (jt00) and the title loop: credits, hiscore page, attract picture, logo, cheats.
// Spec: re/kernel/NOTES.md §(b) "k_init", "k_credits", "k_hiscores", "k_attract", §(g) cheats;
// listing re/kernel/kernel.s $f890-$fcc6, $102d2-$104c4, $10ca2-$10ea0.

extension Platoon {
    /// Registers the kernel's code addresses that the original keeps as data (go address $10d6 = $f800,
    /// section loader table $11166).
    func k_registerDispatch() {
        register(KA.initEntry) { [unowned self] in self.k_init_impl() }
        register(0x11102) { [unowned self] in self.k_load_sec0() }
        register(0x1112a) { [unowned self] in self.k_load_sec1() }
        register(0x11148) { [unowned self] in self.k_load_sec2() }
    }

    // MARK: - k_init (jt00)

    /// $f890 k_init (jt00): cold/warm restart. Display reset, interrupt vectors, font, row table, logo, title
    /// tune; on the first boot also sound flags, the hiscore track (77) load; then the title loop forever.
    func k_init_impl() -> Never {
        tickPoint(0xf890)
        irqDepth = 0; cpuBusy = false                                    // (entered by jumps out of handlers: DEL)
        chip.ipl = 7                                                     // ori.w #$700,sr ; sp = $400
        k_display_reset()
        k_install_vectors()                                              // ($78) = $10faa ; ($6c) = $10eac
        chip.ciaB.write(13, 0x84)                                        // CIA-B ICR: enable ALRM
        chip.write(0x09a, 0xa020)
        chip.write(0x09c, 0x2020)
        chip.ipl = 0; chip.checkInterrupts()                             // move.w #$2000,sr
        mem.w32(RA.fontPtr, KA.font)
        cpu(120)
        k_music_stop()
        k_fill_longs_impl(dest: KA.rowTab, start: 0, countMinus1: 0x18, step: 0x140)
        k_set_hud_pal_impl(KA.palBlack)
        tickPoint(0xf904)
        k_clear_both_lower()
        tickPoint(0xf908)
        k_show_logo()
        tickPoint(0xf90c)
        k_music_impl(0)
        tickPoint(0xf912)
        if mem.r16(KA.firstBootFlag) == 0 {
            mem.w8(KA.firstBootFlag, 0xff)
            mem.w8(a6 + KV.soundFlags, 3)
            mem.w8(KA.cacheSndIcons, 0xff)
            mem.w8(a6 + KV.section, 0xff)
            k_set_hud_pal_impl(KA.palCredits)
            k_music_impl(0)
            _ = k_load_retry(track: 0x4d, count: 1, dest: KA.hiscoreTrack, name: KA.strLoadingHs)
            loadHiscores()                                               // port: persisted table (if any)
        }
        k_title_start()
    }

    /// $f95a k_title_start: logo colour cycle reset, then credits -> hiscores -> attract forever.
    /// Port hook (GameConfig.startSection): the first time through, act as if fire had been pressed on the title.
    func k_title_start() -> Never {
        tickPoint(0xf95a)
        k_logo_cycle_reset()
        if let n = config.startSection, !startSectionDone {
            startSectionDone = true
            k_start_new_game(section: n)
        }
        while true {
            tickPoint(0xf95e)
            k_credits()
            k_hiscores()
            k_attract()
        }
    }

    /// Port: GameConfig.startSection entry = the tail of k_title_poll with $6e(a6) = N, optionally with a saved
    /// a6 block (GameConfig.carry: score, morale, men, flags) instead of the new-game values.
    func k_start_new_game(section n: Int) -> Never {
        if let carry = config.carry {
            for (i, b) in carry.prefix(0x76).enumerated() { mem.w8(a6 + UInt32(i), b) }
        } else {
            mem.w16(a6 + KV.morale, 0x9000)
            mem.w32(a6 + KV.score, 0)
        }
        mem.w16(a6 + KV.section, UInt16(truncatingIfNeeded: n))
        k_next_section_impl()
    }

    // MARK: - title pages

    /// $f96c k_credits: credits page (with MUZAK/FX ON/OFF and the cheat lines) printed into both buffers.
    func k_credits() {
        tickPoint(0xf96c)
        k_set_hud_pal_impl(KA.palBlack)
        k_clear_both_lower()
        k_onoff_text()
        r_print(KA.strCredits)
        k_title_show()
    }

    /// $f98a k_title_show (shared by credits and hiscores): clear the displayed lower area, credits palette,
    /// scroll the page in, hold 100 frames, scroll out.
    func k_title_show() {
        tickPoint(0xf98a)
        k_clear_disp_lower()
        k_set_hud_pal_impl(KA.palCredits)
        k_scroll_in()
        for _ in 0...0x63 {
            k_title_poll()
            k_wait_vbl_impl()
        }
        k_scroll_out()
    }

    /// $f9b0 k_hiscores: "TEN BEST SCORES:" page from the hiscore track image.
    func k_hiscores() {
        tickPoint(0xf9b0)
        k_set_hud_pal_impl(KA.palBlack)
        k_clear_both_lower()
        r_print(KA.hiscoreTrack)
        k_print_hs_entries()
        k_title_show()
    }

    /// $f9ca-$f9f8 (also $100cc, $102a0): the 10 entries: name string ($116e5 + offset[k]) then the score.
    func k_print_hs_entries() {
        var a3 = KA.hsScores, a2 = KA.hsOffsets
        for _ in 0...9 {
            let a0 = mem.r32(a2) &+ KA.hsEntries; a2 &+= 4
            r_print(a0)
            k_hex32_impl(mem.r32(a3)); a3 &+= 4
        }
    }

    /// $f9fc k_attract: "THE FIRST CASUALTY OF WAR ..." message, then the soldier picture (RLE -> $68000,
    /// blitted to x=80 line 48), sample $80, fade in, 201 frames, fade out.
    func k_attract() {
        tickPoint(0xf9fc)
        mem.w32(a6 + KV.textRamp, KA.rampCyan)
        k_set_hud_pal_impl(KA.palText)
        k_queue_text_impl(0)
        k_wait_text_title()
        k_set_hud_pal_impl(KA.palBlack)
        k_clear_both_lower()
        k_rle_decode(src: KA.rleAttract, dest: 0x68000)
        k_blit_copy4(src: 0x68000, dest: 0x7878a, dmod: 0x14, size: 0x25ca)
        k_fx_impl(0x80)
        k_fade_in_impl(target: KA.palAttract, palVar: a6 + KV.hudPalPtr, setter: .hud)
        for _ in 0...0xc8 {
            k_wait_vbl_impl()
            k_title_poll()
        }
        k_fade_out_hud()
    }

    /// $fb72 k_wait_text_title: {poll; vbl; vbl; text tick} until the message queue is empty.
    func k_wait_text_title() {
        repeat {
            k_title_poll()
            k_wait_vbl_impl(); k_wait_vbl_impl()
            k_text_tick()
        } while mem.r16(a6 + KV.textN) != 0
    }

    // MARK: - screen helpers

    /// $fa82 k_blit_copy4: 4-plane A->D blitter copy (a0 src, a1 dst, D modulo d0, BLTSIZE d1; planes $2000).
    func k_blit_copy4(src a0in: UInt32, dest a1in: UInt32, dmod d0: UInt16, size d1: UInt16) {
        var a0 = a0in, a1 = a1in
        for p in 0..<4 {
            if p > 0 { a0 &+= 0x2000; a1 &+= 0x2000 }
            k_blit_copy1(src: a0, dest: a1, dmod: d0, size: d1)
        }
    }

    /// $faa6 k_blit_copy1: BLTAPT, BLTDPT, BLTAMOD=0, BLTDMOD, BLTCON0=$09f0, BLTCON1=0, BLTSIZE (+ busy wait).
    func k_blit_copy1(src a0: UInt32, dest a1: UInt32, dmod d0: UInt16, size d1: UInt16) {
        settleCPU()
        chip.writeL(0x050, a0)
        chip.writeL(0x054, a1)
        chip.write(0x064, 0)
        chip.write(0x066, d0)
        chip.write(0x040, 0x09f0)
        chip.write(0x042, 0)
        chip.write(0x058, d1)
        cpu(130)
    }

    /// $fb8a k_clear_disp_lower: clear lines 48..199 of the displayed buffer ($62 ^ $8000), 4 planes.
    func k_clear_disp_lower() {
        var a0 = (mem.r32(a6 + KV.drawBuf) ^ 0x8000) &+ 0x780
        for _ in 0...0x5ef {
            mem.w32(a0 &+ 0x2000, 0); mem.w32(a0 &+ 0x4000, 0); mem.w32(a0 &+ 0x6000, 0); mem.w32(a0, 0)
            a0 &+= 4
        }
        cpu(0x5f0 * 100 + 500)                                         // emu: 336 lines
    }

    /// $fbb2 k_clear_both_lower: clear lines 48..199 (+ $28 longs) of both buffers, 4 planes.
    func k_clear_both_lower() {
        var a1 = mem.r32(a6 + KV.drawBuf) &+ 0x780
        var a0 = a1 ^ 0x8000
        for _ in 0...0x5f9 {
            for o: UInt32 in [0x2000, 0x4000, 0x6000] { mem.w32(a0 &+ o, 0); mem.w32(a1 &+ o, 0) }
            mem.w32(a0, 0); mem.w32(a1, 0)
            a0 &+= 4; a1 &+= 4
        }
        cpu(0x5fa * 192)                                               // emu: 647 lines
    }

    /// $104aa k_clear_screens (jt16): clear $70000-$7ffff (both buffers).
    func k_clear_screens_impl() {
        mem.fill(0x70000, count: 0x10000)
        cpu(398_600)                                                   // emu: 878 lines
    }

    /// $fbec k_scroll_in: the drawn page (draw buffer from line 56) rises from the bottom of the displayed
    /// buffer, one line per frame (144 frames).
    func k_scroll_in() {
        tickPoint(0xfbec)
        let d0buf = mem.r32(a6 + KV.drawBuf)
        let a0 = d0buf &+ 0x8c0
        var a1 = (d0buf ^ 0x8000) &+ 0x1f18
        var d0: UInt16 = 1
        for _ in 0...0x8f {
            k_title_poll()
            k_wait_vbl_impl()
            k_blit_copy4(src: a0, dest: a1, dmod: 0, size: ((d0 & 0xff) << 6) | 0x14)
            d0 &+= 1
            a1 &-= 0x28
        }
    }

    /// $fc3c k_scroll_out: the displayed page scrolls up one line per frame and vanishes under line 56.
    func k_scroll_out() {
        let b = mem.r32(a6 + KV.drawBuf) ^ 0x8000
        let a0 = b &+ 0x8e8, a1 = b &+ 0x8c0
        var d0: UInt16 = 0x8f
        while true {
            k_title_poll()
            k_wait_vbl_impl()
            k_blit_copy4(src: a0, dest: a1, dmod: 0, size: ((d0 &+ 1) << 6) | 0x14)
            d0 &-= 1
            if d0 == 0xffff { break }
        }
    }

    /// $102d2 k_rle_decode: kernel RLE (word N = bytes per plane, then per plane: escape byte, literals /
    /// escape,value,count(0 = 256)) into 4 planes $2000 apart from a2. The original patches N's address into
    /// the operand of its `move.w $xxxxxxxx,d3` ($102e4) - the patched long is kept in RAM.
    func k_rle_decode(src a1in: UInt32, dest a2in: UInt32) {
        var a1 = a1in, a2 = a2in
        mem.w32(KA.rleOperand, a1)
        a1 &+= 2
        var cycles = 40
        for _ in 0...3 {
            var a0 = a2
            var d3 = mem.r16(mem.r32(KA.rleOperand))
            let d2 = mem.r8(a1); a1 &+= 1
            repeat {
                let d0 = mem.r8(a1); a1 &+= 1
                if d0 != d2 {
                    mem.w8(a0, d0); a0 &+= 1
                    d3 &-= 1
                    cycles += 43
                } else {
                    let v = mem.r8(a1); a1 &+= 1
                    let n = mem.r8(a1) &- 1; a1 &+= 1
                    for _ in 0...Int(n) { mem.w8(a0, v); a0 &+= 1; d3 &-= 1 }
                    cycles += 60 + 22 * (Int(n) + 1)
                }
            } while d3 != 0
            a2 &+= 0x2000
            cycles += 40
        }
        cpu(cycles)
    }

    /// $10416 k_show_logo: decode the PLATOON logo (320x48) to $70000, blit it to $78000, reset the logo
    /// colour cycle and fade the top palette in.
    func k_show_logo() {
        tickPoint(0x10416)
        k_rle_decode(src: KA.rleLogo, dest: 0x70000)
        tickPoint(0x10426)
        k_blit_copy4(src: 0x70000, dest: 0x78000, dmod: 0, size: 0x0c14)
        k_logo_cycle_reset()
        k_fade_in_impl(target: KA.palLogo, palVar: a6 + KV.topPalPtr, setter: .top)
    }

    /// $10454 k_display_reset: title split ($2f), HUD scroll 0, display init, black palettes, kernel text table,
    /// empty message queue, cheat sequence reset; falls into k_logo_cycle_reset.
    func k_display_reset() {
        k_set_split_impl(0x2f)
        mem.w16(KA.copHudBplcon1, 0)
        k_display_init_impl()
        k_set_top_pal_impl(KA.palBlack)
        k_set_hud_pal_impl(KA.palBlack)
        mem.w32(a6 + KV.textTable, KA.kernelTexts)
        mem.w16(a6 + KV.textN, 0)
        k_cheat_reset()
        k_logo_cycle_reset()
    }

    /// $10484 k_logo_cycle_reset: 900 frames still, state 2 (fading to white next); logo colours 0/1 black,
    /// colour 6 white.
    func k_logo_cycle_reset() {
        settleCPU()                                                      // the counter is shared with the vblank handler
        mem.w16(KA.logoCnt, 0x384)
        mem.w8(KA.logoState, 2)
        mem.w16(KA.palLogo, 0)
        mem.w16(KA.palLogo + 2, 0)
        mem.w16(KA.palLogo + 0x0c, 0xfff)
    }

    /// $10cfe k_logo_colour_cycle (every vblank): state bit0 = hold, bit1 = direction. 15 steps of 4 frames
    /// between black-on-white and white-on-black letters, holds of 200+2 frames; applied only while the top
    /// palette pointer is the logo palette.
    func k_logo_cycle() {
        let c0 = KA.palLogo, c1 = KA.palLogo + 2, c6 = KA.palLogo + 0x0c
        if mem.r8(KA.logoState) & 1 != 0 {
            mem.w16(KA.logoCnt, mem.r16(KA.logoCnt) &- 1)
            if mem.r16(KA.logoCnt) != 0 { return }
            mem.w16(KA.logoCnt, 2)
            mem.w8(KA.logoState, (mem.r8(KA.logoState) &+ 1) & 3)
        } else {
            mem.w16(KA.logoCnt, mem.r16(KA.logoCnt) &- 1)
            if mem.r16(KA.logoCnt) != 0 { return }
            mem.w16(KA.logoCnt, 4)
            if mem.r8(KA.logoState) & 2 != 0 {
                mem.w16(c0, mem.r16(c0) &+ 0x111); mem.w16(c1, mem.r16(c1) &+ 0x111); mem.w16(c6, mem.r16(c6) &- 0x111)
                if mem.r16(c6) == 0 {
                    mem.w16(KA.logoCnt, 0xc8)
                    mem.w8(KA.logoState, (mem.r8(KA.logoState) &+ 1) & 3)
                }
            } else {
                mem.w16(c0, mem.r16(c0) &- 0x111); mem.w16(c1, mem.r16(c1) &- 0x111); mem.w16(c6, mem.r16(c6) &+ 0x111)
                if mem.r16(c6) == 0xfff {
                    mem.w16(KA.logoCnt, 0xc8)
                    mem.w8(KA.logoState, (mem.r8(KA.logoState) &+ 1) & 3)
                }
            }
        }
        if mem.r32(a6 + KV.topPalPtr) == KA.palLogo { k_set_top_pal_impl(KA.palLogo) }
    }

    /// $10ca2 k_onoff_text: when $66(a6) changed, patch "ON "/"OFF" after "MUZAK: " ($115a6, bit0) and
    /// "FX: " ($115b0, bit1) in the credits string.
    func k_onoff_text() {
        let f = mem.r8(a6 + KV.soundFlags)
        if mem.r8(KA.cacheOnOff) == f { return }
        mem.w8(KA.cacheOnOff, f)
        func put(_ a0: UInt32, _ on: Bool) {
            mem.w8(a0, 0x4f)
            mem.w8(a0 + 1, on ? 0x4e : 0x46)
            mem.w8(a0 + 2, on ? 0x20 : 0x46)
        }
        put(KA.strMuzakOnOff, f & 1 != 0)
        put(KA.strFxOnOff, f & 2 != 0)
    }

    // MARK: - input on the title

    /// $fc9a k_title_poll (every title frame): fire -> wait for release, new game (morale $9000, score 0,
    /// section 0) and k_next_section (never returns); otherwise the cheat key check.
    func k_title_poll() {
        if r_joystick() & 0x80 == 0 { k_cheat_check(); return }
        while r_joystick() & 0x80 != 0 { busyWaitYield() }              // busy-wait for the release (no vblank)
        tickPoint(0xfcb6)
        mem.w16(a6 + KV.morale, 0x9000)
        mem.w32(a6 + KV.score, 0)
        mem.w16(a6 + KV.section, 0)
        k_next_section_impl()                                            // bra jt29 (stack not unwound)
    }

    /// $fc80 k_wait_fire_click: wait until fire is released, then pressed.
    func k_wait_fire_click() {
        while r_joystick() & 0x80 != 0 { busyWaitYield() }
        while r_joystick() & 0x80 == 0 { busyWaitYield() }
    }

    /// $10e14 k_cheat_check: lowest held key vs the current cheat sequence ($10ea4); a key must be released
    /// (no key held) before the next one counts; a wrong key restarts the sequence. HAMBURGER -> $70 |= 1
    /// ("CHEAT!!!" on the credits), then KP- HILL -> $70 |= 2 ("MEGA CHEAT", checks disabled).
    func k_cheat_check() {
        if mem.r8(KA.cheat2Flag) == 0 { return }
        guard let d0 = r_getkey() else { mem.w16(KA.cheatHeld, 0); return }
        if mem.r16(KA.cheatHeld) != 0 { return }
        let a0 = mem.r32(KA.cheatPtr)
        if mem.r8(a0) != d0 { k_cheat_reset(); return }
        mem.w8(KA.cheatHeld, 0xff)
        mem.w32(KA.cheatPtr, mem.r32(KA.cheatPtr) &+ 1)
        k_fx_impl(2)
        if mem.r8(a0 &+ 1) != 0 { return }
        if mem.r8(KA.cheat1Flag) == 0 {
            mem.w8(KA.cheat2Flag, 0)
            mem.w16(a6 + KV.cheats, mem.r16(a6 + KV.cheats) | 2)
            return
        }
        mem.w8(KA.cheat1Flag, 0)
        mem.w16(a6 + KV.cheats, mem.r16(a6 + KV.cheats) | 1)
        k_cheat_reset()
    }

    /// $10e7c k_cheat_reset: sequence pointer := HAMBURGER ($11207) or, once that was typed, KP- HILL ($11211).
    func k_cheat_reset() {
        mem.w32(KA.cheatPtr, mem.r8(KA.cheat1Flag) != 0 ? KA.cheat1 : KA.cheat2)
        mem.w16(KA.cheatHeld, 0)
    }
}
