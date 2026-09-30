// Section 1, tunnel game: view composer, map window, tunnel objects and their handlers, input
// (walk / combat / room cursor), rooms, hotspots and item handlers. Spec: re/tunnels/NOTES.md §b.

/// Non-local exit of the 68k code: `addq.l #4,a7; rts` in the tunnel input routines returns directly
/// from the crosshair handler ($178be) and skips the crosshair sway. Modelled as a Bool result.
typealias S1Popped = Bool

extension Platoon {
    // MARK: small helpers for exact word arithmetic on RAM

    @inline(__always) func s1_addW(_ a: UInt32, _ v: UInt16) -> UInt16 {
        let r = mem.r16(a) &+ v; mem.w16(a, r); return r
    }
    @inline(__always) func s1_subW(_ a: UInt32, _ v: UInt16) -> UInt16 {
        let r = mem.r16(a) &- v; mem.w16(a, r); return r
    }

    // MARK: $17304 spawn_enemy

    /// $17304: choose the enemy type from the view codes of the current position.
    func s1_spawnEnemy() {
        mem.w16(S1.crossSpeed, 2)
        var d0 = mem.r8(S1.viewCodeL)
        if d0 & 0x08 != 0 || d0 & 0x10 != 0 {
            // L_01736e water enemy (wall or room door ahead)
            mem.w8(0x19d68, 0xff)
            mem.w8(0x19d69, 0)
            mem.w16(0x19d6a, 0x23)
            mem.w16(0x19d6c, 0x3b)
            mem.w32(0x19d72, 0x17a4a)
            mem.w32(0x19d6e, 0x1e108)
            mem.w32(0x19d76, 0)
            return
        }
        d0 &= 7
        if d0 == 5 {
            // L_0173a6 side enemy on the left
            mem.w8(0x19d56, 0xff)
            mem.w16(0x19d58, 0x23)
            mem.w16(0x19d5a, 0x36)
            mem.w32(0x19d60, 0x17996)
            mem.w16(0x19d64, 0)
            mem.w8(0x19d57, 2)
            return
        }
        d0 = mem.r8(S1.viewCodeR) & 7
        if d0 == 5 {
            // L_0173d6 side enemy on the right
            mem.w8(0x19d56, 0xff)
            mem.w16(0x19d58, 0x69)
            mem.w16(0x19d5a, 0x36)
            mem.w32(0x19d60, 0x17996)
            mem.w16(0x19d64, 0)
            mem.w8(0x19d57, 2)
            return
        }
        // far corridor enemy
        mem.w8(0x19d56, 0xff)
        mem.w8(0x19d57, 0)
        mem.w16(0x19d58, 0x41)
        mem.w16(0x19d5a, 0x27)
        mem.w32(0x19d60, 0x17968)
        mem.w16(0x19d64, 0)
    }

    // MARK: $17406 draw_view

