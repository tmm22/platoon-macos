// Section 1, flare section ("dugout at night"): entry from the tunnels (normal exit or HELP cheat),
// background decoder, main loop, flares and light cycle (palette sequence), enemies, crosshair,
// muzzle flashes, win/lose. Spec: re/flare/NOTES.md.

extension Platoon {
    // MARK: entry

    /// $18afe flare_cheat_entry (HELP with MEGA CHEAT in the tunnels): 9 flares, "LET'S GO TO THE FLARE SCREEN!".
    func s1_flareCheatEntry(_ a3: UInt32) -> Never {
        mem.w16(a6 + 0x2c, 9)
        k_queue_text(0x24)
        s1_flareEnter(a3)
    }

    /// $18b0e flare_enter. The original resets the stack (`lea $400,a7` at $18b5e): the tunnel call chain
    /// (main loop -> objects -> crosshair handler -> ...) is abandoned, so this continues on a fresh game
    /// thread via `m.jump`. `a3` is the stale object pointer of the caller (tunnel crosshair $19d32), which the
    /// original's init loop writes into by mistake ($18b3a).
    func s1_flareEnter(_ a3: UInt32) -> Never {
        m.jump { [unowned self] in self.s1_flareEnterBody(a3) }
    }

    func s1_flareEnterBody(_ a3: UInt32) -> Never {
        tickPoint(0x18b0e)
        if s1opt.needsScratch { s1e_flareEntered() }                  // ENHANCEMENT M4 (default off)
        s1_fadeOutAndClear()
        s1_recolourCrosshairC4()
        for k in 0..<8 { mem.w8(S1.spawnSlots + UInt32(4 * k), 0) }
        var a0 = S1.list1Enemies
        for _ in 0..<5 {
            mem.w8(a0, 0)
            mem.w8(a0 + 0x90, 0)
            mem.w16(a3 + 0xe, 0)                                 // BUG in the original: a3, not a0
            mem.w16(a3 + 0x10, 0)
            mem.w8(a3 + 1, 0)
            mem.w8(a3 + 0x91, 0)
            a0 &+= 0x12
        }
        s1_setTopPal(mem.r32(S1.palSeq))
        // lea $400,a7
        s1_music(6)
        s1_decodeBackground()
        mem.w32(S1.colLeft, 0)
        mem.w16(S1.spawnCount, 0x24)
        mem.w16(S1.spawnBase, UInt16(truncatingIfNeeded: s1opt.difficulty.flareSpawnBase ?? 0x90))   // ENHANCEMENT M10
        s1_copyBackground()
        s1_swap()
        s1_copyBackground()
        s1_swap()
        mem.w16(S1.palIndex, 0)
        _ = s1_paletteStep()
        var d6: UInt16 = 0x25
        for _ in 0..<3 {
            k_queue_text(d6); d6 &+= 1
            repeat {
                k_wait_vbl(); k_wait_vbl(); k_wait_vbl()
                k_hud_update()
            } while mem.r16(a6 + 0x48) != 0
        }
        s1_flareMainLoop()
    }

    // MARK: main loop

