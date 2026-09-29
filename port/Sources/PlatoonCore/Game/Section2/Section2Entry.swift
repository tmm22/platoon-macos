// Load section 2 "THE JUNGLE & FOXHOLE SECTIONS" (tracks 111..158 loaded 1:1 to $17000-$58fff).
// Spec: re/finaljungle/NOTES.md (shared engine + final jungle) and re/foxhole/NOTES.md (bunker room, Barnes,
// grenades, all end sequences). Listing: re/finaljungle/finaljungle.s.
//
// Files:
//   Section2Entry.swift  entry, RAM/data addresses, object-handler dispatch, small 68k helpers
//   FinalJungle.swift    main loop, rooms/maze, rendering, player, soldiers, idle shot, static objects, death
//   Foxhole.swift        bunker room: Barnes, grenades, explosions, win check, text screens, fades and endings
//
// Register conventions of the original (kept as documented parameters/locals):
//   a6 = $12dde (kernel globals, `a6`), a3 = current object slot inside handlers (parameter `a3`),
//   a5 = current man record. a5 is always equal to the long at $1e(a6) in this section (fj_entry, fj_restart and
//   the second-chance code set both together), so it is read from there (`s2_a5`).
//
// Non-local exits of the original and how they are translated:
//   * room_enter ($170a8) resets the stack (`lea $400,a7`) and never returns -> `s2_room_enter` uses m.jump.
//     It is reached from deep inside object handlers (exit_left/exit_right in obj_player) and from the
//     second-chance restart.
//   * `addq.l #4,a7` in bullet_hits_player / soldier_hit_check / soldier_dying (return from the CALLER):
//     the callee returns true and the handler returns immediately.
//   * game_won / time_up / morale_zero / all_dead end with `jmp k_game_over` -> `-> Never`.

extension Platoon {
    /// Section-2 RAM / data addresses (all at their original locations).
    enum S2 {
        // object slots: 16 x $12 bytes (+0 active, +1 anim, +2 x, +4 y(depth), +6 bob dir, +a handler, +e w, +10 frame)
        static let slots: UInt32 = 0x57e22
        static let slotSize: UInt32 = 0x12
        static let player: UInt32 = 0x57e22        // slot 0
        static let playerAnim: UInt32 = 0x57e23
        static let playerX: UInt32 = 0x57e24
        static let playerY: UInt32 = 0x57e26
        static let playerHandler: UInt32 = 0x57e2c
        static let playerE: UInt32 = 0x57e30       // +e byte: death end frame
        static let playerF: UInt32 = 0x57e31       // +f byte: tick counter
        static let playerFrame: UInt32 = 0x57e32
        static let slot1: UInt32 = 0x57e34         // player bullets 1..3
        static let slot4: UInt32 = 0x57e6a         // soldiers 4..6 / Barnes (byte 0 = his hit points)
        static let slot7: UInt32 = 0x57ea0         // enemy bullets 7..9
        static let slot10: UInt32 = 0x57ed6        // static room objects / grenades 10..15

        // section variables ($57f42..)
        static let vSoldiersLeft: UInt32 = 0x57f42
        static let vExits: UInt32 = 0x57f44        // exit mask of the room (0 = bunker room)
        static let vRoomType: UInt32 = 0x57f45
        static let vPlayerSaved: UInt32 = 0x57f46  // long x,y at the start of the player's handler
        static let vShotRequest: UInt32 = 0x57f4a
        static let vFireLatch: UInt32 = 0x57f52
        static let vDotLatch: UInt32 = 0x57f53
        static let vDying: UInt32 = 0x57f54
        static let vKillSfxFlag: UInt32 = 0x57f55  // write-only
        static let vHintCount: UInt32 = 0x57f56
        static let vSpawnDelay: UInt32 = 0x57f58
        static let vFireCooldown: UInt32 = 0x57f5a
        static let vIdleCount: UInt32 = 0x57f5c
        static let vIdleDepth: UInt32 = 0x57f5e
        static let vIdleSlot: UInt32 = 0x57f60
        static let vHitSfx: UInt32 = 0x57f64
        static let vIdleSavedGfx: UInt32 = 0x57f66
        static let vIdleSavedHandler: UInt32 = 0x57f6a
        static let vIdleSavedFrame: UInt32 = 0x57f6e
        static let workPalette: UInt32 = 0x57f70
        static let buckets: UInt32 = 0x57f90        // 256 depth-sort buckets ($ff = empty)
        static let bucketsLast: UInt32 = 0x5808f
        static let blitBuffer: UInt32 = 0x58190
        static let rowTable: UInt32 = 0x57b00        // 200 longs i*40
        static let background: UInt32 = 0x68000      // decoded room picture, 4 planes $2000 apart

