// Section 0 death / "CHOOSE YOUR MAN" screen ($19518-$1984f), the bridge game over ($19d8c) and the
// fire-button wait ($19850). Spec: re/jungle/NOTES.md §b.10.

extension Platoon {
    static let s0TxtChoose: UInt32 = 0x1a9cd
    static let s0TxtKia: UInt32 = 0x1a9fe          // "KILLED IN ACTION", y byte patched at $1a9ff
    static let s0TxtNumNormal: UInt32 = 0x1aa18    // 5 string pointers
    static let s0TxtNumHilite: UInt32 = 0x1aa5e    // 5 string pointers
    static let s0TxtBridgeGameOver: UInt32 = 0x1a970
    static let s0ManGrenPos: UInt32 = 0x1a158
    static let s0ManAmmoPos: UInt32 = 0x1a16c
    static let s0ManHitsPos: UInt32 = 0x1a180

    /// $19518 man_select: after a death (or Left-Alt): KIA check, choose screen, UP/DOWN, FIRE = continue.
    func s0ManSelect() {
        s0Dbg("019518")
        k_set_top_pal(Platoon.s0PalBlack)
        k_wait_vbl()
        if v0.backBuf != 0x70000 { k_swap() }
        k_wait_swap()
        s0ClearBuf78000()
        var a5 = s0Man
        if mem.r16(a5 &+ 4) == 4 {
            k_queue_text(0x12)                         // KILLED IN ACTION
            a5 = a6
            var d1: UInt16 = 0
            var found = false
            for _ in 0...4 {
                if mem.r16(a5 &+ 4) < 4 { found = true; break }
                a5 &+= 6
                d1 &+= 1
            }
            if !found && enhancements.cheats.infiniteMen {   // ENHANCEMENT CHEAT-MEN (default off): the fallen man
                d1 = mem.r16(a6 &+ 0x22)                     // is patched up instead of the game ending
                cheatPatchUp(s0Man)
                found = true
            }
            if !found { s0Exit() }                     // the whole platoon is dead
            mem.w16(a6 &+ 0x22, d1)
            v0.manHilite = d1
            let off = (UInt32(d1) &* 6) & 0xff         // mulu #6 ; andi.l #$ff
            v0.manPtr = a6 &+ UInt32(UInt16(truncatingIfNeeded: off))
        }
        s0MsDraw()
        s0MsLoop()
    }

    /// $1959c ms_draw: colour-1 box in the other buffer, texts, per-man grenade/ammo bars and hit markers,
    /// then fade the HUD palette in as the upper palette.
    func s0MsDraw() {
        s0Dbg("01959c")
        cpu(Platoon.s0CyclesChooseBox)
        var a0 = ((v0.backBuf ^ 0x8000) & 0xffff_0000) | UInt32(UInt16(truncatingIfNeeded: v0.backBuf ^ 0x8000) &+ 0x28b)
        for _ in 0...0x70 {                            // 113 rows x 18 bytes: plane 0 = $ff, planes 1-3 = 0
            let row = a0
            mem.w8(a0 &+ 0x2000, 0); mem.w8(a0 &+ 0x4000, 0); mem.w8(a0 &+ 0x6000, 0)
            mem.w8(a0, 0xff); a0 &+= 1
            for _ in 0..<4 {
                mem.w32(a0 &+ 0x2000, 0); mem.w32(a0 &+ 0x4000, 0); mem.w32(a0 &+ 0x6000, 0)
                mem.w32(a0, 0xffff_ffff); a0 &+= 4
            }
            mem.w8(a0 &+ 0x2000, 0); mem.w8(a0 &+ 0x4000, 0); mem.w8(a0 &+ 0x6000, 0)
            mem.w8(a0, 0xff)
            a0 = row &+ 0x28
        }
        // ms_text $19626
        s0Dbg("019626")
        r_print(Platoon.s0TxtChoose)
        var a4 = a6
        var d6: UInt16 = 0
        for _ in 0...4 {
            if mem.r16(a4 &+ 4) == 4 {
                mem.w8(0x1a9ff, UInt8(truncatingIfNeeded: d6 &+ d6 &+ 5))
                r_print(Platoon.s0TxtKia)
            } else {
                let hud = mem.r32(0xf884)              // kernel HUD cell graphics
                k_draw_bar(value: mem.r16(a4) &<< 3, gfx: hud &+ 0x40,
                           dest: s0TableLong(Platoon.s0ManGrenPos, d6))
                k_draw_bar(value: mem.r16(a4 &+ 2) >> 1, gfx: hud &+ 0x20,
                           dest: s0TableLong(Platoon.s0ManAmmoPos, d6))
                if mem.r16(a4 &+ 4) != 0 {
                    var a1 = s0TableLong(Platoon.s0ManHitsPos, d6)
                    var d0 = mem.r16(a4 &+ 4) &- 1
                    while true {                       // one red hit marker per hit
                        k_draw_cell(gfx: hud &+ 0x60, dest: a1, mask: 0xff)
                        a1 &+= 1                           // addq.w #1,a1 (address register: 32-bit)
                        if d0 == 0 { break }
                        d0 &-= 1
                    }
                }
            }
            a4 &+= 6
            d6 &+= 1
        }
        s0Dbg("0196f2")
        k_fade_in(target: Platoon.s0PalHud, palVar: a6 &+ 0x5a, setter: .top)
    }

