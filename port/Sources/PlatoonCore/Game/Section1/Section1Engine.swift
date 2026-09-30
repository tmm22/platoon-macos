// Section 1 shared engine: bob blits (normal cookie cut and the flare section's "night" blit that lets
// colour-15 scenery occlude), player hit (tunnel and flare variants), red fade / fade back, morale.
// Spec: re/tunnels/NOTES.md §b ($17d1a-$17f7c) and re/flare/NOTES.md §b ($17dd0, $17f7c, $180ee).

extension Platoon {
    // MARK: $17d1a player_hit (tunnels)

    /// $17d1a player_hit: "YOU'RE HIT", thrown out of a room, wounds+1, red flash, KIA handling,
    /// wait for the message queue, morale -$c00, "GET GOING !". Runs inside the object loop.
    func s1_playerHit() {
        if enhancements.cheats.invincible { return }                     // ENHANCEMENT CHEAT-INV (default off)
        mem.w8(S1.enemyHit, 0)
        s1_fx(0x80)
        k_queue_text(0x20)
        if mem.r8(S1.inRoom) != 0 {
            mem.w16(S1.posX, mem.r16(S1.posBeforeRoom))
            mem.w8(S1.inRoom, 0)
            mem.w8(S1.obj4, 0)
            mem.w32(0x19d88, 0)
        }
        _ = s1_addW(s1_a5 + 4, 1)
        s1_hudWounds()
        s1_redFade()
        if mem.r16(s1_a5 + 4) == 4 { s1_killedInAction() }
        s1_playerHitWaitMessages()
    }

    /// $17d76 / $17e06 (+ $17f64 player_hit_last_man): "KILLED IN ACTION"; switch to the second man or
    /// flag the platoon destroyed.
    func s1_killedInAction() {
        k_queue_text(0x1b)
        if enhancements.game.extendedMen {                               // ENHANCEMENT M15 (game.lives/fullPlatoon; default off)
            s1e_killedInAction()
            if enhancements.cheats.infiniteMen { s1_cheatNoWipeOut() }   // ENHANCEMENT CHEAT-MEN (default off)
            return
        }
        if mem.r16(a6 + 0x22) == 1 && enhancements.cheats.infiniteMen {  // ENHANCEMENT CHEAT-MEN (default off)
            mem.w8(S1.destroyed, 0xff)
            s1_cheatNoWipeOut()
            return
        }
        if mem.r16(a6 + 0x22) == 1 {
            mem.w8(S1.destroyed, 0xff)
        } else {
            mem.w16(a6 + 0x22, 1)
            mem.w32(a6 + 0x1e, a6 + 6)                           // lea 6(a6),a5 ; move.l a5,$1e(a6)
            mem.w8(S1.soldierLost, 0xff)
        }
    }

    /// ENHANCEMENT CHEAT-MEN: the last man would be lost ("PLATOON DESTROYED"): patch him up and give him another
    /// chance instead (the "ONE MORE CHANCE" restart of a lost soldier).
    func s1_cheatNoWipeOut() {
        guard mem.r8(S1.destroyed) != 0 else { return }
        mem.w8(S1.destroyed, 0)
        cheatPatchUp(s1_a5)
        mem.w8(S1.soldierLost, 0xff)
    }

    /// $17d9e / $17e2e: wait until all queued messages scrolled, then wounds, morale -$c00, "GET GOING !".
    func s1_playerHitWaitMessages() {
        repeat {
            k_hud_update()
            k_wait_vbl()
        } while mem.r16(a6 + 0x48) != 0
        s1_hudWounds()
        s1_moraleSub(UInt16(truncatingIfNeeded: s1opt.difficulty.hitMorale ?? 0xc00))   // ENHANCEMENT M10
        k_hud_update()
        k_queue_text(0)
    }

    /// $17dd0 player_hit_flare: flare variant (no room handling; red fade only on the 4th hit).
    func s1_playerHitFlare() {
        mem.w8(S1.enemyHit, 0)
        s1_fx(0x80)
        k_queue_text(0x20)
        _ = s1_addW(s1_a5 + 4, 1)
        s1_hudWounds()
        if mem.r16(s1_a5 + 4) == 4 {
            s1_redFade()
            s1_killedInAction()
        }
        s1_playerHitWaitMessages()
    }

