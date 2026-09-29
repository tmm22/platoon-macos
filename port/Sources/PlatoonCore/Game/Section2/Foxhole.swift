// Section 2, bunker room ("foxhole") and the end of the game. Spec: re/foxhole/NOTES.md (+ re/finaljungle).
// Barnes, his aimed shots, grenades (throw / arc / landing / hit / explosion), the win check, the napalm
// time-out, the second chance, the text screens and the palette fades (incl. the level-3 fade hook).

extension Platoon {

    // MARK: - bunker room setup, Barnes  ($18282-$182dc, $17f68-$18078)

    /// $18282 room_setup_bunker: Barnes in slot 4 (active byte = his hit points $32), then the picture.
    func s2_room_setup_bunker(pic d0: UInt16) {
        let a0 = S2.slot4
        mem.w8(a0, 0x32)
        mem.w32(a0 &+ 0xe, 0)                        // +e..+11 = 0 (frame 0)
        mem.w16(a0 &+ 2, 0x96)
        mem.w16(a0 &+ 4, 0x69)
        mem.w32(a0 &+ 0xa, S2.hBarnes)
        mem.w32(a0 &+ 6, S2.gfxBarnes)
        s2_room_load_picture(d0)
    }

    /// $182b0 obj_barnes: shoot, face the player (frame 0 left / 1 centre / 2 right).
    func s2_obj_barnes(_ a3: UInt32) {
        s2_barnes_fire(a3)
        mem.w8(a3 &+ 0x10, 0)
        let px = Int16(bitPattern: mem.r16(S2.playerX))
        if px < 0x82 { return }
        mem.w8(a3 &+ 0x10, 1)
        if px < 0xa0 { return }
        mem.w8(a3 &+ 0x10, 2)
    }

    /// $17f68 barnes_fire: fires when the shared cooldown goes negative.
    func s2_barnes_fire(_ a3: UInt32) {
        if mem.r8(S2.vDying) != 0 { return }
        if Int16(bitPattern: mem.r16(S2.vFireCooldown)) >= 0 {
            mem.w16(S2.vFireCooldown, mem.r16(S2.vFireCooldown) &- 1)
            return
        }
        var a0 = S2.slot7
        for _ in 0...2 {
            if mem.r8(a0) == 0 { s2_barnes_fire_spawn(a0, a3); return }
            a0 &+= S2.slotSize
        }
    }

    /// $18002 barnes_fire_spawn: dx = +-((|px - x| divu ((y - py) lsr 3)) & 15), or +-15 if the divisor's low
    /// byte is 0 (tst.b).
    func s2_barnes_fire_spawn(_ a0: UInt32, _ a3: UInt32) {
        let d1 = (mem.r16(a3 &+ 4) &- mem.r16(S2.playerY)) >> 3      // lsr.w #3 (unsigned)
        var d0w = mem.r16(S2.playerX) &- mem.r16(a3 &+ 2)
        if Int16(bitPattern: d0w) < 0 {
            d0w = 0 &- d0w
            if d1 & 0xff == 0 {
                d0w = 0xfff1                                         // -15
            } else {
                d0w = UInt16(truncatingIfNeeded: s2_divu(UInt32(d0w), d1)) & 0xf
                d0w = 0 &- d0w
            }
        } else {
            if d1 & 0xff == 0 {
                d0w = 0xf
            } else {
                d0w = UInt16(truncatingIfNeeded: s2_divu(UInt32(d0w), d1)) & 0xf
            }
        }
        mem.w16(a0 &+ 0xe, d0w)
        mem.w32(a0 &+ 2, mem.r32(a3 &+ 2))
        mem.w16(a0 &+ 2, mem.r16(a0 &+ 2) &+ 0xe)                   // bullet x = Barnes x + $e
        mem.w8(a0, 0xff)
        let r = UInt16(truncatingIfNeeded: k_random())
        mem.w16(S2.vFireCooldown, (r & 0xf) &+ 0xa)                 // 10..25
        s2_sfx(0x82)
    }

    // MARK: - grenades and explosions  ($182de-$18418, $186dc-$18717)

