import Foundation
// Section 2 engine: the final jungle ($17000-$18865). Spec: re/finaljungle/NOTES.md, listing finaljungle.s.
// Bunker-room specifics, text screens, fades and all endings are in Foxhole.swift.

extension Platoon {

    // MARK: - entry / (re)start / room entry  ($17000-$17116)

    /// $17000 fj_entry: display init, row table, message table, intro text, game screen, 5 men re-initialised.
    func s2_fj_entry() -> Never {
        tickPoint(0x17000)
        k_display_init()
        var d0: UInt32 = 0
        var a0 = S2.rowTable
        cpu(200 * 38)                               // CPU time of the loop (move.l 12 + addi.l 16 + dbra 10)
        for _ in 0...0xc7 {                         // $57b00[i] = i*40, 200 longs
            mem.w32(a0, d0); a0 &+= 4
            d0 &+= 0x28
        }
        mem.w32(a6 &+ 0x4a, S2.msgTable)            // message table for k_queue_text
        k_clear_screens()
        s2_text_screen(S2.txtIntro)                 // "!THE JUNGLE! YOU HAVE TWO MINUTES ..." (no music change)
        s2_game_screen_init()                       // music 5, clear, game palette
        a0 = a6
        mem.w32(a6 &+ 0x1e, a0)
        mem.w16(a6 &+ 0x22, 0)
        for _ in 0...4 {                            // men: grenades 9, ammo $90, hits 0
            mem.w16(a0, 9)
            mem.w16(a0 &+ 2, 0x90)
            mem.w16(a0 &+ 4, 0)
            a0 &+= 6
        }
        s2_fj_restart(a5: a6)
    }

    /// $17068 fj_restart: (re)start of the final jungle with man a5: timer 2:00, hints, HUD, start room.
    /// Also reached after "YOU HAVE ONE MORE CHANCE" (from deep inside the object loop; room_enter resets the stack).
    func s2_fj_restart(a5: UInt32) -> Never {
        tickPoint(0x17068)
        mem.w32(a6 &+ 0x1e, a5)
        let a0 = S2.transStart
        mem.w16(a6 &+ 0x6a, 0x32)                   // timer frame sub-counter
        mem.w16(a6 &+ 0x6c, 0x200)                  // timer 02:00 (BCD mm:ss)
        mem.w32(S2.vHints, mem.r32(S2.hintsInit))   // hints = 00 01 06 07
        var d0: UInt8 = 0
        if mem.r16(a6 &+ 0x26) == 0 { d0 = 0x0b }   // no compass: hint 0 = "A COMPASS WOULD HELP !"
        mem.w8(S2.vHints, d0)
        k_hud_init()
        s2_room_enter(a0)
    }

    /// $170a8 room_enter (a0 = transition routine). `lea $400,a7`: the stack is reset, so this is a non-local
    /// jump (m.jump) from wherever it is called (exits inside obj_player, fj_restart).
    func s2_room_enter(_ a0: UInt32) -> Never {
        m.jump { [unowned self] in self.s2_room_enter_body(a0) }
    }

    /// $170ae.. body of room_enter + room_enter_done ($170f4), then the main loop.
    func s2_room_enter_body(_ transition: UInt32) -> Never {
        var a0: UInt32 = 0x57e20                   // clear $57e20..$58f9f (slots, vars, buckets, blit buffer)
        // CPU time of the three loops below (clr.l (a0)+ / move.l (a0)+,(a1)+ / st.b (a0,d0.w), each + dbra)
        cpu(0x460 * 30 + 45 * 30 + 256 * 28 + 150)
        for _ in 0...0x45f { mem.w32(a0, 0); a0 &+= 4 }
        a0 = S2.slotInit                            // slot init table -> slots 0..9 (46 longs)
        var a1 = S2.slots
        for _ in 0...0x2c { mem.w32(a1, mem.r32(a0)); a0 &+= 4; a1 &+= 4 }
        for d0 in stride(from: 0xff, through: 0, by: -1) { mem.w8(S2.buckets &+ UInt32(d0), 0xff) }
        mem.w8(a6 &+ 0x54, 0)                       // sf.b $54(a6)
        // d0 = 1 (unused by the transition routines); jsr (a0)
        switch transition {
        case S2.transStart: s2_trans_start()
        case S2.transRight: s2_trans_right()
        case S2.transLeft: s2_trans_left()
        default: call(transition)
        }
        // room_enter_done $170f4
        tickPoint(0x170f4)
        mem.w16(S2.vIdleCount, 0x64)
        mem.w16(S2.vSpawnDelay, 0x14)
        mem.w16(S2.vFireCooldown, 0x14)
        mem.w16(S2.vHitSfx, 0x80)
        mem.w8(a6 &+ 0x68, 0xff)                    // st.b $68(a6): timer running
        s2_main_loop()
    }

    // MARK: - main loop  ($17118-$17186)

    /// $17118 main_loop: one iteration per buffer swap (normally 50 Hz; paced by k_wait_swap).
    func s2_main_loop() -> Never {
        while true {
            snapshotPoint(0x17118)                   // savestate point (Game/Snapshot; no-op unless a host asked)
            tickPoint(0x17118)
            s2PaceIndex += 1                         // verification aid only (see s2_paceToReference)
            s2_dbg("head")
            k_hud_update()
            s2_settleCPU()                           // CPU-time model: the HUD's ~50 lines elapse here (the tick
                                                     // head is at ~line 260, so the vblank normally falls inside)
            s2_dbg("hud")
            if mem.r8(a6 &+ 0x71) & 0x02 != 0 {     // MEGA CHEAT: CAPS LOCK = instant win
                if r_keytest(0x62) { s2_game_won() }
            }
            s2_idle_shot_tick()
            s2_soldier_spawn_tick()
            s2_hint_tick()
            s2_dbg("hint")
            s2_paceDiscard()
            k_wait_swap()                            // wait until the previous swap was latched
            if mem.r16(a6 &+ 0x2e) == 0 { s2_morale_zero() }
            let d0 = s2_bg_restore()
            s2_objects_update_draw(d0: d0)
            s2_paceToReference()
            k_swap()
            // CPU-time model: the tick's 68000 time elapses before the timer (changed by the vblank interrupt)
            // is read, so a tick that overruns the frame sees the new value like on the A500.
            cpu(Platoon.s2LoopCycles)
            s2_settleCPU()
            let t = mem.r16(a6 &+ 0x6c)               // timer changed?
            if t == mem.r16(S2.vLastTime) { continue }
            mem.w16(S2.vLastTime, t)
            if mem.r8(a6 &+ 0x6c) == 0 {             // < 1 minute: hint 1 = "NOT LONG BEFORE THE NAPALM"
                mem.w8(S2.vHint1, 5)
            }
            if mem.r16(a6 &+ 0x6c) != 0 { continue }
            s2_time_up()                             // 00:00 -> napalm
        }
    }

    /// $17228 hint_tick: random hint message every 100..227 ticks.
    func s2_hint_tick() {
        let c = mem.r16(S2.vHintCount) &- 1
        mem.w16(S2.vHintCount, c)
        if Int16(bitPattern: c) >= 0 { return }
        var d0 = UInt16(truncatingIfNeeded: k_random())
        d0 = (d0 & 0x7f) &+ 0x64
        mem.w16(S2.vHintCount, d0)
        d0 = UInt16(truncatingIfNeeded: k_random()) & 3
        k_queue_text(UInt16(mem.r8(S2.vHints &+ UInt32(d0))))
    }

    // MARK: - idle shot ("sniper")  ($17332-$17486)

