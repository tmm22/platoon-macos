// Kernel HUD: icons, wounds, score, bars, TIME (jt01-jt06, jt12-jt15).
// Spec: re/kernel/NOTES.md §(b) "HUD"; listing re/kernel/kernel.s $104c6-$10aca.
// Everything is drawn into buffer $78000 only (the HUD is always displayed from it).

extension Platoon {
    // MARK: - icons (jt01, jt02, sound icons)

    /// $104c6 k_hud_compass (jt01): compass icon at $797d0 from $26(a6) (shown) and $2a(a6)&3 (direction);
    /// redrawn only on change. Quirk kept: when $26 changes to nonzero but the direction equals the cached one,
    /// nothing is drawn.
    func k_hud_compass_impl() {
        let a1: UInt32 = 0x797d0
        var d0 = mem.r16(a6 + KV.compassOn)
        if d0 == mem.r16(KA.cache26) {
            if d0 == 0 { return }
        } else {
            mem.w16(KA.cache26, d0)
            if d0 == 0 { k_draw_icon(gfx: KA.iconWound, dest: a1, draw: false); return }   // Z=1 -> blank
        }
        d0 = mem.r16(a6 + KV.compassDir) & 3
        if d0 == mem.r16(KA.cache2a) { return }
        mem.w16(KA.cache2a, d0)
        let a0 = mem.r32(KA.compassFrames &+ UInt32(d0 << 2))
        k_draw_icon(gfx: a0, dest: a1, draw: true)                    // andi.b #$1b,ccr clears Z
    }

    /// $1052c k_hud_soundicons: music ($797e0) and fx ($797e4) on/off icons from $66(a6), only on change.
    func k_hud_soundicons() {
        let d0 = mem.r8(a6 + KV.soundFlags)
        if d0 == mem.r8(KA.cacheSndIcons) { return }
        mem.w8(KA.cacheSndIcons, d0)
        let music = d0 & 1 != 0 ? KA.iconMusicOn : KA.iconMusicOff
        k_draw_icon(gfx: music, dest: 0x797e0, draw: true)            // tst.w k_rts ($4e75) -> Z=0
        let fx = mem.r8(KA.cacheSndIcons) & 2 != 0 ? KA.iconFxOn : KA.iconFxOff
        k_draw_icon(gfx: fx, dest: 0x797e4, draw: true)
    }

    /// $1058a k_hud_icons (jt02): compass, then gun ($2c), map ($24), TNT ($28) icons - nonzero = drawn,
    /// 0 = blanked, only on change.
    func k_hud_icons_impl() {
        tickPoint(0x1058a)
        k_hud_compass_impl()
        var d0 = mem.r16(a6 + KV.gunCount)
        if d0 != mem.r16(KA.cache2c) {
            mem.w16(KA.cache2c, d0)
            k_draw_icon(gfx: KA.iconGun, dest: 0x797d4, draw: d0 != 0)
        }
        d0 = mem.r16(a6 + KV.mapIcon)
        if d0 != mem.r16(KA.cache24) {
            mem.w16(KA.cache24, d0)
            k_draw_icon(gfx: KA.iconMap, dest: 0x797d8, draw: d0 != 0)
        }
        d0 = mem.r16(a6 + KV.tntIcon)
        if d0 == mem.r16(KA.cache28) { return }
        mem.w16(KA.cache28, d0)
        k_draw_icon(gfx: KA.iconTnt, dest: 0x797dc, draw: d0 != 0)
    }

    /// $105f8 k_draw_icon: 24x24 icon = 3x3 cells (row-major, 32 bytes each) from a0 to a1 (+1 byte per column,
    /// +$13e per cell row). `draw` = !Z at entry: mask $ff, else mask 0 (blank).
    func k_draw_icon(gfx a0in: UInt32, dest a1in: UInt32, draw: Bool) {
        let d2: UInt8 = draw ? 0xff : 0
        var a0 = a0in, a1 = a1in
        for _ in 0...2 {
            k_draw_cell_impl(gfx: a0, dest: a1, mask: d2); a0 &+= 0x20; a1 &+= 1
            k_draw_cell_impl(gfx: a0, dest: a1, mask: d2); a0 &+= 0x20; a1 &+= 1
            k_draw_cell_impl(gfx: a0, dest: a1, mask: d2); a0 &+= 0x20; a1 &+= 0x13e
        }
    }

    // MARK: - score (jt03, jt04, jt05)