    /// $19710 ms_loop: highlight the current choice, wait for release, then UP/DOWN/FIRE.
    func s0MsLoop() {
        while true {
            s0Dbg("019710")
            r_print(s0TableLong(Platoon.s0TxtNumNormal, v0.manHilite))
            let idx = mem.r16(a6 &+ 0x22)
            v0.manPtr = a6 &+ UInt32(UInt16(truncatingIfNeeded: UInt32(idx) &* 6))
            v0.manHilite = idx
            r_print(s0TableLong(Platoon.s0TxtNumHilite, idx))
            k_hud_wounds()
            // ms_wait_release / ms_wait_input
            var d0: UInt16 = 0
            waitRelease: while true {
                repeat {
                    tickPoint(0x19758)
                    k_wait_vbl(); k_wait_vbl()
                    s0ReadInput()
                } while r_joystick() != 0
                while true {
                    tickPoint(0x19772)
                    k_wait_vbl(); k_wait_vbl()
                    s0ReadInput()
                    let j = r_joystick()
                    if j & 0x80 != 0 {                   // FIRE: continue with this man
                        s0Dbg("01978e")
                        k_hud_wounds()
                        k_queue_text(0x15)               // TAKE CONTROL OF YOUR MAN....
                        v0.explTimer = 0
                        v0.trapxTimer = 0
                        v0.trapState = 0
                        s0ClearBuf78000()
                        let a1 = s0DrawTiles()
                        k_set_top_pal(Platoon.s0PalPlayfield)
                        s0DissolveIn(a1: a1, d4: 0x780)
                        return
                    }
                    let v = UInt16(j & 5)
                    if v == 0 || v == 5 { continue }
                    if j & 4 == 0 {                      // DOWN: next living man (stop at 4)
                        d0 = mem.r16(a6 &+ 0x22)
                        while true {
                            if d0 == 4 { continue waitRelease }
                            d0 &+= 1
                            if !s0ManDead(d0) { break waitRelease }
                            if d0 == 4 { continue waitRelease }
                        }
                    } else {                             // UP: previous living man (stop at 0)
                        d0 = mem.r16(a6 &+ 0x22)
                        while true {
                            if d0 == 0 { continue waitRelease }
                            d0 &-= 1
                            if !s0ManDead(d0) { break waitRelease }
                            if d0 == 0 { continue waitRelease }
                        }
                    }
                }
            }
            mem.w16(a6 &+ 0x22, d0)
        }
    }

    /// $1982e man_alive (really "man dead"): true (d7 = $ff) if man d0 has 4 hits.
    func s0ManDead(_ d0: UInt16) -> Bool {
        let a0 = a6 &+ UInt32(UInt16(truncatingIfNeeded: UInt32(d0) &* 6))
        return mem.r16(a0 &+ 4) == 4
    }

    /// $19850 wait_fire_press: wait (every 2 vblanks) for fire released, then pressed.
    func s0WaitFirePress() {
        repeat {
            tickPoint(0x19850)
            k_wait_vbl(); k_wait_vbl()
            s0ReadInput()
        } while r_joystick() & 0x80 != 0
        repeat {
            tickPoint(0x1986c)
            k_wait_vbl(); k_wait_vbl()
            s0ReadInput()
        } while r_joystick() & 0x80 == 0
    }

    /// $19d8c all_dead: shot by the bridge runner — the whole platoon is wiped out. `a5` is the caller's
    /// a5 register (= $1e(a6), left there by the kernel HUD update in read_input).
    func s0AllDead(a5: UInt32) -> Never {
        mem.w16(a5 &+ 4, 4)
        k_hud_wounds()
        // a1 for the dissolve: k_hud_wounds leaves $797d0; if the message queue was empty, k_queue_text starts
        // printing message $12 and leaves a1 = $797c0 (measured); d4 = $ff from the kernel icon drawing.
        let a1: UInt32 = v0.msgCount == 0 ? 0x797c0 : 0x797d0
        k_queue_text(0x12)
        s0DissolveOut(a1: a1, d4: 0xff)
        k_music(3)
        k_set_top_pal(Platoon.s0PalHud)
        r_print(Platoon.s0TxtBridgeGameOver)
        s0WaitFirePress()
        k_game_over()
    }
}