    /// $17342 idle_shot_tick: shot from the side if the player keeps the same depth for $57f5c ticks.
    func s2_idle_shot_tick() {
        if mem.r8(S2.vExits) == 0 { return }         // not in the bunker room
        if mem.r32(S2.vIdleSlot) != 0 { return }     // idle shot already flying
        if mem.r8(S2.vDying) != 0 { return }
        if mem.r16(S2.playerY) >= 0x40 { return }     // unsigned
        if mem.r16(S2.vIdleCount) != 0 {
            let d0 = mem.r16(S2.playerY)
            if d0 != mem.r16(S2.vIdleDepth) {         // idle_reset $17332
                mem.w16(S2.vIdleDepth, d0)
                mem.w16(S2.vIdleCount, 0x32)
                return
            }
            let c = mem.r16(S2.vIdleCount) &- 1
            mem.w16(S2.vIdleCount, c)
            if c != 0 { return }
        }
        // idle_shot_spawn $17390: borrow a free slot of 4..8
        let (a0, found) = s2_find_free_slot(S2.slot4, countMinus1: 4)
        if !found { return }
        mem.w8(a0, 0xff)
        mem.w32(S2.vIdleSlot, a0)
        mem.w32(S2.vIdleSavedGfx, mem.r32(a0 &+ 6))
        mem.w32(S2.vIdleSavedHandler, mem.r32(a0 &+ 0xa))
        mem.w16(S2.vIdleSavedFrame, mem.r16(a0 &+ 0x10))
        mem.w32(a0 &+ 6, S2.gfxIdleShot)
        mem.w32(a0 &+ 0xa, S2.hIdleShot0)
        mem.w8(a0 &+ 1, 0)
        mem.w8(a0 &+ 0x10, 0)
        let d0 = k_random()
        var d2: UInt32 = 0x0008fff9
        var d1: UInt32 = 0x00180110                  // bit1 set: x=$110 dx=-7, else x=$18 dx=+8
        if d0 & 2 == 0 { d1 = d1 << 16 | d1 >> 16; d2 = d2 << 16 | d2 >> 16 }
        mem.w16(a0 &+ 2, UInt16(truncatingIfNeeded: d1))
        mem.w16(a0 &+ 0xe, UInt16(truncatingIfNeeded: d2))
        mem.w16(a0 &+ 4, mem.r16(S2.playerY))
        mem.w16(a0 &+ 4, mem.r16(a0 &+ 4) &+ 0x14)
        s2_sfx(0x82)
    }

    /// $17414 obj_idleshot_h0: first tick of the idle shot, only switches the handler.
    func s2_obj_idleshot_h0(_ a3: UInt32) {
        mem.w32(a3 &+ 0xa, S2.hIdleShot1)
    }

    /// $1741e obj_idleshot_h1: horizontal flight. The original pushes idle_shot_end as return address before
    /// bullet_hits_player: on a hit (which pops its own return) the slot is restored via idle_shot_end.
    func s2_obj_idleshot_h1(_ a3: UInt32, d0: inout UInt16) {
        if s2_bullet_hits_player(a3) { s2_idle_shot_end(); return }
        mem.w32(a3 &+ 6, S2.gfxBullet)
        mem.w8(a3 &+ 1, 0)
        mem.w8(a3 &+ 0x10, 0)
        d0 = mem.r16(a3 &+ 2) &+ mem.r16(a3 &+ 0xe)   // x += dx
        if d0 < 0x10 || d0 >= 0x12c { s2_idle_shot_end(); return }   // unsigned
        mem.w16(a3 &+ 2, d0)
    }

    /// $17458 idle_shot_end: free and restore the borrowed slot.
    func s2_idle_shot_end() {
        let a0 = mem.r32(S2.vIdleSlot)
        mem.w8(a0, 0)
        mem.w32(a0 &+ 6, mem.r32(S2.vIdleSavedGfx))
        mem.w32(a0 &+ 0xa, mem.r32(S2.vIdleSavedHandler))
        mem.w16(a0 &+ 0x10, mem.r16(S2.vIdleSavedFrame))
        mem.w32(S2.vIdleSlot, 0)
        mem.w16(S2.vIdleCount, 0x64)
    }

    // MARK: - soldiers  ($17498-$17556, $17c32-$17cfa, $17f32-$17ffe, $1807a-$1811a)

    /// $17498 soldier_spawn_tick.
    func s2_soldier_spawn_tick() {
        if mem.r8(S2.vDying) != 0 { return }
        if mem.r8(S2.vExits) == 0 { return }         // bunker room: no soldiers
        if mem.r8(S2.vSoldiersLeft) == 0 { return }
        let c = mem.r16(S2.vSpawnDelay) &- 1
        mem.w16(S2.vSpawnDelay, c)
        if Int16(bitPattern: c) >= 0 { return }
        let r = UInt16(truncatingIfNeeded: k_random())
        mem.w16(S2.vSpawnDelay, (r & 0xf) &+ 0x14)   // 20..35
        if Int16(bitPattern: mem.r16(S2.playerY)) > 0x40 { return }
        let (a0, found) = s2_find_free_slot(S2.slot4, countMinus1: 2)
        if !found { return }
        mem.w8(S2.vSoldiersLeft, mem.r8(S2.vSoldiersLeft) &- 1)
        mem.w8(a0, 0xff)
        mem.w32(a0 &+ 0xa, mem.r32(S2.vSoldHandler))
        mem.w8(a0 &+ 0x10, mem.r8(S2.vSoldFrame))
        mem.w16(a0 &+ 0xe, mem.r16(S2.vSoldDx))
        mem.w16(a0 &+ 4, 0x5b)
        let x = mem.r16(S2.vSoldX)
        mem.w16(a0 &+ 2, x)
        if Int16(bitPattern: x) >= 0 { return }
        // T-junction: from the left (x=$5f, frame 0, dx 5) unless the player is left of centre
        mem.w16(a0 &+ 2, 0x5f)
        mem.w8(a0 &+ 0x10, 0)
        mem.w16(a0 &+ 0xe, 5)
        if Int16(bitPattern: mem.r16(S2.playerX)) > 0x64 { return }
        mem.w16(a0 &+ 2, 0xd2)
        mem.w8(a0 &+ 0x10, 5)
        mem.w16(a0 &+ 0xe, 0xfffb)
    }

    /// Common walk of the three soldier handlers: returns the new x and the dx in d0 (for the edge test).
    @inline(__always) private func s2_soldier_walk(_ a3: UInt32) -> (x: Int16, d0: UInt16) {
        mem.w8(a3 &+ 1, mem.r8(a3 &+ 1) &+ 1)       // walk animation
        let d0 = mem.r16(a3 &+ 0xe)
        let x = mem.r16(a3 &+ 2) &+ d0
        mem.w16(a3 &+ 2, x)
        return (Int16(bitPattern: x), d0)
    }

    /// $17c32 obj_soldier_L: soldier in a left-turn room (walks in from the left, back, leaves).
    func s2_obj_soldier_L(_ a3: UInt32, d0: inout UInt16) {
        if s2_soldier_hit_check(a3) { return }
        s2_soldier_fire(a3)
        let (x, dx) = s2_soldier_walk(a3)
        d0 = dx
        if x >= 0x5f && x < 0xd2 { return }
        d0 = 0 &- d0                                 // undo step, reverse
        mem.w16(a3 &+ 2, mem.r16(a3 &+ 2) &+ d0)
        mem.w16(a3 &+ 0xe, d0)
        let f = mem.r8(a3 &+ 0x10) ^ 5
        mem.w8(a3 &+ 0x10, f)
        if f != 0 { return }                         // leaves when back at frame 0
        mem.w8(a3, 0)
        mem.w8(S2.vSoldiersLeft, mem.r8(S2.vSoldiersLeft) &+ 1)
    }