    /// $18bd8 flare_main_loop. Not vblank-locked in the original: it waits for the previous buffer swap
    /// ($f85c, latched by the level-6 split interrupt at line ~204) and then spends ~335 raster lines of CPU
    /// on the background copy, so an iteration normally takes 2 frames (emulator: 174x2, 22x1, 18x3 over 214
    /// iterations). The port reproduces this through the CPU-time model: copy_background, the object loop and
    /// the blits charge their 68000 cycles, which are paid before the swap / palette writes and in f85c.
    func s1_flareMainLoop() -> Never {
        while true {
            snapshotPoint(0x18bd8)                    // savestate point (Game/Snapshot; no-op unless a host asked)
            tickPoint(0x18bd8)
            if mem.r8(a6 + 0x71) & 2 != 0 && s1_keytest(0x5f) { s1_flareWin() }
            k_wait_swap()
            s1_copyBackground()
            if s1_subW(S1.spawnCount, 1) == 0 { s1_flareSpawn() }
            // flare_loop_objects
            s1_flareObjects()
            if mem.r8(S1.soldierLost) != 0 {
                if s1opt.flareRetry && s1e_active { s1e_flareRetry() }  // ENHANCEMENT M4 (s1.flareRetry; default off)
                s1_exitBackToTunnels()
            }
            if mem.r16(a6 + 0x2e) == 0 { s1_exitMoraleZero() }
            if mem.r8(S1.destroyed) != 0 { s1_exitPlatoonDestroyed() }
            var countdown = true
            if mem.r8(S1.lightCycle) == 0 {
                if s1_keytest(0x40) { s1_fireFlare() } else { countdown = false }
            }
            if countdown && mem.r8(S1.list1) == 0 {
                // flare_palette_countdown
                let c = mem.r8(S1.palCount) &- 1
                mem.w8(S1.palCount, c)
                if c == 0 {
                    let d0 = s1_paletteStep() >> 2
                    mem.w8(S1.palCount, mem.r8(S1.palStepDur &+ s1_sx(d0)))
                }
            }
            // flare_loop_end
            k_hud_update()
            s1_swap()
        }
    }

    /// $18c08-$18ca0: spawn countdown expired: new enemy in a free record and a free column.
    func s1_flareSpawn() {
        let d1 = (mem.r16(S1.spawnBase) &+ mem.r16(S1.killBonus)) >> 2
        mem.w16(S1.spawnCount, d1 == 0 && s1opt.fixFlareSpawn ? 1 : d1)   // ENHANCEMENT S9d (default off)
        var a0 = S1.list1Enemies
        var free = false
        for _ in 0..<5 {
            if mem.r8(a0) == 0 { free = true; break }
            a0 &+= 0x12
        }
        if !free { mem.w16(S1.spawnCount, 1); return }
        let a1 = S1.spawnSlots
        var d0 = ((UInt16(truncatingIfNeeded: k_random()) >> 4) & 7) << 2
        let start = d0
        while mem.r8(a1 &+ UInt32(d0)) != 0 {
            d0 = (d0 &+ 4) & 0x1f
            if d0 == start { mem.w16(S1.spawnCount, 1); return }
        }
        mem.w8(a1 &+ UInt32(d0), 0xff)
        mem.w16(a0 + 2, mem.r16(a1 &+ UInt32(d0) &+ 2))
        mem.w16(a0 + 0x10, d0)
        let r = ((UInt16(truncatingIfNeeded: k_random()) >> 4) & 7) &+ 0x40
        mem.w16(a0 + 4, r)
        mem.w8(a0, 0xff)
        mem.w8(a0 + 1, 0)
        mem.w32(a0 + 0xa, 0x19174)
    }

    /// $17810 flare_update_draw_objects: list 1 (flare + enemies, night blit) then list 2 (crosshair +
    /// muzzle flashes, normal blit), entries 7..0 each.
    func s1_flareObjects() {
        for pass in 0..<2 {
            let night = pass == 0
            var a3 = (night ? S1.list1 : S1.list2) + 0x7e
            for _ in 0..<8 {
                cpu(S1Cyc.objSlot)
                if mem.r8(a3) != 0 {
                    cpu(S1Cyc.objActive)
                    s1_objectHandler(mem.r32(a3 + 0xa), a3)
                    if mem.r8(a3) != 0 { s1_drawObject(a3, night: night) }
                }
                a3 &-= 0x12
            }
        }
    }

    /// $18d22 fire_flare: launch the flare (one at a time) and start the light cycle.
    func s1_fireFlare() {
        if mem.r8(S1.lightCycle) != 0 { return }
        _ = s1_subW(a6 + 0x2c, 1)
        mem.w8(S1.list1, 0xff)
        mem.w8(0x19e0b, 0)
        mem.w16(0x19e0e, 0x6e)
        s1_fx(0x0a)
        mem.w8(S1.lightCycle, 0xff)
        mem.w8(S1.palCount, 1)
    }