    /// $182de throw_grenade: slots 10..12, one grenade of the current man.
    func s2_throw_grenade(_ a3: UInt32) {
        var a0 = S2.slot10
        for _ in 0...2 {
            if mem.r8(a0) == 0 {
                // tg_spawn $182f8
                let a5 = s2_a5
                if mem.r16(a5) == 0 { return }                      // no grenades left
                mem.w16(a5, mem.r16(a5) &- 1)
                mem.w16(a0, 0xff00)                                 // active $ff, anim 0
                var d0 = mem.r32(a3 &+ 2)                           // x+$a, depth+$1e
                d0 = (d0 & 0x0000ffff) | UInt32(UInt16(truncatingIfNeeded: d0 >> 16) &+ 0xa) << 16
                d0 = (d0 & 0xffff0000) | UInt32(UInt16(truncatingIfNeeded: d0) &+ 0x1e)
                mem.w32(a0 &+ 2, d0)
                mem.w32(a0 &+ 0xa, S2.hGrenade)
                mem.w32(a0 &+ 6, S2.gfxGrenade)
                mem.w8(a0 &+ 0x10, 0)
                mem.w16(a0 &+ 0xe, 0)
                s2_sfx(0x0a)                                        // throw
                return
            }
            a0 &+= S2.slotSize
        }
    }

    /// $1833a obj_grenade: arc (13 steps), landing, hit test on Barnes. When it vanishes (y u>= $8c) it frees its
    /// slot and leaves d0 = the arc value (object-loop d0 flow).
    func s2_obj_grenade(_ a3: UInt32, d0: inout UInt16) {
        mem.w16(a3 &+ 4, mem.r16(a3 &+ 4) &+ 4)                     // depth += 4 + arc[step]
        let idx = mem.r16(a3 &+ 0xe) << 1                           // asl.w #1
        d0 = mem.r16(S2.grenadeArc &+ UInt32(bitPattern: Int32(Int16(bitPattern: idx))))
        mem.w16(a3 &+ 4, mem.r16(a3 &+ 4) &+ d0)
        if mem.r16(a3 &+ 4) >= 0x8c { mem.w8(a3, 0); return }       // gr_vanish (unsigned): no explosion
        let e = mem.r16(a3 &+ 0xe) &+ 1
        mem.w16(a3 &+ 0xe, e)
        if e != 0xd { return }
        // landing
        var snd: UInt16 = 0x85                                      // miss
        var msg: UInt16 = 0
        let y = mem.r16(a3 &+ 4), x = Int16(bitPattern: mem.r16(a3 &+ 2))
        if Int16(bitPattern: y) >= 0x60 && y < 0x6e && x > 0x9b && x <= 0xaa && mem.r8(S2.slot4) != 0 {
            msg = (UInt16(truncatingIfNeeded: k_random()) & 1) &+ 0xe   // "DIRECT HIT !" / "YOU GOT HIM!"
            snd = 0x81
            let hp = mem.r8(S2.slot4) &- 0xa
            mem.w8(S2.slot4, hp)
            if hp == 0 {                                            // Barnes dead
                k_queue_text(0x10)                                  // "GET TO THE BUNKER - NOW!"
                mem.w8(S2.vKillSfxFlag, 0)
                s2_sfx(0x81)
                mem.w8(S2.vKillSfxFlag, 0xff)
                s2_obj_to_explosion(a3)
                return
            }
        }
        // gr_explode_msg $183e6
        s2_sfx(snd)
        if msg != 0 { k_queue_text(msg) }
        s2_obj_to_explosion(a3)
    }

    /// $186dc obj_to_explosion: turn object a3 into a 4-frame explosion.
    func s2_obj_to_explosion(_ a3: UInt32) {
        mem.w8(a3 &+ 0x10, 0)
        mem.w32(a3 &+ 0xa, S2.hExplosion)
        mem.w32(a3 &+ 6, S2.gfxExplosion)
        mem.w8(a3 &+ 1, 0)
        mem.w8(a3 &+ 0x10, 0)
        mem.w16(a3 &+ 2, mem.r16(a3 &+ 2) &- 0xe)
        mem.w16(a3 &+ 4, mem.r16(a3 &+ 4) &+ 4)
    }

    /// $18706 obj_explosion: frames 0..3, then free.
    func s2_obj_explosion(_ a3: UInt32) {
        let f = mem.r8(a3 &+ 0x10) &+ 1
        mem.w8(a3 &+ 0x10, f)
        if f != 4 { return }
        mem.w8(a3, 0)
    }

    // MARK: - win  ($17be2-$17c1c)