    /// $17c7c obj_soldier_R: soldier in a right-turn room (leaves when the frame becomes 5 again).
    func s2_obj_soldier_R(_ a3: UInt32, d0: inout UInt16) {
        if s2_soldier_hit_check(a3) { return }
        s2_soldier_fire(a3)
        let (x, dx) = s2_soldier_walk(a3)
        d0 = dx
        if x >= 0x5f && x < 0xd2 { return }
        d0 = 0 &- d0
        mem.w16(a3 &+ 2, mem.r16(a3 &+ 2) &+ d0)
        mem.w16(a3 &+ 0xe, d0)
        let f = mem.r8(a3 &+ 0x10) ^ 5
        mem.w8(a3 &+ 0x10, f)
        if f == 0 { return }
        mem.w8(a3, 0)
        mem.w8(S2.vSoldiersLeft, mem.r8(S2.vSoldiersLeft) &+ 1)
    }

    /// $17cc6 obj_soldier_T: soldier in a T-junction room (crosses once).
    func s2_obj_soldier_T(_ a3: UInt32, d0: inout UInt16) {
        if s2_soldier_hit_check(a3) { return }
        s2_soldier_fire(a3)
        let (x, dx) = s2_soldier_walk(a3)
        d0 = dx
        if x >= 0x5f && x < 0xd2 { return }
        mem.w8(a3, 0)
        mem.w8(S2.vSoldiersLeft, mem.r8(S2.vSoldiersLeft) &+ 1)
    }

    /// $1807a soldier_hit_check: player bullets vs soldier a3; dying countdown. Returns true where the original
    /// does `addq.l #4,a7; rts` (skip the rest of the soldier handler).
    func s2_soldier_hit_check(_ a3: UInt32) -> Bool {
        if Int8(bitPattern: mem.r8(a3)) >= 0 {       // soldier_dying $18114: 1..$7f = countdown
            mem.w8(a3, mem.r8(a3) &- 1)
            return true
        }
        let x = mem.r16(a3 &+ 2)
        let d1 = Int16(bitPattern: x &+ 0x1e)
        let d0 = Int16(bitPattern: x &+ 2)
        var a0 = S2.slot1
        for _ in 0...2 {
            defer { a0 &+= S2.slotSize }
            if mem.r8(a0) == 0 { continue }
            if Int16(bitPattern: mem.r16(a0 &+ 4)) < 0x5f { continue }
            let d2 = Int16(bitPattern: mem.r16(a0 &+ 2) &+ 0x10)
            if d0 > d2 { continue }
            if d1 < d2 { continue }
            mem.w8(a3, 4)                            // killed: dying countdown 4
            mem.w8(a3 &+ 1, 0)
            mem.w8(a0, 0)                            // bullet gone
            mem.w8(a3 &+ 0x10, mem.r8(a3 &+ 0x10) &+ 4)
            k_add_score(after: S2.scoreKillEnd)      // +300
            let r = k_random()
            var m: UInt16 = 3                        // "GOOD SHOOTING!" / "THAT'S THE WAY TO DO IT!"
            if r & 1 == 0 { m = 8 }
            k_queue_text(m)
            s2_play_hit_sfx()
            return true
        }
        return false
    }

    /// $17f32 soldier_fire: shared cooldown; aimed shot from a free enemy-bullet slot 7..9.
    func s2_soldier_fire(_ a3: UInt32) {
        if mem.r8(S2.vDying) != 0 { return }
        if mem.r16(S2.vFireCooldown) != 0 {
            mem.w16(S2.vFireCooldown, mem.r16(S2.vFireCooldown) &- 1)
            return
        }
        var a0 = S2.slot7
        for _ in 0...2 {
            if mem.r8(a0) == 0 { s2_soldier_fire_spawn(a0, a3); return }
            a0 &+= S2.slotSize
        }
    }

    /// $17f9e soldier_fire_spawn: a0 = free bullet slot, a3 = soldier. dx = +-(|dx|*4 divu dy).
    func s2_soldier_fire_spawn(_ a0: UInt32, _ a3: UInt32) {
        let d1 = mem.r16(a3 &+ 4) &- mem.r16(S2.playerY)       // soldier depth - player depth
        var d0w = mem.r16(S2.playerX) &- mem.r16(a3 &+ 2)      // player x - soldier x (d0 high word 0)
        if Int16(bitPattern: d0w) < 0 {
            d0w = 0 &- d0w
            if d1 & 0xff == 0 { mem.w8(a0, 0); return }       // fire_cancel (tst.b: only the low byte)
            let q = s2_divu(UInt32(d0w) &* 4, d1)
            d0w = 0 &- UInt16(truncatingIfNeeded: q)
        } else {
            if d1 & 0xff == 0 { mem.w8(a0, 0); return }
            let q = s2_divu(UInt32(d0w) &* 4, d1)
            d0w = UInt16(truncatingIfNeeded: q)
        }
        mem.w16(a0 &+ 0xe, d0w)
        mem.w32(a0 &+ 2, mem.r32(a3 &+ 2))
        mem.w8(a0, 0xff)
        let r = UInt16(truncatingIfNeeded: k_random())
        mem.w16(S2.vFireCooldown, (r & 0xf) &+ 0x14)          // 20..35
        s2_sfx(0x82)
    }

    // MARK: - bullets  ($17c1e, $17cfc-$17d66)

    /// $17c1e obj_pbullet: player bullet, depth += 8, gone at >= $6e.
    func s2_obj_pbullet(_ a3: UInt32) {
        let y = mem.r16(a3 &+ 4) &+ 8
        mem.w16(a3 &+ 4, y)
        if Int16(bitPattern: y) < 0x6e { return }
        mem.w8(a3, 0)
    }

    /// $17cfc obj_ebullet: enemy bullet (slots 7-9). Leaves d0 = dx (matters for the phantom '.' quirk when it
    /// frees its slot).
    func s2_obj_ebullet(_ a3: UInt32, d0: inout UInt16) {
        if s2_bullet_hits_player(a3) { return }    // hit: player_hit ran, handler body skipped
        d0 = mem.r16(a3 &+ 0xe)
        let x = mem.r16(a3 &+ 2) &+ d0
        mem.w16(a3 &+ 2, x)
        if x < 0x140 {                             // unsigned
            let y = mem.r16(a3 &+ 4) &- 4
            mem.w16(a3 &+ 4, y)
            if Int16(bitPattern: y) >= 0 { return }
        }
        mem.w8(a3, 0)
    }

    /// $17d1e bullet_hits_player (a3 = bullet). On a hit the original pops the caller's return address, clears the
    /// bullet and falls into player_hit: returns true after doing so.
    func s2_bullet_hits_player(_ a3: UInt32) -> Bool {
        if mem.r8(S2.vDying) != 0 { return false }
        let d0 = Int16(bitPattern: mem.r16(a3 &+ 2))
        let d1 = Int16(bitPattern: mem.r16(a3 &+ 4))
        let px = mem.r16(S2.playerX), py = mem.r16(S2.playerY)
        let d2 = Int16(bitPattern: px)
        let d3 = Int16(bitPattern: py &+ 8)        // player box x..x+$18, y+8..y+$1c
        let d4 = Int16(bitPattern: px &+ 0x18)
        let d5 = Int16(bitPattern: py &+ 0x1c)
        if d2 > d0 { return false }
        if d4 < d0 { return false }
        if d3 > d1 { return false }
        if d5 < d1 { return false }
        mem.w8(a3, 0)                               // bullet gone
        s2_player_hit()
        return true
    }