    /// $17e60 red_fade: working palette $1a012 toward red, 3 vblanks per step. Unless the man is dead
    /// (hits == 4) the view is redrawn into both buffers and the palette fades back ($17ee8).
    func s1_redFade() {
        var d7: UInt8
        repeat {
            k_wait_vbl(); k_wait_vbl(); k_wait_vbl()
            d7 = 0
            for i in 0..<16 {
                let a = S1.palWork + UInt32(2 * i)
                var d1 = mem.r16(a)
                if d1 & 0xf00 != 0xf00 { d7 = 0xff; d1 &+= 0x100 }
                if d1 & 0x0f0 != 0 { d7 = 0xff; d1 &-= 0x10 }
                if d1 & 0x00f != 0 { d7 = 0xff; d1 &-= 1 }
                mem.w16(a, d1)
            }
            s1_setTopPal(S1.palWork)
        } while d7 != 0
        if mem.r16(s1_a5 + 4) == 4 { return }
        s1_drawView()
        s1_swap()
        s1_drawView()
        s1_swap()
        // L_017ee8 fade back to the tunnel palette $1a032
        repeat {
            k_wait_vbl()
            d7 = 0
            for i in 0..<16 {
                let a1 = S1.palWork + UInt32(2 * i)
                var d1 = mem.r16(a1)
                let d2 = mem.r16(S1.palTunnel + UInt32(2 * i))
                if d1 & 0xf00 != d2 & 0xf00 { d7 = 0xff; d1 &-= 0x100 }
                if d1 & 0x0f0 != d2 & 0x0f0 { d7 = 0xff; d1 &+= 0x10 }
                if d1 & 0x00f != d2 & 0x00f { d7 = 0xff; d1 &+= 1 }
                mem.w16(a1, d1)
            }
            s1_setTopPal(S1.palWork)
        } while d7 != 0
    }

    /// $17f6e morale_sub: $2e(a6) -= d0, clamped at 0 on borrow (unsigned).
    func s1_moraleSub(_ d0: UInt16) {
        if enhancements.cheats.infiniteMorale { return }                 // ENHANCEMENT CHEAT-MORALE (default off)
        let m = mem.r16(a6 + 0x2e)
        mem.w16(a6 + 0x2e, m < d0 ? 0 : m &- d0)
    }

    // MARK: $17f7c blit_bob_normal