    /// $10638 k_add_score (jt03): score $4e..$51(a6) += the 4-byte BCD value ending at a0 (abcd -(a0),-(a1)
    /// x4, X cleared first; wraps at 99999999); clears $52 so the next jt05 reprints the score.
    func k_add_score_impl(after a0in: UInt32) {
        mem.w8(a6 + KV.scorePrinted, 0)
        var a0 = a0in, a1 = a6 + KV.scorePrinted
        var x = false
        for _ in 0..<4 {
            a0 &-= 1; a1 &-= 1
            let (r, c) = Platoon.abcd(mem.r8(a1), mem.r8(a0), x: x)
            mem.w8(a1, r); x = c
        }
        cpu(150)
        if config.probe != nil { probeScore(after: a0in) }             // F2 observer (read-only)
    }

    /// $106a0 k_print_hiscore1 (jt04): header $11220 (col 16 row 22) + best score $11808.
    func k_print_hiscore1_impl() {
        r_print(KA.strHiscoreHdr)
        k_hex32_impl(mem.r32(KA.hsScores))
    }

    /// $106b4 k_force_score: clear the printed flag, then k_print_score.
    func k_force_score() {
        mem.w8(a6 + KV.scorePrinted, 0)
        k_print_score_impl()
    }

    /// $106b8 k_print_score (jt05): `tas $52(a6)`; if it was clear print the score (col 16 row 24).
    func k_print_score_impl() {
        let was = mem.r8(a6 + KV.scorePrinted)
        mem.w8(a6 + KV.scorePrinted, was | 0x80)
        if was != 0 { return }                                          // tas: Z/N from the old byte
        r_print(KA.strScoreHdr)
        k_hex32_impl(mem.r32(a6 + KV.score))
    }

    // MARK: - wounds (jt06)

    /// $10656 k_hud_wounds (jt06): wound splats for the current man ((man)+4 of them, the flag byte $1069e
    /// selects drawn/blank) in the 4 slots $797c0+4k; the remaining slots are blanked.
    func k_hud_wounds_impl() {
        tickPoint(0x10656)
        var d1: UInt16 = 0
        let a2 = mem.r32(a6 + KV.curMan)
        var d0 = mem.r16(a2 &+ 4)
        var a1: UInt32 = 0x797c0
        let a0 = KA.iconWound
        d0 &-= 1
        if Int16(bitPattern: d0) < 0 {
            d0 = 6; mem.w8(KA.woundFlag, 0)
        } else {
            mem.w8(KA.woundFlag, 0xff)
        }
        while true {
            k_draw_icon(gfx: a0, dest: a1, draw: mem.r8(KA.woundFlag) != 0)
            a1 &+= 4
            d1 &+= 1
            if d1 >= 4 { return }
            d0 &-= 1                                                    // dbra d0
            if d0 == 0xffff { d0 = 6; mem.w8(KA.woundFlag, 0) }
        }
    }

    // MARK: - HUD init / update (jt12, jt13)

    /// $1084a k_hud_init (jt12): invalidate the HUD caches ($1357 / $ff), print the labels, score, best score,
    /// wounds, then a full jt13 and jt02.
    func k_hud_init_impl() {
        tickPoint(0x1084a)
        for c in [KA.cache28, KA.cache24, KA.cache2c, KA.cache26, KA.cache2a, KA.cacheTime] { mem.w16(c, 0x1357) }
        mem.w8(KA.cacheSndIcons, 0xff)
        r_print(KA.strHudLabels)
        k_force_score()
        k_print_hiscore1_impl()
        k_hud_wounds_impl()
        k_hud_update_impl()
        k_hud_icons_impl()
    }