    // MARK: - player  ($179fa-$17be0, $1811c-$1816a)

    /// $179fa obj_player: handler of slot 0 (a3 = $57e22). `d0` = the d0 low word left by the object loop.
    func s2_obj_player(_ a3: UInt32, d0 d0In: UInt16) {
        s2_pacePlayer()
        mem.w32(S2.vPlayerSaved, mem.r32(a3 &+ 2))            // saved for blocking objects
        mem.w16(S2.vPathWSaved, mem.r16(S2.vPathW))
        if mem.r8(S2.vExits) == 0 {                           // bunker room
            s2_bunker_goal_check(a3)                          // may not return (won)
            let d0 = (d0In & 0xff00) | 0x39                   // move.b #$39,d0 ('.' key; high byte = leftover)
            if s2_keytest_d0w(d0) {
                if mem.r8(S2.vDotLatch) == 0 {
                    mem.w8(S2.vDotLatch, 0xff)
                    s2_throw_grenade(a3)
                }
            } else {
                mem.w8(S2.vDotLatch, 0)                       // pl_key_released
            }
        }
        // pl_fire_button $17a48
        let j = r_joystick()
        if j & 0x80 == 0 {
            mem.w8(S2.vFireLatch, 0)                          // released: clear latch
        } else if mem.r8(S2.vExits) == 0 {                    // bunker: fire = grenade (latched)
            if mem.r8(S2.vFireLatch) == 0 {
                mem.w8(S2.vFireLatch, 0xff)
                s2_throw_grenade(a3)
            }
        } else if mem.r16(s2_a5 &+ 2) != 0 {                  // pl_fire_gun: rifle if ammo left
            mem.w8(S2.vShotRequest, 0xff)
        }
        s2_pl_move(a3)
    }

    /// $17a92 pl_move: joystick movement, exits, animation frame and size set.
    func s2_pl_move(_ a3: UInt32) {
        let d0 = r_joystick() & 0x0f                          // andi.b #$f,d0
        var d1: UInt16 = 2                                    // depth step
        var d3: UInt8 = 0                                     // anim step
        var d4 = false                                        // vertical movement
        if d0 == 0 {                                          // standing: frame 4 - anim/2
            let d2 = UInt8(4) &- (mem.r8(a3 &+ 1) >> 1)
            mem.w8(a3 &+ 0x10, d2)
        }
        if d0 & 1 != 0 {                                      // DOWN: towards the camera
            d4 = true
            d3 = 1
            mem.w16(S2.vPathW, mem.r16(S2.vPathW) &+ 1)
            let y = mem.r16(a3 &+ 4) &- d1
            mem.w16(a3 &+ 4, y)
            if Int16(bitPattern: y) < 0 {
                mem.w16(S2.vPathW, mem.r16(S2.vPathW) &- 1)
                mem.w16(a3 &+ 4, 0)
            }
        }
        if d0 & 4 != 0 {                                      // UP: into the screen
            d4 = true
            d3 = 0xff
            mem.w16(a3 &+ 4, mem.r16(a3 &+ 4) &+ d1)
            mem.w16(S2.vPathW, mem.r16(S2.vPathW) &- 1)
            if Int16(bitPattern: mem.r16(a3 &+ 4)) >= 0x60 {
                mem.w16(S2.vPathW, mem.r16(S2.vPathW) &+ 1)
                mem.w16(a3 &+ 4, 0x5f)
            }
        }
        d1 = 4                                                // horizontal step
        var d6: UInt8 = 0
        if Int16(bitPattern: mem.r16(a3 &+ 4)) >= 0x5a { d6 = mem.r8(S2.vExits) }   // exits only at the far end
        if d0 & 8 != 0 {                                      // LEFT
            mem.w8(a3 &+ 0x10, 9)
            d3 = 1
            mem.w16(a3 &+ 2, mem.r16(a3 &+ 2) &- d1)
        }
        if d0 & 2 != 0 {                                      // RIGHT
            mem.w8(a3 &+ 0x10, 0)
            d3 = 1
            mem.w16(a3 &+ 2, mem.r16(a3 &+ 2) &+ d1)
        }
        if mem.r8(S2.vShotRequest) != 0 {
            s2_pl_shoot(a3)
            mem.w8(S2.vShotRequest, 0)
        }
        if d4 { mem.w8(a3 &+ 0x10, 0x11) }                    // vertical: frame $11
        // pl_clamp_exit $17b76
        let lo = Int16(bitPattern: 0x64 &- mem.r16(S2.vPathW))
        let hi = Int16(bitPattern: 0xbe &+ mem.r16(S2.vPathW))
        let x = Int16(bitPattern: mem.r16(a3 &+ 2))
        if lo > x {
            if d6 & 1 != 0 { s2_exit_left() }
            mem.w16(a3 &+ 2, UInt16(bitPattern: lo))
        }
        if hi < x {
            if d6 & 2 != 0 { s2_exit_right() }
            mem.w16(a3 &+ 2, UInt16(bitPattern: hi))
        }
        // pl_anim_size $17bb2
        mem.w8(a3 &+ 1, mem.r8(a3 &+ 1) &+ d3)
        let y = Int16(bitPattern: mem.r16(a3 &+ 4))
        if y <= 0x1e { return }
        mem.w8(a3 &+ 0x10, mem.r8(a3 &+ 0x10) &+ 0x15)        // medium size
        if y <= 0x3c { return }
        if Int8(bitPattern: mem.r8(a3 &+ 0x10)) >= 0x26 { return }
        mem.w8(a3 &+ 0x10, mem.r8(a3 &+ 0x10) &+ 0x15)        // far size
    }

    /// $1811c pl_shoot: one rifle bullet (slots 1-3) per fire press.
    func s2_pl_shoot(_ a3: UInt32) {
        if mem.r8(S2.vFireLatch) != 0 { return }
        mem.w8(S2.vFireLatch, 0xff)
        var a0 = S2.slot1
        for _ in 0...2 {
            if mem.r16(a0) == 0 {                             // active and anim byte both 0
                let a5 = s2_a5
                mem.w16(a5 &+ 2, mem.r16(a5 &+ 2) &- 1)       // ammo - 1
                mem.w8(a0, 0xff)
                mem.w32(a0 &+ 2, mem.r32(a3 &+ 2))            // at player x+8, depth+$28
                mem.w16(a0 &+ 2, mem.r16(a0 &+ 2) &+ 8)
                mem.w16(a0 &+ 4, mem.r16(a0 &+ 4) &+ 0x28)
                s2_sfx(0x82)
                return
            }
            a0 &+= S2.slotSize
        }
    }

    // MARK: - hit / death / respawn  ($17d68-$17f02)