    /// $18d5e copy_background: clean scene $68000 -> draw buffer, 144 rows x 40 bytes x 4 planes.
    func s1_copyBackground() {
        let dst = mem.r32(a6 + 0x62)
        for p in 0..<4 {
            let o = UInt32(p * 0x2000)
            mem.copy(from: S1.bgClean + o, to: dst &+ o, count: 0x1680)
        }
        cpu(144 * S1Cyc.bgRow + 40)
    }

    /// $18e3a palette_step: set the next palette of the light sequence; returns the new index (d0).
    /// At the end of the sequence the light cycle stops; with no flares left the night is survived.
    func s1_paletteStep() -> UInt16 {
        var d0 = mem.r16(S1.palIndex)
        s1_setTopPal(mem.r32(S1.palSeq &+ s1_sx(d0)))
        d0 &+= 4
        if d0 == 0x1c {
            d0 = 0
            mem.w8(S1.lightCycle, 0)
            if mem.r16(a6 + 0x2c) == 0 { s1_flareWin() }
        }
        mem.w16(S1.palIndex, d0)
        return d0
    }

    /// $18e6c flare_win: "WELL DONE, / YOU MADE IT THROUGH THE NIGHT", fade, next load section.
    func s1_flareWin() -> Never {
        k_queue_text(0x28)
        k_queue_text(0x29)
        s1_fadeOutAndClear()
        k_next_section()
    }

    /// $18e92 decode_background: byte RLE at $36242 -> $68000 (row-interleaved planes, 144 rows).
    func s1_decodeBackground() {
        var a0 = S1.bgRLE
        var a1 = S1.bgClean, a2 = S1.bgClean
        var d5: UInt32 = 0
        var d6: UInt8 = 0, d7: UInt8 = 0
        /// $18eda bg_put_byte; returns true when the 144th row is complete (addq.l #4,a7 ; rts).
        var cycles = 0
        func put(_ d1: UInt8) -> Bool {
            mem.w8(a1, d1); a1 &+= 1
            let wasSet = d5 & 0x8000 != 0
            d5 ^= 0x8000
            if !wasSet { cycles += S1Cyc.bgByteEven; return false }
            cycles += S1Cyc.bgByteOdd
            let b = UInt8(truncatingIfNeeded: d5) &+ 2
            d5 = (d5 & ~0xff) | UInt32(b)
            if b != 0x28 { return false }
            cycles += S1Cyc.bgRowEnd
            d5 &= ~0xff
            a2 &+= 0x2000; a1 = a2
            d6 = (d6 &+ 1) & 3
            if d6 != 0 { return false }
            a2 &-= 0x7fd8; a1 = a2
            d7 &+= 1
            return d7 == 0x90
        }
        defer { cpu(cycles) }
        while true {
            let d0 = mem.r8(a0); a0 &+= 1
            if d0 & 0x80 == 0 {
                cycles += S1Cyc.bgCtrlLiteral
                for _ in 0...Int(d0 & 0x7f) {
                    let d1 = mem.r8(a0); a0 &+= 1
                    cycles += S1Cyc.bgLiteralExtra
                    if put(d1) { return }
                }
            } else {
                if d0 == 0x80 { cycles += S1Cyc.bgCtrlNop; continue }
                cycles += S1Cyc.bgCtrlRun
                let n = (0 &- d0) & 0x7f
                let d1 = mem.r8(a0); a0 &+= 1
                for _ in 0...Int(n) { if put(d1) { return } }
            }
        }
    }

    /// $189c0 recolor_crosshair_c4: crosshair ($1e020) and muzzle-flash bobs ($1e048/$1e050) := colour 4.
    func s1_recolourCrosshairC4() {
        s1_recolourBobC4(mem.r32(S1.animTable))
        s1_recolourBobC4(mem.r32(0x1e048))
        s1_recolourBobC4(mem.r32(0x1e050))
    }