    /// $17be2 bunker_goal_check: Barnes dead and the player at the bunker door -> game_won.
    func s2_bunker_goal_check(_ a3: UInt32) {
        if mem.r8(S2.slot4) != 0 { return }
        let x = Int16(bitPattern: mem.r16(a3 &+ 2))
        if x <= 0x9e { return }
        if x > 0xae { return }
        if Int16(bitPattern: mem.r16(a3 &+ 4)) < 0x5f { return }
        s2_game_won()
    }

    /// $17c0a game_won: "YOU MADE IT! ..." -> k_game_over (also CAPS LOCK with MEGA CHEAT).
    func s2_game_won() -> Never {
        tickPoint(0x17c0a)
        s2_clear_play_and_pal()
        s2_text_screen_music3(S2.txtWon)
        k_game_over()
    }

    // MARK: - endings  ($1718a-$17220, $17e96-$17ebe, $17f04-$17f2c)

    /// $1718a time_up: napalm flash to white, fade out, "YOU DIDN'T MAKE IT! ... NAPALM STRIKE !", game over.
    func s2_time_up() -> Never {
        tickPoint(0x1718a)
        s2_sfx_and_reset(0x81)
        s2_pal_copy_current()
        var d2: UInt16
        repeat {
            var a0 = S2.workPalette
            d2 = 0
            for _ in 0...0xf {
                d2 = 0                                              // clr.w d2 is inside the colour loop:
                                                                    // only colour 15 decides whether to go on
                if (mem.r16(a0) &+ 0x100) & 0xf00 != 0 { d2 = 0x00ff; mem.w16(a0, mem.r16(a0) &+ 0x100) }
                if (mem.r16(a0) &+ 0x010) & 0x0f0 != 0 { d2 = 0x00ff; mem.w16(a0, mem.r16(a0) &+ 0x010) }
                if (mem.r16(a0) &+ 0x001) & 0x00f != 0 { d2 = 0x00ff; mem.w16(a0, mem.r16(a0) &+ 0x001) }
                a0 &+= 2
            }
            k_set_top_pal(S2.workPalette)
            k_wait_vbl(); k_wait_vbl(); k_wait_vbl(); k_wait_vbl()
        } while d2 != 0
        s2_fade_out_wait()
        k_clear_screens()
        s2_text_screen_music3(S2.txtNapalm)
        k_game_over()
    }

    /// $17e96 (in obj_player_dead_wait): man 0 dead -> man 1 takes over, "ONE OF YOUR PLATOON MEMBERS FOLLOWED
    /// YOU ..." and the whole jungle restarts (fj_restart).
    func s2_second_chance() -> Never {
        tickPoint(0x17e96)
        mem.w16(a6 &+ 0x22, mem.r16(a6 &+ 0x22) &+ 1)
        let a5 = a6 &+ 6
        mem.w32(a6 &+ 0x1e, a5)
        k_hud_wounds()
        s2_fade_out_wait()
        s2_clear_play_and_pal()
        s2_text_screen_music3(S2.txtOneMoreChance)
        s2_game_screen_init()
        s2_fj_restart(a5: a5)
    }

    /// $17f04 morale_zero: meant to show "WITHDRAWN FROM ACTION" but a0 is overwritten at $17f22 (original bug):
    /// shows "YOUR PLATOON HAS BEEN DESTROYED!".
    func s2_morale_zero() -> Never {
        tickPoint(0x17f04)
        s2_fade_out_wait()
        k_clear_screens()
        _ = S2.txtWithdrawn                                         // lea d_txt_withdrawn,a0 (overwritten)
        s2_end_text_gameover()
    }

    /// $17f18 all_dead: second man dead.
    func s2_all_dead() -> Never {
        tickPoint(0x17f18)
        s2_fade_out_wait()
        k_clear_screens()
        s2_end_text_gameover()
    }

    /// $17f22 end_text_gameover.
    func s2_end_text_gameover() -> Never {
        s2_text_screen_music3(S2.txtDestroyed)                      // "YOUR PLATOON HAS BEEN DESTROYED! ..."
        k_game_over()
    }

    // MARK: - text screens, palettes  ($176de-$1773c, $17676)

    /// $176de text_screen_music3: tune 3, then text_screen.
    func s2_text_screen_music3(_ a0: UInt32) {
        k_music(3)
        s2_text_screen(a0)
    }