    /// $17d68 player_hit: death animation, hits+1, message, wounds, morale -$800, hit sfx.
    func s2_player_hit() {
        // Verification aid (not game logic): the RE test scripts make the player invulnerable by poking an `rts`
        // ($4e75) over the first instruction of player_hit ($17d68, normally $4239). The code bytes are in RAM,
        // so honour that patch exactly like the 68000 would (all callers tolerate an immediate return).
        if mem.r16(0x17d68) == 0x4e75 { return }
        mem.w8(S2.playerAnim, 0)
        mem.w32(S2.playerHandler, S2.hPlayerDying)
        let f = Int8(bitPattern: mem.r8(S2.playerFrame))      // start frame from size/facing (signed byte compares)
        var start: UInt8 = 5
        if f > 4 {
            start = 0x0d
            if f > 0x14 {
                start = 0x1a
                if f > 0x19 {
                    start = 0x22
                    if f > 0x29 {
                        start = 0x2f
                        if f > 0x2e { start = 0x37 }
                    }
                }
            }
        }
        mem.w8(S2.playerFrame, start)
        mem.w8(S2.playerE, start &+ 3)                        // end frame
        mem.w8(S2.playerF, 0)
        mem.w8(S2.vDying, 0xff)
        mem.w16(S2.vIdleCount, 0x64)
        let a5 = s2_a5
        mem.w16(a5 &+ 4, mem.r16(a5 &+ 4) &+ 1)               // hits + 1
        var d0: UInt16 = 0x0a                                 // "YOU'RE HIT"
        if mem.r16(a5 &+ 4) >= 4 { d0 = 9 }                   // "KILLED IN ACTION"
        k_queue_text(d0)
        k_hud_wounds()
        let morale = mem.r16(a6 &+ 0x2e)                      // subi.w #$800; bcc
        mem.w16(a6 &+ 0x2e, morale >= 0x800 ? morale &- 0x800 : 0)
        s2_play_hit_sfx()
    }

    /// $180f6 play_hit_sfx: sfx($57f64), then $57f64 = $80.
    func s2_play_hit_sfx() { s2_sfx_and_reset(mem.r16(S2.vHitSfx)) }

    /// $180fc sfx_and_reset.
    func s2_sfx_and_reset(_ d0: UInt16) {
        s2_sfx(d0)
        mem.w16(S2.vHitSfx, 0x80)
    }

    /// $17e30 obj_player_dying: frame + 1 every 4 ticks until the end frame.
    func s2_obj_player_dying(_ a3: UInt32) {
        let c = (mem.r8(a3 &+ 0xf) &+ 1) & 3
        mem.w8(a3 &+ 0xf, c)
        if c != 0 { return }
        let f = mem.r8(a3 &+ 0x10) &+ 1
        mem.w8(a3 &+ 0x10, f)
        if f != mem.r8(a3 &+ 0xe) { return }
        mem.w32(a3 &+ 0xa, S2.hPlayerDeadWait)
    }

    /// $17e5e obj_player_dead_wait: 8 ticks, then respawn / second man / game over.
    func s2_obj_player_dead_wait(_ a3: UInt32) {
        let c = (mem.r8(a3 &+ 0xf) &+ 1) & 7
        mem.w8(a3 &+ 0xf, c)
        if c != 0 { return }
        mem.w16(S2.vPathW, 0x32)
        mem.w32(a3 &+ 0xa, S2.hPlayer)
        mem.w8(S2.vDying, 0)
        if mem.r16(s2_a5 &+ 4) >= 4 {                          // man dead
            if mem.r16(a6 &+ 0x22) != 0 { s2_all_dead() }
            s2_second_chance()
        }
        // pd_respawn $17ec2
        var a0: UInt32, n: Int
        if mem.r8(S2.vExits) == 0 { a0 = S2.slot7; n = 2 }     // bunker: only Barnes' bullets
        else { a0 = S2.slot1; n = 8 }                          // slots 1-9
        for _ in 0...n { mem.w8(a0, 0); a0 &+= S2.slotSize }
        _ = mem.r32(S2.vIdleSlot)                              // tst.l $57f60 (no effect)
        mem.w16(a3 &+ 4, 0)                                    // back to the entry: depth 0, x $a0
        mem.w16(a3 &+ 2, 0xa0)
    }

    // MARK: - room transitions and setup  ($1816c-$182ac, $17604, $1841a)

    /// $1817e exit_right.
    func s2_exit_right() -> Never { s2_room_enter(S2.transRight) }
    /// $18188 exit_left.
    func s2_exit_left() -> Never { s2_room_enter(S2.transLeft) }

    /// $1816c trans_start: start room, initial heading, compass 0. The room number is the immediate operand of
    /// `move.w #$69,d0` and is read from its place in RAM ($18174), so the RE test pokes keep working.
    func s2_trans_start() {
        let d1 = mem.r32(S2.dirsInit)
        let d0 = mem.r16(S2.startRoomImmediate)
        mem.w16(a6 &+ 0x2a, 0)
        s2_room_setup(room: d0, dirs: d1)
    }

    /// $18192 trans_right: compass + 1, room += R, dirs rol 8.
    func s2_trans_right() {
        mem.w16(a6 &+ 0x2a, (mem.r16(a6 &+ 0x2a) &+ 1) & 3)
        let d0 = mem.r8(S2.vRoom) &+ mem.r8(S2.vDirs)
        let dirs = mem.r32(S2.vDirs)
        s2_room_setup(room: UInt16(d0), dirs: dirs << 8 | dirs >> 24)
    }

    /// $181b4 trans_left: compass - 1, room += L, dirs ror 8.
    func s2_trans_left() {
        mem.w16(a6 &+ 0x2a, (mem.r16(a6 &+ 0x2a) &- 1) & 3)
        let d0 = mem.r8(S2.vRoom) &+ mem.r8(S2.vDirsL)
        let dirs = mem.r32(S2.vDirs)
        s2_room_setup(room: UInt16(d0), dirs: dirs >> 8 | dirs << 24)
    }

    /// $181d2 room_setup: d0 = room, d1 = direction offsets. Room type, exits, picture, soldier pool.
    func s2_room_setup(room d0in: UInt16, dirs d1: UInt32) {
        mem.w32(S2.vDirs, d1)
        mem.w8(S2.vRoom, UInt8(truncatingIfNeeded: d0in))
        mem.w16(0x68, 0)                                        // clr.w $68.l (absolute; harmless original bug)
        let t = mem.r8(S2.map &+ UInt32(d0in & 0xff))           // room type
        mem.w8(S2.vRoomType, t)
        mem.w8(S2.vExits, mem.r8(S2.typeExits &+ UInt32(t)))
        let pic = UInt16(mem.r8(S2.typePic &+ UInt32(t)))
        var n = UInt8(truncatingIfNeeded: k_random()) & 7       // soldiers: 0..5
        if Int8(bitPattern: n) > 5 { n &-= 3 }
        mem.w8(S2.vSoldiersLeft, n)
        mem.w16(S2.vPathW, 0x32)
        let e = UInt32(mem.r8(S2.vExits))
        if e == 0 { s2_room_setup_bunker(pic: pic); return }
        mem.w8(S2.vSoldFrame, mem.r8(S2.exitFrame &+ e &- 1))
        mem.w16(S2.vSoldDx, mem.r16(S2.exitDx &+ e * 2 &- 2))
        mem.w16(S2.vSoldX, mem.r16(S2.exitX &+ e * 2 &- 2))
        mem.w32(S2.vSoldHandler, mem.r32(S2.exitHandler &+ e * 4 &- 4))
        s2_room_load_picture(pic)
    }