        // variables inside the code/data block
        static let vLastTime: UInt32 = 0x17226
        static let vFadeActive: UInt32 = 0x172aa
        static let vOldL3Vector: UInt32 = 0x172ac
        static let vHints: UInt32 = 0x189dc
        static let vHint1: UInt32 = 0x189dd
        static let vRoom: UInt32 = 0x18f1c
        static let vDirs: UInt32 = 0x18f40
        static let vDirsL: UInt32 = 0x18f42
        static let vSoldHandler: UInt32 = 0x1900a
        static let vSoldX: UInt32 = 0x1900e
        static let vSoldDx: UInt32 = 0x19010
        static let vPathW: UInt32 = 0x19012
        static let vPathWSaved: UInt32 = 0x19014
        static let vSoldFrame: UInt32 = 0x19016

        // data tables / strings
        static let msgTable: UInt32 = 0x189e0
        static let txtWon: UInt32 = 0x18b5f
        static let txtNapalm: UInt32 = 0x18bb8
        static let txtWithdrawn: UInt32 = 0x18c14
        static let txtIntro: UInt32 = 0x18c6d
        static let txtDestroyed: UInt32 = 0x18ce7
        static let txtOneMoreChance: UInt32 = 0x18d2c
        static let slotInit: UInt32 = 0x18df0
        static let map: UInt32 = 0x18ea4
        static let typePic: UInt32 = 0x18f1d
        static let typeExits: UInt32 = 0x18f2e
        static let dirsInit: UInt32 = 0x18f44
        static let startRoomImmediate: UInt32 = 0x18174  // operand of `move.w #$69,d0` in trans_start
        static let exitFrame: UInt32 = 0x18f48
        static let exitX: UInt32 = 0x18f4c
        static let exitDx: UInt32 = 0x18f52
        static let exitHandler: UInt32 = 0x18f58
        static let picTable: UInt32 = 0x18f9a
        static let pictures: UInt32 = 0x19400
        static let palGame: UInt32 = 0x18fc2
        static let palText: UInt32 = 0x18fe2
        static let palHud: UInt32 = 0x176be
        static let scoreKillEnd: UInt32 = 0x19002     // a0 for k_add_score (BCD 00000300 ends here)
        static let grenadeArc: UInt32 = 0x18400
        static let roomLists: UInt32 = 0x18866
        static let objGfx: UInt32 = 0x188aa
        static let objHandlers: UInt32 = 0x188da
        static let hintsInit: UInt32 = 0x189d8
        static let bobData: UInt32 = 0x47700
        static let keyMatrix: UInt32 = 0x2498          // resident key matrix (for the phantom '.' quirk)

        // code addresses stored as data (handlers in slots, transition routines, level-3 hook)
        static let hPlayer: UInt32 = 0x179fa
        static let hPlayerBullet: UInt32 = 0x17c1e
        static let hSoldierL: UInt32 = 0x17c32
        static let hSoldierR: UInt32 = 0x17c7c
        static let hSoldierT: UInt32 = 0x17cc6
        static let hEnemyBullet: UInt32 = 0x17cfc
        static let hPlayerDying: UInt32 = 0x17e30
        static let hPlayerDeadWait: UInt32 = 0x17e5e
        static let hIdleShot0: UInt32 = 0x17414
        static let hIdleShot1: UInt32 = 0x1741e
        static let hBarnes: UInt32 = 0x182b0
        static let hGrenade: UInt32 = 0x1833a
        static let hExplosion: UInt32 = 0x18706
        static let hLog9: UInt32 = 0x1846c
        static let hLog10: UInt32 = 0x184c6
        static let hLog11: UInt32 = 0x18520
        static let hRock0: UInt32 = 0x1857a
        static let hRock1: UInt32 = 0x185d4
        static let hRock2: UInt32 = 0x1862e
        static let hMine3: UInt32 = 0x18688
        static let hMine4: UInt32 = 0x18718
        static let hMine5: UInt32 = 0x18760
        static let hWire6: UInt32 = 0x187a8
        static let hWire78: UInt32 = 0x18804
        static let transStart: UInt32 = 0x1816c
        static let transRight: UInt32 = 0x18192
        static let transLeft: UInt32 = 0x181b4
        static let l3HookFade: UInt32 = 0x172c2

        // bob directories
        static let gfxIdleShot: UInt32 = 0x476c0
        static let gfxBullet: UInt32 = 0x476a0
        static let gfxBarnes: UInt32 = 0x47628
        static let gfxGrenade: UInt32 = 0x476a8
        static let gfxExplosion: UInt32 = 0x476e0
    }

    /// a5: current man record (6 bytes: +0 grenades, +2 ammo, +4 hits). Always == $1e(a6) in section 2.
    var s2_a5: UInt32 { mem.r32(a6 &+ 0x1e) }

    /// Section entry: `jmp $17000` from k_section_start. Never returns.
    func section2_start() -> Never {
        if config.deterministicRNG { mem.w32(0x12d70, 0x31415926) }   // lockstep mode, see PORTING.md
        s2_registerDispatch()
        s2_fj_entry()
    }