    /// $176ea text_screen: clear both buffers, text palette, print a0, 50 vblanks, wait for fire (no release wait).
    func s2_text_screen(_ a0: UInt32) {
        k_clear_screens()
        k_set_top_pal(S2.palText)
        r_print(a0)
        k_wait_frames(0x31)
        // busy poll of res_joystick in the original; one poll per frame here (input changes only per frame)
        while r_joystick() & 0x80 == 0 { m.waitVBlank() }
    }

    /// $1771e game_screen_init: tune 5 (jungle), clear screens, game palette.
    func s2_game_screen_init() {
        k_music(5)
        k_clear_screens()
        k_set_top_pal(S2.palGame)
    }

    /// $17676 clear_play_and_pal: clear rows 0..143 of the 4 planes of both buffers, game + HUD palettes.
    func s2_clear_play_and_pal() {
        var a0: UInt32 = 0x70000, a1: UInt32 = 0x78000
        for _ in 0...0x59f {
            mem.w32(a0 &+ 0x2000, 0); mem.w32(a0 &+ 0x4000, 0); mem.w32(a0 &+ 0x6000, 0); mem.w32(a0, 0); a0 &+= 4
            mem.w32(a1 &+ 0x2000, 0); mem.w32(a1 &+ 0x4000, 0); mem.w32(a1 &+ 0x6000, 0); mem.w32(a1, 0); a1 &+= 4
        }
        k_set_top_pal(S2.palGame)
        k_set_hud_pal(S2.palHud)
    }

    // MARK: - fades  ($1726a-$17330, $175e8-$17602)

    /// $1726a pal_copy_current: copy the palette at $5a(a6) to $57f70 and set it.
    func s2_pal_copy_current() {
        var a0 = mem.r32(a6 &+ 0x5a), a1 = S2.workPalette
        for _ in 0...7 { mem.w32(a1, mem.r32(a0)); a0 &+= 4; a1 &+= 4 }
        k_set_top_pal(S2.workPalette)
    }

    /// $1728a fade_out_start: copy the palette and hook the level-3 vector with l3hook_fade.
    /// The RAM vector ($6c) and its saved copy ($172ac) are kept like the original; the translated handler is
    /// wrapped in chip.interruptHandlers[3] (the hook runs first, then chains to the previous handler).
    func s2_fade_out_start() {
        s2_pal_copy_current()
        mem.w8(S2.vFadeActive, 0xff)                                // st.b (high byte of the word)
        // (A fade is always over and the hook removed one vblank later, long before the next fade starts, so
        // the hook is never installed twice - as in the original, which would chain to itself.)
        mem.w32(S2.vOldL3Vector, mem.r32(0x6c))
        mem.w32(0x6c, S2.l3HookFade)
        let saved = chip.interruptHandlers[3]
        chip.interruptHandlers[3] = { [unowned self] in self.s2_l3hook_fade(chain: saved) }
    }

    /// $172c2 l3hook_fade (runs on every level-3 interrupt before the kernel's vblank handler): every nonzero
    /// component of $57f70 -1; removes itself one vblank after nothing changed.
    func s2_l3hook_fade(chain: (() -> Void)?) {
        if mem.r16(S2.vFadeActive) == 0 {                           // l3hook_restore $172b0
            mem.w32(0x6c, mem.r32(S2.vOldL3Vector))
            chip.interruptHandlers[3] = chain
            chain?()
            return
        }
        var a0 = S2.workPalette
        var d1: UInt16 = 0
        for _ in 0...0xf {
            let c = mem.r16(a0)
            var d2 = c & 0x00f, d3 = c & 0x0f0, d4 = c & 0xf00
            if d2 != 0 { d2 -= 1; d1 = 0x00ff }
            if d3 != 0 { d3 -= 0x010; d1 = 0x00ff }
            if d4 != 0 { d4 -= 0x100; d1 = 0x00ff }
            mem.w16(a0, d2 | d3 | d4); a0 &+= 2
        }
        mem.w16(S2.vFadeActive, d1)
        k_set_top_pal(S2.workPalette)
        chain?()
    }

    /// $175e8 fade_out_wait: start a fade-out and wait until it is finished (HUD keeps updating).
    func s2_fade_out_wait() {
        s2_fade_out_start()
        s2_fade_wait_loop()
    }

    /// $175ec fade_wait_loop.
    func s2_fade_wait_loop() {
        repeat {
            k_wait_vbl()
            k_hud_update()
        } while mem.r16(S2.vFadeActive) != 0
    }
}