    /// $17604 room_load_picture (d0 = 1..10): start the fade-out, RLE-decode the picture to $68000, wait for the
    /// fade, clear screens + palettes, spawn the room's static objects.
    func s2_room_load_picture(_ pic: UInt16) {
        tickPoint(0x17604)
        s2_dbg("loadpic")
        s2_fade_out_start()
        s2_dbg("fadestarted")
        var a2 = S2.background
        var a1 = mem.r32(S2.picTable &+ UInt32(pic << 2) &- 4) &+ S2.pictures
        var cyc = 60                                            // CPU time (68000 cycles) of the decoder
        for _ in 0...3 {                                        // 4 planes of $17c0 bytes
            var a0 = a2
            var d3: UInt16 = 0x17c0
            let esc = mem.r8(a1); a1 &+= 1
            cyc += 32
            var full = false
            while !full {
                let b = mem.r8(a1); a1 &+= 1
                if b != esc {
                    mem.w8(a0, b); a0 &+= 1; d3 &-= 1           // pic_putbyte
                    full = d3 == 0
                    cyc += full ? 78 : 76                       // move/cmp/beq/bsr/putbyte/rts/bne
                } else {                                        // run: value, count (0 = 256)
                    let v = mem.r8(a1), c = mem.r8(a1 &+ 1); a1 &+= 2
                    cyc += 46
                    var d1 = UInt16(c &- 1)                     // dbeq counter (word, high byte 0)
                    while true {
                        mem.w8(a0, v); a0 &+= 1; d3 &-= 1
                        cyc += 46                               // bsr + putbyte + rts
                        if d3 == 0 { full = true; cyc += 12; break }  // dbeq: Z from subq -> stop (rest dropped)
                        if d1 == 0 { cyc += 14; break }
                        d1 &-= 1
                        cyc += 10
                    }
                    cyc += full ? 22 : 20                       // bra + bne
                }
            }
            a2 &+= 0x2000
            cyc += 26
        }
        s2_decode_delay(cycles: cyc)
        tickPoint(0x1764e)
        s2_dbg("decoded")
        s2_fade_wait_loop()
        s2_dbg("fadedone")
        s2_clear_play_and_pal()
        s2_room_spawn_objects()
    }

    /// Timing of the RLE decode above on the A500: the decoder runs for ~3850 raster lines (12.3 frames) while the
    /// vblank interrupts (kernel handler + the fade hook, charged by them via irqCharge) preempt it; HUD updates
    /// (fade_wait_loop) only start after it. `cycles` is the exact Musashi cycle count of the decoder for this
    /// picture (emulator: 17604 -> 1764e = decoder lines + 184..198 interrupt lines for all 10 pictures).
    func s2_decode_delay(cycles: Int) {
        s2_dbg("decode cycles \(cycles)")
        cpu(cycles)
        settleCPU()
    }

    /// $1841a room_spawn_objects: static objects of the room type into slots 10..15.
    func s2_room_spawn_objects() {
        let d0 = UInt32(mem.r8(S2.vRoom))
        let t = UInt32(mem.r8(S2.map &+ d0))
        var a0 = mem.r32(S2.roomLists &+ t * 4)
        var a1 = S2.slot10
        while true {
            let ty = mem.r16(a0); a0 &+= 2
            if Int16(bitPattern: ty) < 0 { return }
            mem.w8(a1, 0xff)
            let o = UInt32(ty << 2)
            mem.w32(a1 &+ 6, mem.r32(S2.objGfx &+ o))
            mem.w32(a1 &+ 0xa, mem.r32(S2.objHandlers &+ o))
            mem.w32(a1 &+ 2, mem.r32(a0)); a0 &+= 4            // x, y
            a1 &+= S2.slotSize
        }
    }

    // MARK: - rendering  ($17558, $1773e-$17808, $17850-$179bc)

    /// $17558 bg_restore: blit the decoded background ($68000, 4 planes, 144 rows) into the back buffer.
    /// Returns d0.w = $2414 (the BLTSIZE value left in d0; the object loop starts with it).
    @discardableResult func s2_bg_restore() -> UInt16 {
        var a0 = S2.background
        var a1 = mem.r32(a6 &+ 0x62)
        let d0: UInt16 = 0x2414                                 // 144 rows x 20 words
        chip.write(0x040, 0x09f0)                               // A -> D
        chip.write(0x042, 0)
        chip.write(0x064, 0)
        chip.write(0x066, 0)
        for _ in 0...3 {
            chip.writeL(0x050, a0)
            chip.writeL(0x054, a1)
            chip.write(0x058, d0)
            a0 &+= 0x2000; a1 &+= 0x2000
        }
        return d0
    }

    /// $1773e objects_update_draw: run the 16 handlers (slot 15..0), insert each still-active object into the
    /// depth buckets (linear probe upwards), then draw far to near ($177a6 objects_draw).
    func s2_objects_update_draw(d0 d0Start: UInt16) {
        var d0 = d0Start
        var a3 = S2.slots &+ 0x10e                              // slot 15
        cpu(24)
        for d7 in stride(from: 15, through: 0, by: -1) {
            if mem.r8(a3) != 0 {
                let h = mem.r32(a3 &+ 0xa)
                cpu(76 + 36 + s2_handlerCycles(h))              // call sequence + handler (CPU-time model)
                s2_run_handler(h, a3: a3, d0: &d0)
                if mem.r8(a3) != 0 {
                    cpu(110)
                    var k = mem.r16(a3 &+ 4)                    // key = y ...
                    if d7 != 0 && (d7 < 4 || (d7 >= 7 && d7 < 0xa)) { k &-= 0x14 }   // ... bullets $14 nearer
                    k &= 0xff
                    while Int8(bitPattern: mem.r8(S2.buckets &+ UInt32(bitPattern: Int32(Int16(bitPattern: k))))) >= 0 {
                        k &+= 1                                  // probe to the first empty ($ff) byte, no bound
                        cpu(40)
                    }
                    mem.w8(S2.buckets &+ UInt32(bitPattern: Int32(Int16(bitPattern: k))), UInt8(d7))
                    d0 = k
                }
            }
            cpu(36)                                             // tst/beq, lea, dbra
            a3 &-= S2.slotSize
        }
        cpu(12 + 256 * 74)                                      // objects_draw: 74 cycles per (empty) bucket
        // objects_draw $177a6: buckets $5808f down to $57f90 (far to near)
        var a0 = S2.bucketsLast
        while a0 != S2.buckets &- 1 {
            let s = mem.r8(a0)
            if Int8(bitPattern: s) >= 0 {
                mem.w8(a0, 0xff)                                // empty the bucket
                let obj = S2.slots &+ UInt32(s) * S2.slotSize
                let pos = mem.r32(obj &+ 2)                     // x<<16 | y
                let dir = mem.r32(obj &+ 6)                     // bob directory
                var yw = UInt16(truncatingIfNeeded: pos) &+ mem.r16(dir &+ 6)
                yw = 0 &- (yw &- 0x8f)                          // screen top = $8f - y - (rows-1 of entry 0)
                let anim = mem.r8(obj &+ 1) & 7
                mem.w8(obj &+ 1, anim)                          // anim &= 7 (stored back)
                let e = (anim >> 1) &+ mem.r8(obj &+ 0x10)      // byte add
                let a1 = mem.r32(dir &+ UInt32(e) << 3) &+ S2.bobData
                cpu(274 + 1248)                                 // bucket fetch/address computation + draw_bob
                s2_draw_bob(a1, pos & 0xffff0000 | UInt32(yw))
            }
            a0 &-= 1
        }
    }