    /// $17f7c blit_bob_normal: d0 = x<<16|y, a1 = bob (header long, then mask + 4 planes).
    /// Copies the bob into the scratch buffer with one extra zero word per row, then 4 cookie-cut blits
    /// (D = B | ~A & C) into the draw buffer at byte column $3b3f8.
    func s1_blitBobNormal(_ d0in: UInt32, _ a1in: UInt32) {
        var a1 = a1in
        cpu(S1Cyc.blitNormal)
        chip.write(0x040, 0x0100)
        chip.write(0x042, 0)
        chip.write(0x064, 0)
        chip.write(0x062, 0)
        chip.write(0x060, 0)
        chip.write(0x066, 0)
        chip.writeL(0x050, 0)
        chip.writeL(0x04c, 0)
        chip.writeL(0x048, 0)
        chip.writeL(0x054, S1.bobScratch)
        chip.write(0x058, 0x8c05)                                // clear 560 x 5 words
        var d1 = mem.r32(a1) &+ 0x10001; a1 &+= 4
        var d0 = UInt16(truncatingIfNeeded: d1)
        d0 = (d0 &* 5) << 6
        d0 |= UInt16(truncatingIfNeeded: d1 >> 16) & 0x3f
        chip.write(0x066, 2)
        chip.write(0x040, 0x09f0)
        chip.writeL(0x050, a1)
        chip.writeL(0x054, S1.bobScratch)
        chip.write(0x058, d0)                                    // copy bob, +1 zero word per row
        // destination
        let y = UInt16(truncatingIfNeeded: d0in), x = UInt16(truncatingIfNeeded: d0in >> 16)
        var a0 = mem.r32(S1.lineTab &+ s1_sx(y << 2))
        a0 &+= mem.r32(a6 + 0x62)
        a0 &+= mem.r32(S1.colLeft)
        var d7 = x & 0xf
        a0 &+= UInt32((x >> 3) & 0xfe)
        d1 = mem.r32(a1 &- 4) &+ 0x20001
        let h = d1 & 0xffff, W = (d1 >> 16) & 0xffff
        let size = UInt16(truncatingIfNeeded: (h << 6) | (W & 0x3f))
        let d2 = UInt16(truncatingIfNeeded: (W &* h) << 1)      // mulu.w ; add.w d2,d2
        let d3 = 0x28 &- (UInt16(truncatingIfNeeded: W) << 1)
        let mask = S1.bobScratch
        let planes = (mask & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: mask) &+ d2)  // add.w d2,d1
        d7 = (d7 << 12) | 0x0fce
        chip.write(0x060, d3)
        chip.write(0x066, d3)
        chip.write(0x040, d7)
        chip.write(0x042, d7 & 0xf000)
        chip.writeL(0x050, mask)
        chip.writeL(0x04c, planes)
        chip.writeL(0x048, a0)
        chip.writeL(0x054, a0)
        chip.write(0x058, size)
        for _ in 0..<3 {
            a0 &+= 0x2000
            chip.writeL(0x050, mask)
            chip.writeL(0x048, a0)
            chip.writeL(0x054, a0)
            chip.write(0x058, size)
        }
    }

    // MARK: $180ee blit_bob_night

    /// $180ee blit_bob_night (flare list 1): like the normal blit, but pixels where the draw buffer
    /// currently shows colour 15 are removed from the mask first, so colour-15 scenery hides the bob.
    /// No $3b3f8 column offset.
    func s1_blitBobNight(_ d0in: UInt32, _ a1in: UInt32) {
        var a1 = a1in
        cpu(S1Cyc.blitNight)
        chip.write(0x040, 0x0100)
        chip.write(0x042, 0)
        chip.write(0x064, 0)
        chip.write(0x062, 0)
        chip.write(0x060, 0)
        chip.write(0x066, 0)
        chip.writeL(0x050, 0)
        chip.writeL(0x04c, 0)
        chip.writeL(0x048, 0)
        chip.writeL(0x054, S1.bobScratch)
        chip.write(0x058, 0x8c0a)                                // clear 560 x 10 words
        var d1 = mem.r32(a1) &+ 0x10001; a1 &+= 4
        // swap d1 ; cmp.w #8,d1 ; bcs ; subq.w #8,d1 ; swap d1
        var wwords = UInt16(truncatingIfNeeded: d1 >> 16)
        if !(wwords < 8) { wwords &-= 8 }
        d1 = UInt32(wwords) << 16 | (d1 & 0xffff)
        var d0 = UInt16(truncatingIfNeeded: d1)
        d0 = (d0 &* 5) << 6
        d0 |= wwords & 0x3f
        chip.write(0x066, 2)
        chip.write(0x040, 0x09f0)
        chip.writeL(0x050, a1)
        chip.writeL(0x054, S1.bobScratch)
        chip.write(0x058, d0)
        let y = UInt16(truncatingIfNeeded: d0in), x = UInt16(truncatingIfNeeded: d0in >> 16)
        var a0 = mem.r32(S1.lineTab &+ s1_sx(y << 2))
        a0 &+= mem.r32(a6 + 0x62)
        var d7 = (x & 0xf) << 12
        a0 &+= UInt32((x >> 3) & 0xfe)
        d1 = mem.r32(a1 &- 4) &+ 0x20001
        let h = d1 & 0xffff, W = (d1 >> 16) & 0xffff
        let size = UInt16(truncatingIfNeeded: (h << 6) | (W & 0x3f))
        let d2 = UInt16(truncatingIfNeeded: (W &* h) << 1)
        let d3 = 0x28 &- (UInt16(truncatingIfNeeded: W) << 1)
        let dst = a0
        let temp = S1.nightTemp
        // temp = plane0 & plane1 & plane2 & plane3 (colour 15 where all bits set)
        chip.write(0x064, d3)
        chip.write(0x066, 0)
        chip.write(0x060, 0)
        chip.write(0x040, 0x09f0)
        chip.writeL(0x050, a0)
        chip.writeL(0x054, temp)
        chip.write(0x058, size)
        a0 &+= 0x2000
        chip.write(0x040, 0x0ba0)
        for _ in 0..<3 {
            chip.writeL(0x050, a0)
            chip.writeL(0x048, temp)
            chip.writeL(0x054, temp)
            chip.write(0x058, size)
            a0 &+= 0x2000
        }
        // mask := (mask >> s) & ~temp  (D = A & ~B)
        d7 |= 0x0d30
        chip.write(0x064, 0)
        chip.write(0x066, 0)
        chip.write(0x062, 0)
        chip.writeL(0x050, S1.bobScratch)
        chip.writeL(0x04c, temp)
        chip.writeL(0x054, S1.bobScratch)
        chip.write(0x040, d7)
        chip.write(0x058, size)
        // 4x cookie cut, A already shifted: D = A&B | ~A&C with B shifted by s
        let d6: UInt16 = 0x0fca
        d7 &= 0xf000
        a0 = dst
        let mask = S1.bobScratch
        let planes = (mask & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: mask) &+ d2)
        chip.write(0x060, d3)
        chip.write(0x066, d3)
        chip.write(0x064, 0)
        chip.write(0x040, d6)
        chip.write(0x042, d7)
        chip.writeL(0x050, mask)
        chip.writeL(0x04c, planes)
        chip.writeL(0x048, a0)
        chip.writeL(0x054, a0)
        chip.write(0x058, size)
        for _ in 0..<3 {
            a0 &+= 0x2000
            chip.writeL(0x050, mask)
            chip.writeL(0x048, a0)
            chip.writeL(0x054, a0)
            chip.write(0x058, size)
        }
    }
}