    /// $189da recolor_bob_c4: bp0 := 0, bp1 := 0, bp2 := mask, bp3 := 0.
    func s1_recolourBobC4(_ off: UInt32) {
        var a0 = off &+ S1.bobBank
        let d7 = mem.r32(a0); a0 &+= 4
        let d5 = d7 &+ 0x10001
        let h = d5 & 0xffff
        let s = UInt16(truncatingIfNeeded: UInt32(UInt16(truncatingIfNeeded: (d5 >> 16) << 1)) &* h)
        let rows = Int(d7 & 0xffff) + 1, cols = Int(d7 >> 16) + 1
        for _ in 0..<rows {
            for _ in 0..<cols {
                let d0 = mem.r16(a0)
                var d2 = s
                mem.w16(a0 &+ s1_sx(d2), 0); d2 &+= s
                mem.w16(a0 &+ s1_sx(d2), 0); d2 &+= s
                mem.w16(a0 &+ s1_sx(d2), d0); d2 &+= s
                mem.w16(a0 &+ s1_sx(d2), 0)
                a0 &+= 2
            }
        }
    }

    // MARK: fades

    /// $18a20 fade_copy_palette: current palette ($5a(a6)) -> $3b722, set it.
    func s1_fadeCopyPalette() {
        let a0 = mem.r32(a6 + 0x5a)
        for i in 0..<8 { mem.w32(S1.fadePal + UInt32(4 * i), mem.r32(a0 &+ UInt32(4 * i))) }
        s1_setTopPal(S1.fadePal)
    }

    /// $18a42 fade_step_down: every component of the 16 colours -1 toward 0; $18a40 = changed flag.
    func s1_fadeStepDown() {
        var d1: UInt16 = 0
        for i in 0..<16 {
            let a = S1.fadePal + UInt32(2 * i)
            let w = mem.r16(a)
            var d2 = w & 0xf, d3 = w & 0xf0, d4 = w & 0xf00
            if d2 != 0 { d2 &-= 1; d1 = 0xff }
            if d3 != 0 { d3 &-= 0x10; d1 = 0xff }
            if d4 != 0 { d4 &-= 0x100; d1 = 0xff }
            mem.w16(a, d2 | d3 | d4)
        }
        mem.w16(S1.fadeActive, d1)
        s1_setTopPal(S1.fadePal)
    }

    /// $18a98 fade_out_and_clear: fade to black (3 vblanks per step, also until the message queue is
    /// empty), then clear lines 0..143 of both screen buffers.
    func s1_fadeOutAndClear() {
        s1_fadeCopyPalette()
        repeat {
            k_wait_vbl(); k_wait_vbl(); k_wait_vbl()
            s1_fadeStepDown()
            k_hud_update()
        } while mem.r16(a6 + 0x48) != 0 || mem.r16(S1.fadeActive) != 0
        for p in 0..<4 {
            let o = UInt32(p * 0x2000)
            mem.fill(0x70000 + o, count: 0x1680)
            mem.fill(0x78000 + o, count: 0x1680)
        }
        cpu(0x5a0 * S1Cyc.clearIter + 30)
    }

    // MARK: object handlers