    /// $1780a dead_project: unreferenced perspective helper (dead code in the original, translated for
    /// completeness). Returns d0 = x' << 16 | ($66 + byte +$11 - y) with x' = ((138*(100-y)/100 + 72) * x / 200)
    /// + $24 + $48*y/100 (divu quotients, word arithmetic).
    func s2_dead_project(_ a3: UInt32) -> UInt32 {
        let d0x = mem.r16(a3 &+ 2), d1 = mem.r16(a3 &+ 4)
        var d2: UInt32 = 0x8a
        let d3w = 0x64 &- d1
        d2 = UInt32(UInt16(truncatingIfNeeded: d2)) &* UInt32(d3w)             // mulu.w d3,d2
        d2 = s2_divu(d2, 0x64)
        d2 = (d2 & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: d2) &+ 0x48)
        d2 = UInt32(UInt16(truncatingIfNeeded: d2)) &* UInt32(d0x)             // mulu.w d0,d2
        d2 = s2_divu(d2, 0xc8)
        d2 = (d2 & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: d2) &+ 0x24)
        var d3: UInt32 = 0x48 &* UInt32(d1)                                     // mulu.w d1,d3
        d3 = s2_divu(d3, 0x64)
        let xw = UInt16(truncatingIfNeeded: d2) &+ UInt16(truncatingIfNeeded: d3)
        let lo = (mem.r16(a3 &+ 0x10) & 0xff) &+ 0x66 &- d1
        return UInt32(xw) << 16 | UInt32(lo)
    }

    /// $179be dead_debug_frame: unreferenced debug routine (dead code, translated for completeness): prints ',',
    /// keys $4d/$4b step the object's frame, prints it in hex.
    func s2_dead_debug_frame(_ a3: UInt32) {
        r_putchar(0x2c)
        if r_keytest(0x4d) { mem.w8(a3 &+ 0x10, mem.r8(a3 &+ 0x10) &+ 1) }
        if r_keytest(0x4b) { mem.w8(a3 &+ 0x10, mem.r8(a3 &+ 0x10) &- 1) }
        k_hex8(mem.r8(a3 &+ 0x10))
    }

    /// $17850 draw_bob: a1 = bob header, d0 = x<<16 | screen row. Cookie-cut 4-plane blit into the back buffer
    /// through the buffer $58190 (mask + 4 planes, one extra zero word per row). No clipping.
    func s2_draw_bob(_ a1In: UInt32, _ d0In: UInt32) {
        var a1 = a1In
        // clear the blit buffer: D only, 300 rows x 6 words
        chip.write(0x040, 0x0100)
        chip.write(0x042, 0)
        chip.write(0x064, 0)
        chip.write(0x062, 0)
        chip.write(0x060, 0)
        chip.write(0x066, 0)
        chip.writeL(0x050, 0)
        chip.writeL(0x04c, 0)
        chip.writeL(0x048, 0)
        chip.writeL(0x054, S2.blitBuffer)
        chip.write(0x058, 0x4b06)
        // copy the bob (mask + 4 planes = rows*5 lines x words) with DMOD 2
        var d1 = mem.r32(a1) &+ 0x10001; a1 &+= 4               // words | rows
        var d0w = UInt16(truncatingIfNeeded: d1)
        d0w = d0w &+ d0w
        d0w = d0w &+ d0w
        d0w = d0w &+ UInt16(truncatingIfNeeded: d1)             // rows*5
        d0w = d0w << 6
        d1 = d1 << 16 | d1 >> 16
        d0w |= UInt16(truncatingIfNeeded: d1) & 0x3f
        chip.write(0x066, 2)
        chip.write(0x040, 0x09f0)
        chip.writeL(0x050, a1)
        chip.writeL(0x054, S2.blitBuffer)
        chip.write(0x058, d0w)
        // destination
        let yw = UInt16(truncatingIfNeeded: d0In) << 2           // lsl.w #2 (row table index, sign-extended)
        var a0 = mem.r32(S2.rowTable &+ UInt32(bitPattern: Int32(Int16(bitPattern: yw)))) &+ mem.r32(a6 &+ 0x62)
        let x = UInt16(truncatingIfNeeded: d0In >> 16)
        var d7 = x & 0xf
        a0 &+= UInt32((x >> 3) & 0xfe)                          // byte offset (adda.w of a value <= $fe)
        d1 = mem.r32(a1 &- 4) &+ 0x20001                         // words+1 | rows
        let rows = UInt16(truncatingIfNeeded: d1)
        var d0 = UInt32(rows) << 6                              // lsl.l #6
        d1 = d1 << 16 | d1 >> 16                                // d1.w = words+1
        var d2 = UInt32(rows) * UInt32(UInt16(truncatingIfNeeded: d1))   // mulu.w
        d2 = (d2 & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: d2) &+ UInt16(truncatingIfNeeded: d2))   // add.w
        let w1 = UInt16(truncatingIfNeeded: d1) & 0x3f
        d0 = (d0 & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: d0) | w1)
        let d3 = 0x28 &- (w1 &+ w1)                              // C/D modulo = 40 - 2*(words+1)
        let a1b = S2.blitBuffer                                  // A = mask
        var bpt = a1b
        bpt = (bpt & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: bpt) &+ UInt16(truncatingIfNeeded: d2))   // add.w
        d7 = ((d7 & 0xf) << 12) | 0x0fce                         // D = A ? B : C, A/B shift = x & 15
        let size = UInt16(truncatingIfNeeded: d0)
        chip.write(0x060, d3)
        chip.write(0x066, d3)
        chip.write(0x040, d7)
        chip.write(0x042, d7 & 0xf000)
        chip.writeL(0x050, a1b)
        chip.writeL(0x04c, bpt)
        chip.writeL(0x048, a0)
        chip.writeL(0x054, a0)
        chip.write(0x058, size)
        a0 &+= 0x2000
        for _ in 0..<3 {                                        // planes 1..3: A re-pointed, B continues
            chip.writeL(0x050, a1b)
            chip.writeL(0x048, a0)
            chip.writeL(0x054, a0)
            chip.write(0x058, size)
            a0 &+= 0x2000
        }
    }

    // MARK: - static room objects  ($1846c-$18858)

    /// Common part of the static object handlers: player box [px, px+$e] x [py, py+pdy] against the object box
    /// [x, x+w] x [y, y+d] (signed word compares, in the original's order).
    @inline(__always) private func s2_player_overlaps(_ a3: UInt32, w: UInt16, d: UInt16, pdy: UInt16) -> Bool {
        let px = mem.r16(S2.playerX), py = mem.r16(S2.playerY)
        let d0 = Int16(bitPattern: px), d1 = Int16(bitPattern: py)
        let d2 = Int16(bitPattern: px &+ 0xe), d3 = Int16(bitPattern: py &+ pdy)
        let ox = mem.r16(a3 &+ 2), oy = mem.r16(a3 &+ 4)
        let d4 = Int16(bitPattern: ox), d5 = Int16(bitPattern: oy)
        let d6 = Int16(bitPattern: ox &+ w), d7 = Int16(bitPattern: oy &+ d)
        if d6 < d0 { return false }
        if d4 > d2 { return false }
        if d5 > d3 { return false }
        if d7 < d1 { return false }
        return true
    }

    /// Blocking: undo the player's move of this tick and the path width.
    @inline(__always) private func s2_block_player() {
        mem.w32(S2.playerX, mem.r32(S2.vPlayerSaved))
        mem.w16(S2.vPathW, mem.r16(S2.vPathWSaved))
    }

    /// $1846c obj_s9_log: block, box $46 x $a.
    func s2_obj_s9_log(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0x46, d: 0xa, pdy: 4) { s2_block_player() } }
    /// $184c6 obj_s10_log: block, box $32 x 8.
    func s2_obj_s10_log(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0x32, d: 8, pdy: 4) { s2_block_player() } }
    /// $18520 obj_s11_log: block, box $28 x 6.
    func s2_obj_s11_log(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0x28, d: 6, pdy: 4) { s2_block_player() } }
    /// $1857a obj_s0_rock: block, box $14 x 7.
    func s2_obj_s0_rock(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0x14, d: 7, pdy: 4) { s2_block_player() } }
    /// $185d4 obj_s1_rock: block, box $10 x 5 (type not used by any room).
    func s2_obj_s1_rock(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0x10, d: 5, pdy: 4) { s2_block_player() } }
    /// $1862e obj_s2_rock: block, box $a x 5 (type not used by any room).
    func s2_obj_s2_rock(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0xa, d: 5, pdy: 4) { s2_block_player() } }

    /// $18688 obj_s3_mine: box $a x 4 -> mine_trigger.
    func s2_obj_s3_mine(_ a3: UInt32) { if s2_player_overlaps(a3, w: 0xa, d: 4, pdy: 4) { s2_mine_trigger(a3) } }
    /// $18718 obj_s4_mine: box 6 x 4 (player box +3).
    func s2_obj_s4_mine(_ a3: UInt32) { if s2_player_overlaps(a3, w: 6, d: 4, pdy: 3) { s2_mine_trigger(a3) } }
    /// $18760 obj_s5_mine: box 6 x 4 (player box +3).
    func s2_obj_s5_mine(_ a3: UInt32) { if s2_player_overlaps(a3, w: 6, d: 4, pdy: 3) { s2_mine_trigger(a3) } }

    /// $186cc mine_trigger: explode, sfx $81 for the hit, player_hit.
    func s2_mine_trigger(_ a3: UInt32) {
        s2_obj_to_explosion(a3)
        mem.w16(S2.vHitSfx, 0x81)
        s2_player_hit()
    }

    /// $187a8 obj_s6_wire: barbed wire box $32 x 6 (+3): block + hit.
    func s2_obj_s6_wire(_ a3: UInt32) {
        if s2_player_overlaps(a3, w: 0x32, d: 6, pdy: 3) { s2_block_player(); s2_player_hit() }
    }
    /// $18804 obj_s78_wire: barbed wire box $28 x 4 (+3): block + hit.
    func s2_obj_s78_wire(_ a3: UInt32) {
        if s2_player_overlaps(a3, w: 0x28, d: 4, pdy: 3) { s2_block_player(); s2_player_hit() }
    }
}