    /// $17406 draw_view: corridor view (two halves from 40 tile maps) or the room picture.
    func s1_drawView() {
        if mem.r8(S1.inRoom) != 0 { s1_drawRoomPic(); return }
        var d0 = UInt32(mem.r16(a6 + 0x2a) & 3) << 2
        let a0 = mem.r32(S1.viewOffsets + d0)
        d0 = UInt32(mem.r8(S1.posX))
        let d1 = UInt32(mem.r8(S1.posY)) << 2
        d0 &+= mem.r32(S1.mazeRowTab &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: d1))))
        let a1 = S1.maze &+ d0
        // d0.w = lo, d1.w = ro, d2.w = fo (upper words are 0 here)
        var lo = mem.r16(a0), ro = mem.r16(a0 + 2)
        let fo = mem.r16(a0 + 4)
        @inline(__always) func cell(_ o: UInt16) -> UInt8 {
            mem.r8(a1 &+ UInt32(bitPattern: Int32(Int16(bitPattern: o))))
        }
        var d6: UInt8 = 0, d7: UInt8 = 0
        // forward scan for the left half
        var d3 = fo
        var d4: Int = 3
        while d4 >= 0 {
            if cell(d3) == 3 { d6 |= 0x10; d6 |= UInt8(d4); break }   // L_017490
            if cell(d3) != 2 { d6 |= 0x08; d6 |= UInt8(d4); break }   // L_017486
            d3 &+= fo
            d4 -= 1
        }
        // L_017470 left lateral scan
        d4 = 3
        while d4 >= 0 {
            if cell(lo) == 2 { d6 |= 0x04; d6 |= UInt8(d4); break }   // L_01749a
            lo &+= fo
            d4 -= 1
        }
        // L_0174a0 forward scan again for the right half
        d3 = fo
        d4 = 3
        while d4 >= 0 {
            if cell(d3) == 3 { d7 |= 0x10; d7 |= UInt8(d4); break }   // L_0174de
            if cell(d3) != 2 { d7 |= 0x08; d7 |= UInt8(d4); break }   // L_0174d4
            d3 &+= fo
            d4 -= 1
        }
        // L_0174be right lateral scan
        d4 = 3
        while d4 >= 0 {
            if cell(ro) == 2 { d7 |= 0x04; d7 &= 0xfc; d7 |= UInt8(d4); break }   // L_0174e8
            ro &+= fo
            d4 -= 1
        }
        // L_0174f2
        if d6 != 0 {
            if d7 == 0 { d7 = d6 & 3 }                               // L_017512
        } else if d7 != 0 {
            d6 = d7 & 3
        } else {
            // L_017522 plain corridor: walking animation phase
            if mem.r8(a6 + 0x2b) & 1 != 0 { d6 = mem.r8(S1.posX) & 3 } else { d6 = mem.r8(S1.posY) & 3 }
            d7 = d6
        }
        // L_017548
        cpu(S1Cyc.viewSetup)
        mem.w8(S1.viewCodeL, d6)
        s1_drawViewHalf(d6, column: mem.r32(S1.colLeft))
        mem.w8(S1.viewCodeR, d7)
        d7 &+= 0x14
        s1_drawViewHalf(d7, column: mem.r32(S1.colRight))
    }

    /// $1756c draw_viewhalf: d1 = tile map index, a4 = byte column. 10x18 tiles of 8x8, CPU copy.
    func s1_drawViewHalf(_ code: UInt8, column a4: UInt32) {
        var a2 = mem.r32(S1.viewMapTab + UInt32(code) * 4) &+ S1.viewMaps
        let a3 = S1.viewTiles
        cpu(S1Cyc.viewHalfEntry + 18 * S1Cyc.viewRow + 180 * S1Cyc.viewTile)
        for d4 in 0..<18 {
            var a1 = s1_screenAddr(col: 0, row: UInt32(d4)) &+ a4
            for _ in 0..<10 {
                let t = UInt32(mem.r8(a2)); a2 &+= 1
                let a0 = a3 &+ t << 5
                s1_copyCell(from: a0, to: a1)
                a1 &+= 1
            }
        }
    }

    /// The unrolled 32-byte 8x8 cell copy used by $1756c and $17640: 8 rows x 4 planes
    /// (tile row r = 4 bytes plane0..3; destination stride 40, planes $2000 apart).
    @inline(__always) func s1_copyCell(from a0: UInt32, to a1: UInt32) {
        var s = a0
        for r in 0..<8 {
            let d = a1 &+ UInt32(r * 0x28)
            mem.w8(d, mem.r8(s)); mem.w8(d &+ 0x2000, mem.r8(s &+ 1))
            mem.w8(d &+ 0x4000, mem.r8(s &+ 2)); mem.w8(d &+ 0x6000, mem.r8(s &+ 3))
            s &+= 4
        }
    }

    /// $1933c screen_addr: a1 = $62(a6) + rowtab[d2] + d1.b
    @inline(__always) func s1_screenAddr(col d1: UInt32, row d2: UInt32) -> UInt32 {
        let r = mem.r32(S1.charRowTab &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: d2 << 2))))
        return (r &+ (d1 & 0xff)) &+ mem.r32(a6 + 0x62)
    }

    // MARK: $17640 draw_map

    /// $17640 draw_map: player arrow into the maze, 20x18 map window at byte columns 20..39 (only with map),
    /// incremental via the per-buffer tile cache; the saved cell lives in the SMC immediate at $177b5.
    func s1_drawMap() {
        let a0 = S1.maze &+ UInt32(mem.r8(S1.posX)) &+ mem.r32(S1.mazeRowTab + UInt32(mem.r8(S1.posY)) * 4)
        mem.w8(S1.smcMapCell, mem.r8(a0))
        mem.w8(a0, UInt8(truncatingIfNeeded: mem.r16(a6 + 0x2a) &+ 0x21))
        var d4 = mem.r8(S1.posX) &- 0xa
        if d4 & 0x80 != 0 { d4 = 0 } else if Int8(bitPattern: d4) > 0x17 { d4 = 0x17 }
        var d5 = mem.r8(S1.posY) &- 9
        if d5 & 0x80 != 0 { d5 = 0 } else if Int8(bitPattern: d5) > 0x19 { d5 = 0x19 }
        cpu(S1Cyc.mapFixed)
        // ENHANCEMENT M3 (s1.exploredMap; default off): without the map item the window shows the cells seen so far
        let explored = s1e_exploredWindow && mem.r16(a6 + 0x24) == 0
        if explored { s1e_markSeen() }
        if mem.r16(a6 + 0x24) != 0 || explored {
            cpu(18 * S1Cyc.mapRow + 360 * S1Cyc.mapCell)
            var a3 = S1.maze &+ UInt32(d4) &+ mem.r32(S1.mazeRowTab + UInt32(d5) * 4)
            let a2 = S1.mapTiles
            var a4 = mem.r32(S1.mapCachePtrs &+ UInt32(mem.r16(S1.mapCacheIdx)))
            for row in 0..<18 {
                var a1 = s1_screenAddr(col: 0x14, row: UInt32(row))
                for _ in 0..<20 {
                    var d2 = mem.r8(a3); a3 &+= 1
                    if explored && mem.r8(S1E.seen &+ (a3 &- 1 &- S1.maze)) == 0 { d2 = S1E.blankTile }   // ENHANCEMENT M3
                    if d2 != mem.r8(a4) {
                        mem.w8(a4, d2)
                        s1_copyCell(from: a2 &+ UInt32(d2) << 5, to: a1)
                        cpu(S1Cyc.mapCellCopy)
                    }
                    a4 &+= 1; a1 &+= 1
                }
                a3 &+= 0x17
            }
        }
        // L_0177b0: move.b #<smc>,(a0)
        mem.w8(a0, mem.r8(S1.smcMapCell))
    }

    // MARK: $177b8 objects_tunnel

    /// $177b8: run the handlers of tunnel objects 7..0 and draw each still-active one (normal bob blit).
    func s1_objectsTunnel() {
        var a3 = S1.objs + 0x7e
        for _ in 0..<8 {
            cpu(S1Cyc.objSlot)
            if mem.r8(a3) != 0 {
                cpu(S1Cyc.objActive)
                s1_objectHandler(mem.r32(a3 + 0xa), a3)
                if mem.r8(a3) != 0 { s1_drawObject(a3, night: false) }
            }
            a3 &-= 0x12
        }
    }

    /// $177da..$177fe / $17832..: d0 = x<<16|y, a1 = $1e220 + l[l[a3+6] + 8*frame] and blit.
    @inline(__always) func s1_drawObject(_ a3: UInt32, night: Bool) {
        let d0 = UInt32(mem.r16(a3 + 2)) << 16 | UInt32(mem.r16(a3 + 4))
        let a0 = mem.r32(a3 + 6)
        let d2 = UInt32(mem.r8(a3 + 1)) << 3
        let a1 = mem.r32(a0 &+ d2) &+ S1.bobBank
        if night { s1_blitBobNight(d0, a1) } else { s1_blitBobNormal(d0, a1) }
    }

    // MARK: object handlers

    /// $178be h_crosshair (object 0): HELP cheat, input, walking sway.
    func s1_hCrosshair(_ a3: UInt32) {
        if mem.r8(a6 + 0x71) & 2 != 0 && s1_keytest(0x5f) { s1_flareCheatEntry(a3) }
        if s1_inputTunnel(a3) { return }
        if mem.r8(S1.walked) == 0 && mem.r32(a3 + 2) == 0x440078 { return }
        mem.w8(S1.walked, 0)
        let d2 = mem.r16(a3 + 0xe)
        let idx = UInt32(bitPattern: Int32(Int16(bitPattern: d2)))
        let d0 = mem.r16(S1.swayTable &+ idx) &+ 0x24
        let d1 = mem.r16(S1.swayTable &+ 2 &+ idx) &+ 0x68
        let step = mem.r16(a3 + 0x10)
        _ = s1_addW(a3 + 0xe, step)
        if mem.r8(a3 + 0xf) & 0x80 != 0 {
            _ = s1_subW(a3 + 0xe, step)
            mem.w16(a3 + 0x10, 0 &- mem.r16(a3 + 0x10))
        }
        mem.w16(a3 + 2, d0)
        mem.w16(a3 + 4, d1)
    }

    /// $17936 h_flash (object 1, enemy shot): 5 frames, then the player is hit (and obj2 is removed).
    func s1_hFlash(_ a3: UInt32) {
        let e = (mem.r8(a3 + 0xe) &+ 1) & 3
        mem.w8(a3 + 0xe, e)
        if e != 0 { return }
        let f = mem.r8(a3 + 1) &+ 1
        mem.w8(a3 + 1, f)
        if f != 5 { return }
        mem.w8(a3 + 0x13, 0)
        mem.w8(a3 + 1, 0)
        mem.w8(a3 + 0x12, 0)
        mem.w8(a3, 0)
        s1_playerHit()
    }

    /// $17968 h_enemy_walk: far enemy approaching (frames 0,1), then aim.
    func s1_hEnemyWalk(_ a3: UInt32) {
        s1_hitEnemy(a3)
        let e = (mem.r16(a3 + 0xe) &+ 1) & 3
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        let f = mem.r8(a3 + 1) &+ 1
        mem.w8(a3 + 1, f)
        if f != 2 { return }
        mem.w32(a3 + 0xa, 0x17996)
    }

    /// $17996 h_enemy_aim: after 15 ticks fire (object 1 = shot).
    func s1_hEnemyAim(_ a3: UInt32) {
        s1_hitEnemy(a3)
        if s1_addW(a3 + 0xe, 1) != UInt16(truncatingIfNeeded: s1opt.difficulty.enemyAim ?? 0xf) { return }   // ENHANCEMENT M10
        mem.w16(a3 + 0xe, 0)
        mem.w8(a3 &- 0x12, 0xff)
        mem.w16(a3 &- 0x10, mem.r16(a3 + 2))
        mem.w16(a3 &- 0xe, mem.r16(a3 + 4))
        _ = s1_subW(a3 &- 0x10, 5)
        _ = s1_addW(a3 &- 0xe, 0xc)
        mem.w8(a3 + 1, mem.r8(a3 + 1) &+ 1)
        mem.w32(a3 + 0xa, 0x179e4)
        s1_fx(0x83)
    }

    /// $179e4 h_enemy_fired: firing frame for 4 ticks, then back to frame 2 and just hit-testing.
    func s1_hEnemyFired(_ a3: UInt32) {
        s1_hitEnemy(a3)
        let e = (mem.r16(a3 + 0xe) &+ 1) & 3
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        mem.w8(a3 + 1, 2)
        mem.w32(a3 + 0xa, 0x17ba4)
    }

    /// $17a08 h_enemy_die: frames 5..11 (every 2nd tick), sinks into the water at frame 8, +300 at the end.
    func s1_hEnemyDie(_ a3: UInt32) {
        let e = (mem.r16(a3 + 0xe) &+ 1) & 1
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        let f = mem.r8(a3 + 1) &+ 1
        mem.w8(a3 + 1, f)
        if f == 8 { _ = s1_addW(a3 + 4, 0x1e); return }
        if f != 0xc { return }
        mem.w8(a3, 0)
        k_add_score(after: S1.score300End)
    }

    /// $17a4a h_water: water enemy rising (positions/frames from $19cf2/$19d12); at step 5 the player is hit.
    func s1_hWater(_ a3: UInt32) {
        s1_hitWater(a3)
        if s1_addW(a3 + 0xe, 1) != 3 { return }
        mem.w16(a3 + 0xe, 0)
        let c = s1_addW(a3 + 0x10, 1)
        if c == 4 {
            mem.w16(a3 + 0xe, 2)
        } else if c == 5 {
            mem.w8(a3, 0)
            s1_playerHit()
            return
        }
        s1_waterSetStep(a3)
    }

    /// $17a8c / $17ae4: frametab, x, y from the water tables indexed by the step counter at +$10.
    func s1_waterSetStep(_ a3: UInt32) {
        let d0 = UInt32(bitPattern: Int32(Int16(bitPattern: mem.r16(a3 + 0x10) &* 4)))
        mem.w32(a3 + 6, mem.r32(S1.waterFrames &+ d0))
        mem.w16(a3 + 2, mem.r16(S1.waterPos &+ d0))
        mem.w16(a3 + 4, mem.r16(S1.waterPos &+ d0 &+ 2))
    }

    /// $17ab4 h_water_die: sinking animation, +300 at the end.
    func s1_hWaterDie(_ a3: UInt32) {
        let e = (mem.r16(a3 + 0xe) &+ 1) & 3
        mem.w16(a3 + 0xe, e)
        if e != 0 { return }
        let c = (mem.r16(a3 + 0x10) &+ 1) & 7
        mem.w16(a3 + 0x10, c)
        if c == 0 {
            mem.w8(a3, 0)
            k_add_score(after: S1.score300End)
            return
        }
        s1_waterSetStep(a3)
    }

    /// $17b0c h_roomguard (object 4): frames 0,1,2 (12 ticks each), fires once on the 36th tick.
    func s1_hRoomGuard(_ a3: UInt32) {
        s1_hitRoomGuard(a3)
        if mem.r8(a3 + 0x10) != 0 { return }
        if s1_addW(a3 + 0xe, 1) != 0xc { return }
        mem.w16(a3 + 0xe, 0)
        mem.w8(a3 + 1, mem.r8(a3 + 1) &+ 1)
        if s1_addW(a3 + 0x10, 1) != 3 { return }
        mem.w8(a3 &- 0x36, 0xff)
        mem.w16(a3 &- 0x34, mem.r16(a3 + 2))
        mem.w16(a3 &- 0x32, mem.r16(a3 + 4))
        _ = s1_subW(a3 &- 0x34, 5)
        _ = s1_addW(a3 &- 0x32, 0xc)
        s1_fx(0x83)
        mem.w8(a3 + 1, 0)
        mem.w8(a3 + 0x10, 0xff)
        mem.w16(a3 + 0xe, 0)
    }

    /// $17b76 h_roomguard_die: frames 3.., then handler := rts ($1840e), the body stays.
    func s1_hRoomGuardDie(_ a3: UInt32) {
        if s1_addW(a3 + 0xe, 1) != 3 { return }
        mem.w16(a3 + 0xe, 0)
        let f = mem.r8(a3 + 1) &+ 1
        mem.w8(a3 + 1, f)
        if f != 4 { return }
        mem.w32(a3 + 0xa, 0x1840e)
    }

    /// Inclusive box test of the crosshair point (x+9, y+9) used by $17ba4/$17c1c/$17ca6/$192c4
    /// (signed word compares), plus "shot fired" and ammo checks.
    @inline(__always) func s1_crossInBox(cross a0: UInt32, x d2: UInt16, y d3: UInt16, x2 d4: UInt16, y2 d5: UInt16) -> Bool {
        let d0 = Int16(bitPattern: mem.r16(a0 + 2) &+ 9)
        let d1 = Int16(bitPattern: mem.r16(a0 + 4) &+ 9)
        if Int16(bitPattern: d2) > d0 { return false }
        if Int16(bitPattern: d4) < d0 { return false }
        if Int16(bitPattern: d3) > d1 { return false }
        if Int16(bitPattern: d5) < d1 { return false }
        if mem.r8(S1.shotFlag) == 0 { return false }
        // ENHANCEMENT S9c (s1.fixLastBullet; default off): the flag already means a bullet was fired
        if mem.r16(s1_a5 + 2) == 0 && !s1opt.fixLastBullet { return false }
        return true
    }

    /// $17ba4 hit_enemy (corridor enemy box 31x26 at its position). Also used as a handler.
    func s1_hitEnemy(_ a3: UInt32) {
        let x = mem.r16(a3 + 2), y = mem.r16(a3 + 4)
        guard s1_crossInBox(cross: S1.objs, x: x, y: y, x2: x &+ 0x1e, y2: y &+ 0x19) else { return }
        mem.w8(a3 + 1, 5)
        mem.w16(a3 + 0xe, 0)
        mem.w32(a3 + 0xa, 0x17a08)
        s1_fx(0x81)
        mem.w8(S1.enemyHit, 0xff)
    }

    /// $17c1c hit_water: fixed box [60..100]x[64..110].
    func s1_hitWater(_ a3: UInt32) {
        guard s1_crossInBox(cross: S1.objs, x: 0x3c, y: 0x40, x2: 0x64, y2: 0x6e) else { return }
        mem.w16(a3 + 0xe, 3)
        mem.w16(a3 + 0x10, 5)
        mem.w32(a3 + 0xa, 0x17ab4)
        mem.w32(a3 + 6, 0x1e128)
        mem.w16(a3 + 2, 0x32)
        mem.w16(a3 + 4, 0x40)
        s1_fx(0x81)
        mem.w8(S1.enemyHit, 0xff)
    }

    /// $17ca6 hit_roomguard: fixed box [30..62]x[35..69] (no score).
    func s1_hitRoomGuard(_ a3: UInt32) {
        guard s1_crossInBox(cross: S1.objs, x: 0x1e, y: 0x23, x2: 0x3e, y2: 0x45) else { return }
        mem.w16(a3 + 0xe, 0)
        mem.w8(a3 + 1, 3)
        mem.w32(a3 + 0xa, 0x17b76)
        s1_fx(0x81)
        mem.w8(S1.enemyHit, 0xff)
    }

    // MARK: $18330 input_tunnel

    /// $18330 input_tunnel (a3 = crosshair). Returns true where the original pops the caller's return
    /// address (combat and room modes: return from h_crosshair without sway).
    func s1_inputTunnel(_ a3: UInt32) -> S1Popped {
        let d0 = s1_joystick()
        if mem.r8(S1.obj2) != 0 || mem.r8(S1.obj3) != 0 || mem.r8(S1.obj1) != 0 {
            s1_inCombat(a3, d0); return true
        }
        if mem.r8(S1.inRoom) != 0 {
            if mem.r8(S1.obj4) == 0 { s1_inRoom(a3, d0); return true }
            if mem.r8(0x19d7b) != 4 { s1_inCombat(a3, d0); return true }
            s1_inRoom(a3, d0); return true
        }
        // L_018378 corridor navigation
        var skipLatchClear = false
        if d0 & 0x80 != 0 {
            if mem.r8(S1.fireLatch) != 0 {
                skipLatchClear = true
            } else if mem.r16(s1_a5 + 2) != 0 {
                _ = s1_subW(s1_a5 + 2, 1)
                s1_fx(0x82)
            }
        }
        if !skipLatchClear { mem.w8(S1.fireLatch, 0) }
        // L_0183ac
        if d0 & 0x04 != 0 {
            let t = mem.r8(S1.walkToggle) ^ 0xff
            mem.w8(S1.walkToggle, t)
            if t != 0 { s1_moveForward(); return false }
            mem.w8(S1.turnLatch, 0)
            return false
        }
        if d0 & 0x02 != 0 {
            let l = mem.r8(S1.turnLatch)
            mem.w8(S1.turnLatch, l | 0x08)
            if l & 0x08 != 0 { return false }
            mem.w16(a6 + 0x2a, (mem.r16(a6 + 0x2a) &+ 1) & 3)
            return false
        }
        if d0 & 0x08 != 0 {
            let l = mem.r8(S1.turnLatch)
            mem.w8(S1.turnLatch, l | 0x04)
            if l & 0x04 != 0 { return false }
            mem.w16(a6 + 0x2a, (mem.r16(a6 + 0x2a) &- 1) & 3)
            return false
        }
        mem.w8(S1.turnLatch, 0)
        return false
    }

    /// $18410 move_forward: one cell in the facing direction; walls block, room cells enter the room.
    func s1_moveForward() {
        mem.w8(S1.walked, 0xff)
        let saved = mem.r16(S1.posX)                              // move.w $1a0b0,-(a7)
        mem.w8(S1.turnLatch, 0)
        let d0 = UInt32(mem.r16(a6 + 0x2a) << 1)
        let a0 = S1.dirDelta
        let x = mem.r8(S1.posX) &+ mem.r8(a0 &+ d0)
        mem.w8(S1.posX, x)
        if x & 0x80 != 0 {
            mem.w8(S1.posX, 0)                                   // L_018560
        } else if Int8(bitPattern: x) > 0x2a {
            mem.w8(S1.posX, 0x2a)                                // L_01856a
        } else {
            let y = mem.r8(S1.posY) &+ mem.r8(a0 &+ d0 &+ 1)
            mem.w8(S1.posY, y)
            if y & 0x80 != 0 { mem.w8(S1.posY, 0) }
            else if Int8(bitPattern: y) > 0x2a { mem.w8(S1.posY, 0x2a) }
        }
        // L_018464
        let cell = S1.maze &+ UInt32(mem.r8(S1.posX)) &+ mem.r32(S1.mazeRowTab + UInt32(mem.r8(S1.posY)) * 4)
        let v = mem.r8(cell)
        if v == 2 { return }                                     // L_018502: addq.l #2,a7
        if v != 3 { mem.w16(S1.posX, saved); return }            // L_018506 wall
        mem.w8(S1.inRoom, 0xff)
        let pos = mem.r16(S1.posX)
        var d1: UInt32 = 0xfffffffe
        var d2 = 9
        while true {
            d1 = (d1 & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: d1) &+ 2)
            if mem.r16(S1.roomEntries &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: d1)))) == pos { break }
            d2 -= 1
            if d2 == -1 { break }
        }
        // L_0184c0
        let k = UInt16(truncatingIfNeeded: d1)
        mem.w16(S1.roomIndex2, k)
        var t = mem.r16(S1.roomType &+ UInt32(bitPattern: Int32(Int16(bitPattern: k))))
        t = t &+ t
        mem.w16(S1.roomType2, t)
        t = t &+ t
        mem.w32(S1.roomPic, mem.r32(S1.roomPicByType &+ UInt32(bitPattern: Int32(Int16(bitPattern: t)))))
        mem.w16(S1.posBeforeRoom, saved)
        if s1opt.checkpointRespawn { s1e_roomEntered(before: saved) }   // ENHANCEMENT M4 (default off)
        if UInt8(truncatingIfNeeded: d1) != 0 { return }
        mem.w8(S1.obj4, 0xff)                                    // room 0: guard active
        mem.w16(0x19d8a, 0)
    }

    // MARK: $1850e draw_roompic

    /// $1850e draw_roompic: plane-interleaved picture (20 bytes x 144 lines) at byte column $3b3f8.
    func s1_drawRoomPic() {
        var a0 = mem.r32(S1.roomPic)
        var a1 = mem.r32(S1.colLeft) &+ mem.r32(a6 + 0x62)
        let wb = UInt32(mem.r8(a0)), hc = UInt32(mem.r8(a0 &+ 1))
        a0 &+= 2
        // lsr.l #1,d2 ; subi.b #1,d2 / lsl.l #3,d3 ; subi.b #1,d3 ; loops are dbra on the words
        var d2 = wb >> 1; d2 = (d2 & ~0xff) | UInt32(UInt8(d2 & 0xff) &- 1)
        var d3 = hc << 3; d3 = (d3 & ~0xff) | UInt32(UInt8(d3 & 0xff) &- 1)
        let words = Int(d2 & 0xffff) + 1, lines = Int(d3 & 0xffff) + 1
        cpu(S1Cyc.roomFixed + lines * (S1Cyc.roomLine + words * S1Cyc.roomWord))
        var a2 = a1
        for _ in 0..<lines {
            for _ in 0..<words {
                let d0 = mem.r16(a0)
                mem.w16(a1 &+ 0x2000, mem.r16(a0 &+ 2))
                mem.w16(a1 &+ 0x4000, mem.r16(a0 &+ 4))
                mem.w16(a1 &+ 0x6000, mem.r16(a0 &+ 6))
                mem.w16(a1, d0)
                a0 &+= 8; a1 &+= 2
            }
            a2 &+= 0x28; a1 = a2
        }
    }

    // MARK: crosshair control in combat / room

    /// Shared direction code of $185f0/$18686 (bounds x 0..$8d, y 0..$7d; signed word compares).
    @inline(__always) func s1_moveCursorTunnel(_ a3: UInt32, _ d0: UInt8, _ d1: UInt16) {
        if d0 & 0x04 != 0 { if s1_subW(a3 + 4, d1) & 0x8000 != 0 { mem.w16(a3 + 4, 0) } }
        if d0 & 0x01 != 0 { if Int16(bitPattern: s1_addW(a3 + 4, d1)) >= 0x7e { mem.w16(a3 + 4, 0x7d) } }
        if d0 & 0x08 != 0 { if s1_subW(a3 + 2, d1) & 0x8000 != 0 { mem.w16(a3 + 2, 0) } }
        if d0 & 0x02 != 0 { if Int16(bitPattern: s1_addW(a3 + 2, d1)) >= 0x8e { mem.w16(a3 + 2, 0x8d) } }
    }

    /// $1858c in_combat: accelerating crosshair, auto-fire (one shot per tick) with recoil.
    func s1_inCombat(_ a3: UInt32, _ d0in: UInt8) {
        var d0 = d0in
        if s1opt.directAim && s1e_aimAt(a3, .tunnelCombat) { d0 &= 0xf0 }   // ENHANCEMENT L2 (s1.directAim; default off)
        var d1: UInt16 = 0
        if d0 & 0xf == 0 {
            mem.w16(S1.crossSpeed, 2)
        } else {
            d1 = mem.r16(S1.crossSpeed)
            if mem.r16(S1.crossSpeed) < 0xf { _ = s1_addW(S1.crossSpeed, 2) }
        }
        // L_0185c0
        mem.w8(S1.shotFlag, 0)
        var skipLatchClear = false
        if mem.r16(s1_a5 + 2) != 0 && d0 & 0x80 != 0 {
            if mem.r8(S1.fireLatch) != 0 {
                skipLatchClear = true
            } else {
                mem.w8(S1.shotFlag, 0xff)
                s1_shotJitterTunnel(a3)
            }
        }
        if !skipLatchClear { mem.w8(S1.fireLatch, 0) }
        s1_moveCursorTunnel(a3, d0, d1)
    }

    /// $18654 in_room: slower cursor; fire (edge) clicks a hotspot.
    func s1_inRoom(_ a3: UInt32, _ d0in: UInt8) {
        var d0 = d0in
        if s1opt.directAim && s1e_aimAt(a3, .tunnelRoom) { d0 &= 0xf0 }   // ENHANCEMENT L2 (s1.directAim; default off)
        var d1: UInt16 = 0
        if d0 & 0xf == 0 {
            mem.w16(S1.crossSpeed, 4)
        } else {
            d1 = mem.r16(S1.crossSpeed) >> 2
            if mem.r16(S1.crossSpeed) < 0x1f { _ = s1_addW(S1.crossSpeed, 2) }
        }
        s1_moveCursorTunnel(a3, d0, d1)
        if d0 & 0x80 != 0 {
            if mem.r8(S1.shotFlag) == 0 { s1_roomClick(a3) }
        } else {
            mem.w8(S1.shotFlag, 0)
        }
    }

    /// $18706 room_click: find the hotspot under the cursor and run the item handler.
    func s1_roomClick(_ a3: UInt32) {
        mem.w8(S1.shotFlag, 0xff)
        let d1 = UInt8(truncatingIfNeeded: mem.r16(a3 + 2))
        let d2 = UInt8(truncatingIfNeeded: mem.r16(a3 + 4))
        let ti = UInt32(bitPattern: Int32(Int16(bitPattern: mem.r16(S1.roomType2) &* 2)))
        var a0 = mem.r32(S1.hotspotsByType &+ ti)
        let groups = Int(mem.r16(a0)); a0 &+= 2
        var d4: UInt16 = 0xffff
        var found = false
        outer: for _ in 0..<max(groups, 0) {
            let n = Int(mem.r16(a0)); a0 &+= 2
            d4 &+= 1
            for _ in 0..<n {
                if d1 >= mem.r8(a0) && d2 >= mem.r8(a0 &+ 1) && d1 <= mem.r8(a0 &+ 2) && d2 <= mem.r8(a0 &+ 3) {
                    found = true; break outer
                }
                a0 &+= 4
            }
        }
        if !found { return }
        // L_018760
        let ri = UInt32(bitPattern: Int32(Int16(bitPattern: mem.r16(S1.roomIndex2) &* 2)))
        let list = mem.r32(S1.roomItems &+ ri)
        let a4 = list &+ UInt32(bitPattern: Int32(Int16(bitPattern: d4 &* 2)))
        var code = mem.r16(a4)
        if code & 0x80 != 0 {
            let c = code & 0x7f
            code = (c == 5 || c == 0xa || c == 0x11 || c == 0x13) ? 0xb : 6
        }
        let d7 = code
        let handler = mem.r32(S1.itemHandlers &+ UInt32(bitPattern: Int32(Int16(bitPattern: code << 2))))
        s1_fx(0)
        s1_itemHandler(handler, d7: d7, a4: a4, a3: a3)
    }

    /// `jmp (a0)` into the item handler table $199bc. Every handler ends with the pop-return ($18702)
    /// except the successful exit, which enters the flare section.
    func s1_itemHandler(_ addr: UInt32, d7: UInt16, a4: UInt32, a3: UInt32) {
        switch addr {
        case 0x187d6:                       // leave the room
            k_queue_text(d7)
            mem.w16(S1.posX, mem.r16(S1.posBeforeRoom))
            mem.w8(S1.inRoom, 0)
            mem.w8(S1.shotFlag, 0)
            mem.w8(S1.fireLatch, 0xff)
            mem.w8(S1.obj4, 0)
            mem.w16(a6 + 0x2a, (mem.r16(a6 + 0x2a) &+ 2) & 3)
        case 0x18810:                       // map
            k_queue_text(d7)
            if mem.r16(a6 + 0x24) != 0 { k_queue_text(0x1c); return }
            if mem.r32(S1.colLeft) != 0 || !s1e_exploredWindow { s1_mapScrollAnim() }   // ENHANCEMENT M3 (already slid)
            mem.w32(S1.colLeft, 0)
            mem.w32(S1.colRight, 0xa)
            mem.w16(a6 + 0x24, 1)
            s1_hudIcons()
            k_add_score(after: S1.score500End)        // L_018852
        case 0x18862:                       // box of flares
            var d0 = mem.r16(a6 + 0x2c) &+ 5
            if !(Int16(bitPattern: d0) < 8) { d0 = 8 }
            mem.w16(a6 + 0x2c, d0)
            s1_hudIcons()
            s1_itemScoreTaken(d7: d7, a4: a4)
        case 0x18880:                       // +500, taken
            s1_itemScoreTaken(d7: d7, a4: a4)
        case 0x1888c:                       // taken (no score)
            s1_itemTaken(d7: d7, a4: a4)
        case 0x18898:                       // generic message
            k_queue_text(d7)
        case 0x188a4:                       // food: repeatable score
            k_queue_text(d7)
            k_queue_text(0x1d)
            k_add_score(after: S1.score500End)
            if s1opt.fixFoodFarm { mem.w8(a4 + 1, mem.r8(a4 + 1) | 0x80) }   // ENHANCEMENT S9e (default off)
        case 0x188ba:                       // ammo
            if mem.r16(s1_a5 + 2) == 0x90 { k_queue_text(d7); return }
            mem.w16(s1_a5 + 2, 0x90)
            s1_itemScoreTaken(d7: d7, a4: a4)
        case 0x188ce:                       // medical kit
            if mem.r16(s1_a5 + 4) == 0 { k_queue_text(d7); return }
            _ = s1_subW(s1_a5 + 4, 1)
            s1_hudWounds()
            s1_itemScoreTaken(d7: d7, a4: a4)
        case 0x188e6:                       // exit blocked
            k_queue_text(d7)
            k_queue_text(0x1e)
        case 0x188fc:                       // compass
            mem.w16(a6 + 0x26, 1)
            s1_hudIcons()
            s1_itemScoreTaken(d7: d7, a4: a4)
        case 0x1890c:                       // roman empire
            k_queue_text(d7)
            k_queue_text(0x1f)
        case 0x18922:                       // the real EXIT
            s1_tunnelExit(d7: d7, a3: a3)
        default:
            fatalError(String(format: "section 1: no item handler at $%06X", addr))
        }
    }

    /// $18880: +500, then $1888c.
    func s1_itemScoreTaken(d7: UInt16, a4: UInt32) {
        k_add_score(after: S1.score500End)
        s1_itemTaken(d7: d7, a4: a4)
    }

    /// $1888c: mark taken, morale +$200, then the generic message ($18898).
    func s1_itemTaken(d7: UInt16, a4: UInt32) {
        mem.w8(a4 + 1, mem.r8(a4 + 1) | 0x80)
        let add = UInt16(truncatingIfNeeded: s1opt.difficulty.itemMorale ?? 0x200)     // ENHANCEMENT M10
        if s1opt.fixMoraleWrap && UInt32(mem.r16(a6 + 0x2e)) + UInt32(add) > 0xffff {  // ENHANCEMENT S9b (default off)
            mem.w16(a6 + 0x2e, 0xffff)
        } else {
            _ = s1_addW(a6 + 0x2e, add)
        }
        k_queue_text(d7)
    }

    /// $18922 tunnel_exit_handler: needs 8 flares; +30000 and on to the flare section.
    func s1_tunnelExit(d7: UInt16, a3: UInt32) {
        k_queue_text(0xf)
        k_queue_text(d7)
        let flares = mem.r16(a6 + 0x2c)
        if flares < 5 { k_queue_text(0x21); return }             // tunnel_exit_refuse
        if flares < 8 { k_queue_text(0x22); return }
        if mem.r16(a6 + 0x26) == 0 { k_queue_text(0x23) }
        k_add_score(after: S1.score30000End)
        s1_flareEnter(a3)
    }

    /// $1897a recolour_crosshair: crosshair bob (first bob of the bank) := colour 1 (bp0 = mask, bp1-3 = 0).
    func s1_recolourCrosshair() {
        var a0 = S1.bobBank
        let d7 = mem.r32(a0); a0 &+= 4
        let d5 = d7 &+ 0x10001
        let h = d5 & 0xffff
        let psz = UInt16(truncatingIfNeeded: ((d5 >> 16) << 1) & 0xffff) // asl.w #1 on the width word
        let d5p = UInt32(psz) &* h                                       // mulu.w
        let rows = Int(d7 & 0xffff) + 1, cols = Int(d7 >> 16) + 1
        let s = UInt16(truncatingIfNeeded: d5p)
        for _ in 0..<rows {
            for _ in 0..<cols {
                let d0 = mem.r16(a0)
                var d2 = s
                mem.w16(a0 &+ s1_sx(d2), d0); d2 &+= s
                mem.w16(a0 &+ s1_sx(d2), 0); d2 &+= s
                mem.w16(a0 &+ s1_sx(d2), 0); d2 &+= s
                mem.w16(a0 &+ s1_sx(d2), 0)
                a0 &+= 2
            }
        }
    }

    /// sign-extend a word index (68k `(a0,d2.w)`)
    @inline(__always) func s1_sx(_ w: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: w))) }

    /// $18f1a map_scroll_anim: the room picture slides left by 2 bytes per frame when the map is taken.
    func s1_mapScrollAnim() {
        while true {
            k_wait_swap()
            let c = mem.r32(S1.colLeft) &- 2
            mem.w32(S1.colLeft, c)
            if c == 0 { return }
            s1_drawRoomPic()
            s1_swap()
        }
    }

    /// $18f3c shot_jitter_tunnel: ammo -1, gunshot, 4x random recoil (x 0..$8d, y 0..$7d).
    func s1_shotJitterTunnel(_ a3: UInt32) {
        _ = s1_subW(s1_a5 + 2, 1)
        s1_fx(0x83)
        var r = UInt16(truncatingIfNeeded: k_random()) & 7
        if Int16(bitPattern: s1_addW(a3 + 2, r)) >= 0x8e { mem.w16(a3 + 2, 0x8d) }
        r = UInt16(truncatingIfNeeded: k_random()) & 7
        if s1_subW(a3 + 2, r) & 0x8000 != 0 { mem.w16(a3 + 2, 0) }
        r = UInt16(truncatingIfNeeded: k_random()) & 7
        if Int16(bitPattern: s1_addW(a3 + 4, r)) >= 0x7e { mem.w16(a3 + 4, 0x7d) }
        r = UInt16(truncatingIfNeeded: k_random()) & 7
        if s1_subW(a3 + 4, r) & 0x8000 != 0 { mem.w16(a3 + 4, 0) }
    }
}