    /// Registers the section's transition routines ($1816c/$18192/$181b4, passed in a0 to room_enter) in the
    /// shared dispatch table. Slot handlers are dispatched by `s2_run_handler` (they need the slot a3 and the
    /// d0 register flow of the object loop, see the phantom '.' quirk) and are never called from elsewhere.
    func s2_registerDispatch() {
        register(S2.transStart) { [unowned self] in self.s2_trans_start() }
        register(S2.transRight) { [unowned self] in self.s2_trans_right() }
        register(S2.transLeft) { [unowned self] in self.s2_trans_left() }
    }

    /// `jsr (a0)` with a0 = handler of the slot at a3 (objects_update_draw $17754). `d0` models the low word of
    /// the 68000's d0 across the object loop: handlers that free their own slot leave their last d0 value in it,
    /// which is what obj_player's `move.b #$39,d0` key test sees (re/foxhole/NOTES.md §h.6).
    func s2_run_handler(_ h: UInt32, a3: UInt32, d0: inout UInt16) {
        switch h {
        case S2.hPlayer: s2_obj_player(a3, d0: d0)
        case S2.hPlayerBullet: s2_obj_pbullet(a3)
        case S2.hSoldierL: s2_obj_soldier_L(a3, d0: &d0)
        case S2.hSoldierR: s2_obj_soldier_R(a3, d0: &d0)
        case S2.hSoldierT: s2_obj_soldier_T(a3, d0: &d0)
        case S2.hEnemyBullet: s2_obj_ebullet(a3, d0: &d0)
        case S2.hPlayerDying: s2_obj_player_dying(a3)
        case S2.hPlayerDeadWait: s2_obj_player_dead_wait(a3)
        case S2.hIdleShot0: s2_obj_idleshot_h0(a3)
        case S2.hIdleShot1: s2_obj_idleshot_h1(a3, d0: &d0)
        case S2.hBarnes: s2_obj_barnes(a3)
        case S2.hGrenade: s2_obj_grenade(a3, d0: &d0)
        case S2.hExplosion: s2_obj_explosion(a3)
        case S2.hLog9: s2_obj_s9_log(a3)
        case S2.hLog10: s2_obj_s10_log(a3)
        case S2.hLog11: s2_obj_s11_log(a3)
        case S2.hRock0: s2_obj_s0_rock(a3)
        case S2.hRock1: s2_obj_s1_rock(a3)
        case S2.hRock2: s2_obj_s2_rock(a3)
        case S2.hMine3: s2_obj_s3_mine(a3)
        case S2.hMine4: s2_obj_s4_mine(a3)
        case S2.hMine5: s2_obj_s5_mine(a3)
        case S2.hWire6: s2_obj_s6_wire(a3)
        case S2.hWire78: s2_obj_s78_wire(a3)
        default:
            fatalError(String(format: "section 2: unknown object handler $%06X in slot $%06X", h, a3))
        }
    }

    // MARK: small 68000 helpers

    /// `divu.w divisor,d` : quotient in the low word, remainder in the high word. On overflow (quotient > $ffff)
    /// the 68000 leaves the destination unchanged. (Division by zero is never reached in this section.)
    @inline(__always) func s2_divu(_ d: UInt32, _ divisor: UInt16) -> UInt32 {
        precondition(divisor != 0, "section 2: divu by zero")
        let q = d / UInt32(divisor), r = d % UInt32(divisor)
        if q > 0xffff { return d }
        return r << 16 | q
    }

    /// $40c res_keytest called with a whole d0.w of which the section only set the low byte (obj_player's
    /// `move.b #$39,d0`). The resident computes index = d0.w with the low byte replaced by (code>>3)&15 and tests
    /// bit (code&7) of the byte at $2498 + index (sign-extended). With a zero high byte this is the normal key
    /// test; otherwise it reads some other RAM byte (the phantom '.' quirk, re/foxhole/NOTES.md §h.6).
    func s2_keytest_d0w(_ d0: UInt16) -> Bool {
        let code = UInt8(truncatingIfNeeded: d0)
        if d0 & 0xff00 == 0 { return r_keytest(code) }
        let index = (d0 & 0xff00) | UInt16((code >> 3) & 0x0f)
        let addr = S2.keyMatrix &+ UInt32(bitPattern: Int32(Int16(bitPattern: index)))
        return mem.r8(addr) & (1 << (code & 7)) != 0
    }

    /// find_free_slot $17488: a0 = first slot, d1 = count-1. `tst.b (a0); lea $12(a0),a0; dbeq d1` then
    /// `lea -$12(a0),a0`. Returns the slot and whether it is free (Z flag).
    func s2_find_free_slot(_ first: UInt32, countMinus1: Int) -> (a0: UInt32, found: Bool) {
        var a0 = first
        var d1 = countMinus1
        while true {
            let z = mem.r8(a0) == 0
            a0 &+= S2.slotSize
            if z { return (a0 &- S2.slotSize, true) }
            d1 -= 1
            if d1 == -1 { return (a0 &- S2.slotSize, false) }
        }
    }

    /// $18860 sfx: `jmp k_fx` (d0 = effect).
    @inline(__always) func s2_sfx(_ d0: UInt16) { k_fx(d0) }
}