extension Platoon {
    /// l3hook_fade $172c2: 16 colours x ~64 cycles + k_set_top_pal + chaining.
    static let s2FadeHookCycles = 1_500
}

extension Platoon {
    func s2_dbg(_ t: String) {
        if s2DebugTiming { FileHandle.standardError.write("DBG \(t) f\(m.frameCount) v\(m.beamLine) cyc \(cpuCycles)\n".data(using: .utf8)!) }
    }
}
let s2DebugTiming = ProcessInfo.processInfo.environment["S2DBG"] != nil

/// Verification aid (not game logic, off by default): S2PACE=<emu tickdump file of $17118 with record length
/// S2PACELEN (hex)> makes main-loop tick n start no earlier than the frame in which the emulator started it, so
/// that frame-based input scripts reach the same ticks in both even where the kernel/audio CPU-time model is not
/// exact yet. Lets the section logic be compared tick by tick under arbitrary (random) input.
let s2PaceFrames: [UInt32] = {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["S2PACE"], let d = FileManager.default.contents(atPath: path) else { return [] }
    let len = Int(env["S2PACELEN"] ?? "270", radix: 16) ?? 0x270
    let b = [UInt8](d)
    var r: [UInt32] = []
    var i = 0
    while i + 4 <= b.count {
        var v = UInt32(b[i + 3]) << 24
        v |= UInt32(b[i + 2]) << 16
        v |= UInt32(b[i + 1]) << 8
        v |= UInt32(b[i])
        r.append(v)
        i += 4 + len
    }
    return r
}()
var s2PaceIndex = 0

/// Verification aid (off by default): S2PACEPL=<file of u32 beam positions (frame*313+line) of the emulator's obj_player
/// ($179fa) calls> additionally holds each obj_player call until the emulator's, so that the joystick is sampled in the
/// same frame as on the A500 (used with S2PACE for frame-by-frame input scripts).
let s2PacePlayer: [UInt32] = {
    guard let path = ProcessInfo.processInfo.environment["S2PACEPL"], let d = FileManager.default.contents(atPath: path) else { return [] }
    let b = [UInt8](d)
    var r: [UInt32] = []
    var i = 0
    while i + 4 <= b.count {
        var v = UInt32(b[i + 3]) << 24
        v |= UInt32(b[i + 2]) << 16
        v |= UInt32(b[i + 1]) << 8
        v |= UInt32(b[i])
        r.append(v)
        i += 4
    }
    return r
}()
var s2PacePlayerIndex = 0

extension Platoon {
    /// settleCPU(), except in the S2PACE verification mode where the emulator's measured pacing replaces the
    /// CPU-time model (pending cycles are dropped).
    func s2_settleCPU() { if s2PaceFrames.isEmpty { settleCPU() } else { cpuCycles = 0 } }
    func s2_paceDiscard() { if !s2PaceFrames.isEmpty { cpuCycles = 0 } }
}

extension Platoon {
    /// S2PACEPL verification aid: wait until the emulator's beam position of this obj_player call.
    func s2_pacePlayer() {
        guard !s2PacePlayer.isEmpty else { return }
        cpuCycles = 0
        if s2PacePlayerIndex < s2PacePlayer.count {
            let t = UInt64(s2PacePlayer[s2PacePlayerIndex])
            while UInt64(m.frameCount) < t / 313 { m.waitVBlank() }
            if UInt64(m.frameCount) == t / 313 && UInt64(m.beamLine) < t % 313 { m.waitLine(Int(t % 313)) }
        }
        s2PacePlayerIndex += 1
    }

    /// Called before k_swap of tick n: waits until the emulator's head position of tick n+1 (the swap request
    /// is what decides the pacing of the next tick).
    func s2_paceToReference() {
        guard !s2PaceFrames.isEmpty else { return }
        cpuCycles = 0
        if s2PaceIndex < s2PaceFrames.count {
            // S2PACELEN=0: file of u32 (frame*313 + line) beam positions (from emu --bp $17118 events)
            let t = UInt64(s2PaceFrames[s2PaceIndex])
            let lineMode = ProcessInfo.processInfo.environment["S2PACELEN"] == "0"
            let target = lineMode ? t / 313 : t
            while m.frameCount < target { m.waitVBlank() }
            if lineMode && m.frameCount == target && UInt64(m.beamLine) < t % 313 { m.waitLine(Int(t % 313)) }
        }
    }
}

// MARK: - CPU-time model of the section's own code (see KernelSupport.swift)
extension Platoon {
    /// Main-loop code outside the object system per tick (spawners, hint tick, tests, bg_restore setup, loop tail).
    static let s2LoopCycles = 700

    /// Approximate 68000 cycles of one call of an object handler (Musashi timings of the typical path).
    func s2_handlerCycles(_ h: UInt32) -> Int {
        switch h {
        case S2.hPlayer: return 900
        case S2.hSoldierL, S2.hSoldierR, S2.hSoldierT: return 450
        case S2.hEnemyBullet, S2.hIdleShot1: return 260
        case S2.hBarnes: return 250
        case S2.hGrenade: return 150
        case S2.hPlayerBullet, S2.hExplosion, S2.hIdleShot0, S2.hPlayerDying, S2.hPlayerDeadWait: return 60
        default: return 190                                     // static room objects: box overlap test
        }
    }
}