    /// $19048 h_crosshair (list 2 [0]): accelerating cursor; fire shoots, or fires a flare on the flare box.
    func s1_hFlareCrosshair(_ a3: UInt32) {
        var d0 = s1_joystick()
        if s1opt.directAim && s1e_aimAt(a3, .flare) { d0 &= 0xf0 }   // ENHANCEMENT L2 (s1.directAim; default off)
        var d1: UInt16 = 0
        if d0 & 0xf == 0 {
            mem.w16(S1.crossSpeed, 4)
        } else {
            d1 = mem.r16(S1.crossSpeed) >> 1
            if mem.r16(S1.crossSpeed) < 0xf { _ = s1_addW(S1.crossSpeed, 2) }
        }
        mem.w8(S1.shotFlag, 0)
        if d0 & 0x80 != 0 {
            let x = mem.s16(a3 + 2), y = mem.s16(a3 + 4)
            if x >= 0xcf && x <= 0xdf && y >= 0x6f && y <= 0x78 { s1_fireFlare(); return }
            if mem.r16(s1_a5 + 2) != 0 {
                mem.w8(S1.shotFlag, 0xff)
                if s1_subW(S1.spawnBase, 2) & 0x8000 != 0 { mem.w16(S1.spawnBase, 0) }
                s1_shotJitterFlare(a3)
            }
        }
        // L_0190da
        var right = false
        if d0 & 0x04 != 0 {
            if Int16(bitPattern: s1_subW(a3 + 4, d1)) > 9 {
                right = true                                     // bgt L_01912e (skips down and left: bug)
            } else {
                mem.w16(a3 + 4, 0xa)
            }
        }
        if !right {
            if d0 & 0x01 != 0 {
                if Int16(bitPattern: s1_addW(a3 + 4, d1)) >= 0x79 { mem.w16(a3 + 4, 0x78) }
            }
            if d0 & 0x08 != 0 {
                if !(Int16(bitPattern: s1_subW(a3 + 2, d1)) > 0x1d) { mem.w16(a3 + 2, 0x1e) }
            }
        }
        // L_01912e
        if d0 & 0x02 != 0 {
            if Int16(bitPattern: s1_addW(a3 + 2, d1)) >= 0x10f { mem.w16(a3 + 2, 0x10e) }
        }
    }

    /// $18fba shot_jitter_flare: ammo -1, gunshot, 4x random recoil (x $1e..$10e, y $a..$78).
    func s1_shotJitterFlare(_ a3: UInt32) {
        _ = s1_subW(s1_a5 + 2, 1)
        s1_fx(0x83)
        var r = UInt16(truncatingIfNeeded: k_random()) & 7
        if Int16(bitPattern: s1_addW(a3 + 2, r)) >= 0x10f { mem.w16(a3 + 2, 0x10e) }
        r = UInt16(truncatingIfNeeded: k_random()) & 7
        if !(Int16(bitPattern: s1_subW(a3 + 2, r)) > 0x1d) { mem.w16(a3 + 2, 0x1e) }
        r = UInt16(truncatingIfNeeded: k_random()) & 7
        if Int16(bitPattern: s1_addW(a3 + 4, r)) >= 0x79 { mem.w16(a3 + 4, 0x78) }
        r = UInt16(truncatingIfNeeded: k_random()) & 7
        if !(Int16(bitPattern: s1_subW(a3 + 4, r)) > 9) { mem.w16(a3 + 4, 0xa) }
    }

    /// $1914c h_flare_rise (list 1 [0]): up $14 per iteration, frame+1 every 2nd; gone when y < 0.
    func s1_hFlareRise(_ a3: UInt32) {
        if s1_subW(a3 + 4, 0x14) & 0x8000 != 0 { mem.w8(a3, 0); return }
        let p = (mem.r16(a3 + 0x10) &+ 1) & 1
        mem.w16(a3 + 0x10, p)
        if p != 0 { return }
        mem.w8(a3 + 1, mem.r8(a3 + 1) &+ 1)
    }

    /// $19174 h_enemy_rise (state A): frames 0,1,2 every 8 iterations, then aim.
    func s1_hEnemyRise(_ a3: UInt32) {
        s1_enemyHitTest(a3)
        let e = (mem.r16(a3 + 0xe) &+ 1) & 7
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        let f = mem.r8(a3 + 1) &+ 1
        mem.w8(a3 + 1, f)
        if f != 3 { return }
        mem.w32(a3 + 0xa, 0x191a2)
    }

    /// $191a2 h_enemy_aim (state B): 16 iterations, first shot (fx $84), then shoot.
    func s1_hFlareEnemyAim(_ a3: UInt32) {
        s1_enemyHitTest(a3)
        let e = (mem.r16(a3 + 0xe) &+ 1) & 0xf
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        mem.w32(a3 + 0xa, 0x191cc)
        s1_fx(0x84)
        s1_enemyMuzzleFlash(a3)
    }