    /// $108a0 k_hud_update (jt13): score, text tick, sound icons, compass, the three bars - repeated while the
    /// game is paused ($10eaa != 0: the original spins here without waiting, so a message on screen finishes
    /// instantly) - then "TIME mm:ss" if the timer is on and the minutes/seconds changed.
    func k_hud_update_impl() {
        tickPoint(0x108a0)
        repeat {
            k_print_score_impl()
            k_text_tick()
            k_hud_soundicons()
            k_hud_compass_impl()
            k_hud_topbar()
            k_hud_ammobar()
            k_hud_moralebar()
            tickPoint(0x108bc)
            // The pause word and the timer are changed by the vblank handler: test them only when the CPU time
            // of the HUD work has elapsed (e.g. TAB pressed while the bars are drawn -> this update already
            // loops; the timer decremented by a vblank during the bars -> TIME shows the new value now).
            settleCPU()
        } while mem.r16(KA.pause) != 0
        if mem.r16(a6 + KV.timerOn) == 0 { return }
        let d0 = mem.r16(a6 + KV.timerMin)                              // word: minutes:seconds
        if d0 == mem.r16(KA.cacheTime) { return }
        mem.w16(KA.cacheTime, d0)
        r_print(KA.strTimeHdr)
        k_hex8_impl(mem.r8(a6 + KV.timerMin))
        r_putchar(0x3a)                                                 // ':'
        k_hex8_impl(mem.r8(a6 + KV.timerSec))
    }

    /// $10906 k_hud_topbar: grenades of the current man x8 ($54 = 0, gfx $13294) or flares $2c x8 (gfx $132d4)
    /// at $79cda.
    func k_hud_topbar() {
        tickPoint(0x10906)
        if mem.r16(a6 + KV.topBarMode) != 0 {
            k_draw_bar_impl(value: mem.r16(a6 + KV.gunCount) << 3, gfx: KA.hudFlare, dest: 0x79cda)
        } else {
            let a5 = mem.r32(a6 + KV.curMan)
            k_draw_bar_impl(value: mem.r16(a5) << 3, gfx: KA.hudGrenade, dest: 0x79cda)
        }
    }

    /// $1093c k_hud_ammobar: ammo of the current man >> 1 at $79e1a (gfx $13274).
    func k_hud_ammobar() {
        tickPoint(0x1093c)
        let a5 = mem.r32(a6 + KV.curMan)
        k_draw_bar_impl(value: mem.r16(a5 &+ 2) >> 1, gfx: KA.hudBullet, dest: 0x79e1a)
    }

    /// $10956 k_hud_moralebar: morale high byte >> 1 (lsr.b) at $79e05 (gfx $13254 hearts).
    func k_hud_moralebar() {
        tickPoint(0x10956)
        k_draw_bar_impl(value: UInt16(mem.r8(a6 + KV.morale) >> 1), gfx: KA.hudHeart, dest: 0x79e05)
    }

    // MARK: - bars and cells (jt14, jt15)

    /// $10968 k_draw_bar (jt14): value = d0.b clamped to $48; 9 cells: value>>3 full cells, one partial cell
    /// (mask $1131e[value&7]; drawn even when value&7 == 0, i.e. blank), the rest blank.
    func k_draw_bar_impl(value d0in: UInt16, gfx a0: UInt32, dest a1in: UInt32) {
        var d0 = UInt8(truncatingIfNeeded: d0in)                        // andi.l #$ff,d0
        var d4: Int8 = 8
        if d0 >= 0x49 { d0 = 0x48 }
        let d1 = d0
        var a1 = a1in
        if d1 != 0 {
            var n = d0 >> 3
            if n != 0 {
                n -= 1
                for _ in 0...Int(n) {
                    k_draw_cell_impl(gfx: a0, dest: a1, mask: 0xff)
                    a1 &+= 1
                    d4 &-= 1
                }
            }
            if d4 < 0 { return }
            let mask = mem.r32(KA.barMasks &+ UInt32(d1 & 7) << 2)
            k_draw_cell_impl(gfx: a0, dest: a1, mask: UInt8(truncatingIfNeeded: mask))
            d4 &-= 1
            if d4 < 0 { return }
            a1 &+= 1
        }
        while true {                                                    // L_0109b6 blank cells
            k_draw_cell_impl(gfx: a0, dest: a1, mask: 0)
            d4 &-= 1
            if d4 < 0 { return }
            a1 &+= 1
        }
    }

    /// $109be k_draw_cell (jt15): 8x8 4-plane cell (32 bytes: per line plane 0..3) ANDed with mask d2 to a1
    /// (stride 40, planes $2000 apart).
    func k_draw_cell_impl(gfx a0: UInt32, dest a1: UInt32, mask d2: UInt8) {
        var s = a0
        for y in 0..<8 {
            let row = a1 &+ UInt32(y * 0x28)
            for p in 0..<4 {
                mem.w8(row &+ UInt32(p * 0x2000), mem.r8(s) & d2)
                s &+= 1
            }
        }
        cpu(940)                                                        // incl. call overhead (emu: hud_wounds 74 lines = 36 cells)
    }
}