    /// $191cc h_enemy_shoot (state C): flash every 8 iterations; hits the player after a threshold that
    /// depends on the light phase.
    func s1_hFlareEnemyShoot(_ a3: UInt32) {
        s1_enemyHitTest(a3)
        let e = s1_addW(a3 + 0xe, 1)
        var d0 = (mem.r16(S1.palIndex) >> 2) &- 3
        if d0 & 0x8000 != 0 { d0 = 0 &- d0 }
        d0 = ((d0 &+ 1) << 4) &- UInt16(truncatingIfNeeded: s1opt.difficulty.flareShotSlack ?? 0xd)   // ENHANCEMENT M10
        if Int16(bitPattern: d0) < Int16(bitPattern: e) { s1_enemyHitsPlayer(a3); return }
        if mem.r16(a3 + 0xe) & 7 != 0 { return }
        s1_fx(0x83)
        s1_enemyMuzzleFlash(a3)
    }

    /// $19212 enemy_muzzle_flash: activate the companion record (a3+$90) at x-$d, y+$b.
    func s1_enemyMuzzleFlash(_ a3: UInt32) {
        mem.w8(a3 + 0x90, 0xff)
        mem.w32(a3 + 0x92, mem.r32(a3 + 2))
        _ = s1_subW(a3 + 0x92, 0xd)
        _ = s1_addW(a3 + 0x94, 0xb)
    }

    /// $1922a enemy_hits_player: free slot, remove enemy, reset spawn difficulty, start a light cycle, hit.
    func s1_enemyHitsPlayer(_ a3: UInt32) {
        mem.w8(S1.spawnSlots &+ s1_sx(mem.r16(a3 + 0x10)), 0)
        mem.w8(a3, 0)
        mem.w16(S1.spawnCount, 0x24)
        mem.w16(S1.spawnBase, UInt16(truncatingIfNeeded: s1opt.difficulty.flareSpawnBase ?? 0x90))   // ENHANCEMENT M10
        mem.w16(S1.killBonus, 0)
        mem.w8(S1.lightCycle, 0xff)
        s1_playerHitFlare()
    }

    /// $1925a h_enemy_dying: frames 5,6,7 (2 iterations each), then gone, +3 kill bonus, +300.
    func s1_hFlareEnemyDying(_ a3: UInt32) {
        let e = (mem.r16(a3 + 0xe) &+ 1) & 1
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        let f = mem.r8(a3 + 1) &+ 1
        mem.w8(a3 + 1, f)
        if f != 8 { return }
        mem.w8(a3, 0)
        _ = s1_addW(S1.killBonus, 3)
        mem.w8(S1.spawnSlots &+ s1_sx(mem.r16(a3 + 0x10)), 0)
        k_add_score(after: S1.score300End)
    }

    /// $192a0 h_muzzle_flash (list 2 [1..6]).
    func s1_hMuzzleFlash(_ a3: UInt32) {
        let p = (mem.r16(a3 + 0x10) &+ 1) & 1
        mem.w16(a3 + 0x10, p)
        if p != 0 { return }
        let f = (mem.r8(a3 + 1) &+ 1) & 1
        mem.w8(a3 + 1, f)
        if f != 0 { return }
        mem.w8(a3, 0)
    }

    /// $192c4 enemy_hit_test: crosshair point inside the enemy's 31x26 box with a shot fired -> dying.
    func s1_enemyHitTest(_ a3: UInt32) {
        let x = mem.r16(a3 + 2), y = mem.r16(a3 + 4)
        guard s1_crossInBox(cross: S1.list2, x: x, y: y, x2: x &+ 0x1e, y2: y &+ 0x19) else { return }
        mem.w8(a3 + 1, 5)
        mem.w16(a3 + 0xe, 0)
        mem.w32(a3 + 0xa, 0x1925a)
        s1_fx(0x80)
        mem.w8(S1.enemyHit, 0xff)
    }
}
