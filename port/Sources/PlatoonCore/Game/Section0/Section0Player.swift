// Section 0 player: state machine ($5f89a, table $1aaa4), fire/grenade input, movement and scrolling,
// level changes. Spec: re/jungle/NOTES.md §b.4, §b.5, §b.9; village states 4-6 in Section0Village.swift.

extension Platoon {
    // MARK: state 0 — stand / walk / crouch; starts jumps, path changes, hut entry

    /// $177ca pl_st0_walk.
    func s0PlSt0Walk() {
        v0.px = 0x94; v0.py = 0x50                       // the player never moves on screen
        if v0.align != 0 { s0PlKeepWalking(); return }
        if enhancements.section0.explicitJumpCrouch { s0M14Walk(); return }   // ENHANCEMENT M14 (default off)
        let d0 = UInt16(v0.input) & 5
        if d0 == 0 || d0 == 5 { s0PlHorizontal(); return }
        let a0 = v0.pmapptr
        if d0 & 1 == 0 { s0PlUpPressed(); return }
        // DOWN
        if mem.r8(a0) != 4 { s0PlCrouch(); return }       // not a down-path tile
        let d = s0Abs(v0.c34)
        if !(d < 3) && d < 6 { s0PlCrouch(); return }
        // pl_start_down $17824
        v0.savefacing = v0.pfacing
        v0.pstate = 2
        v0.pathofs = 0
        v0.pcnt = 0
        s0AlignClearC32()
    }

    /// $17846 pl_crouch.
    func s0PlCrouch() { v0.pframe = 0xa }

    /// $174c8 align_clear_c32: `andi.w #8,$60c32`.
    func s0AlignClearC32() { v0.align &= 8 }

    /// $17850 pl_up_path (UP on levels 1-4).
    func s0PlUpPath() {
        if mem.r8(v0.pmapptr) != 3 { s0PlStartJump(); return }
        let d = s0Abs(v0.c34)
        if !(d < 3) && d < 6 { s0PlStartJump(); return }
        // pl_start_up $17878
        v0.savefacing = v0.pfacing
        v0.pstate = 3
        v0.pathofs = 0xffff
        s0AlignClearC32()
    }

    /// $17896 pl_start_jump, falls into pl_horizontal.
    func s0PlStartJump() {
        v0.pcnt = 0
        v0.pstate = 1
        v0.jumpInput = v0.input
        s0PlHorizontal()
    }

    /// $178ae pl_horizontal.
    func s0PlHorizontal() { s0PlHorizDir(v0.input) }

    /// $178b4 pl_horiz_dir (d0.b = input bits).
    func s0PlHorizDir(_ input: UInt8) {
        let d0 = input & 0xa
        if d0 == 0 || d0 == 0xa { s0PlStandFrame(); return }
        v0.lastdir = d0
        s0PlMove(d0)
    }

    /// $178ce pl_keep_walking: finish the 8-px step in the last direction.
    func s0PlKeepWalking() { s0PlHorizDir(v0.lastdir) }

    /// $178d8 pl_stand_frame.
    func s0PlStandFrame() { v0.pframe = 8 }

    /// $178e2 pl_up_pressed: level 0 = hut doors, else up-paths; otherwise jump.
    func s0PlUpPressed() {
        if v0.level != 0 { s0PlUpPath(); return }
        let (fail, d1) = s0HutDoorCheck()
        if fail { s0PlStartJump(); return }
        v0.hut = d1
        v0.savefacing = v0.pfacing
        v0.pathofs = 0x18
        v0.pstate = 4
    }

    // MARK: state 1 — jump

    /// $17918 pl_st1_jump: 16 ticks along the jump arc; horizontal bits frozen at take-off.
    func s0PlSt1Jump() {
        let inp = (v0.input & 0xb5) | v0.jumpInput
        v0.input = inp
        let d0 = inp & 0xa
        if d0 != 0 && d0 != 0xa { s0PlMove(d0) }
        // pj_arc
        v0.pframe = 0xc
        v0.py = 0x50 &- mem.r16(Platoon.s0JumpArc &+ UInt32(v0.pcnt &<< 1))
        v0.pcnt = (v0.pcnt &+ 1) & 0xf
        if v0.pcnt != 0 { return }
        v0.pstate = 0
        v0.pframe = 0
    }

    // MARK: states 2/3 — walk down/up a side path

    /// $17986 pl_st2_down: to level+1.
    func s0PlSt2Down() {
        v0.pcnt = (v0.pcnt &+ 1) & 3
        v0.pframe = v0.pcnt &+ 0xd
        v0.pfacing = 0
        v0.pathofs = v0.pathofs &+ 2
        if v0.pathofs == 0 { s0PlPathDone(); return }
        v0.py = v0.pathofs &+ 0x50
        if v0.py < 0x68 { return }
        v0.pathofs = 0xffe8
        v0.level = v0.level &+ 1
        s0PlLevelChanged()
    }

    /// $179e6 pl_st3_up: to level-1.
    func s0PlSt3Up() {
        v0.pcnt = (v0.pcnt &+ 1) & 3
        v0.pframe = v0.pcnt &+ 0x11
        v0.pathofs = v0.pathofs &- 2
        if v0.pathofs == 0 { s0PlPathDone(); return }
        v0.py = v0.pathofs &+ 0x50
        if v0.py >= 0x38 { return }
        v0.pathofs = 0x18
        v0.level = v0.level &- 1
        s0PlLevelChanged()
    }

    /// $17a3c pl_level_changed, falls into level_enter.
    func s0PlLevelChanged() {
        s0EnemyReset()
        s0KillPlayerBullets()
        s0TrapClear()
        s0LevelEnter()
    }

    /// $17a48 level_enter: palette colour 6 per level, reload palette, player position, attribute map.
    func s0LevelEnter() {
        var d1: UInt16 = 0x0ca2
        if v0.level != 0 && v0.level != 5 { d1 = 0x000d }
        mem.w16(0x1a004, d1)
        if v0.topPalPtr == Platoon.s0PalPlayfield { k_set_top_pal(Platoon.s0PalPlayfield) }
        s0CalcPlayerPos()
        s0BuildAttrMap()
    }

    /// $17a88 kill_player_bullets.
    func s0KillPlayerBullets() {
        var a0: UInt32 = 0x60c48
        for _ in 0...2 { s0BulletKill(a0); a0 &+= 6 }
        v0.grenadeBusy = 0
    }

    /// $17aa4 pl_path_done.
    func s0PlPathDone() {
        v0.pfacing = v0.savefacing
        v0.pstate = 0
        v0.pframe = 0
    }

    // MARK: state 7 — grenade throw

    /// $17ee8 pl_st7_throw.
    func s0PlSt7Throw() {
        v0.pcnt = v0.pcnt &- 1
        if v0.pcnt != 0 { return }
        v0.pcnt = 2
        v0.pframe = v0.pframe &+ 1
        if v0.pframe == 0x30 { s0GrenadeLaunch(); return }
        if v0.pframe < 0x31 { return }
        v0.pframe = 8
        v0.pstate = 0
    }

    /// $17f28 grenade_launch: grenade {y $50, x $98/$90, dx +/-$e}.
    func s0GrenadeLaunch() {
        mem.w16(0x60c5a + 2, 0x50)
        let d0: UInt32 = v0.pfacing == 0 ? 0x000e_0098 : 0xfff2_0090
        mem.w16(0x60c5a + 0, UInt16(truncatingIfNeeded: d0))
        mem.w16(0x60c5a + 4, UInt16(d0 >> 16))
    }

    // MARK: state 8 — hit / dying

    /// $17f56 pl_st8_hit.
    func s0PlSt8Hit() {
        if v0.pcnt == 0 { s0PhDone(); return }
        let d0 = v0.pcnt
        v0.pcnt = v0.pcnt &- 1
        let d1: UInt16 = v0.level == 5 ? 0x3d : 0x50
        // ph_arc: i = 16 reads the word after the jump table ($1a1b4 = 0)
        v0.py = d1 &- (mem.r16(Platoon.s0JumpArc &+ UInt32(d0 &<< 1)) >> 2)
        if v0.pcnt >= 6 { return }
        v0.pframe = 0x32
        if v0.pcnt >= 3 { return }
        v0.pframe = 0x33
    }

    /// $17fc2 ph_done: end of the hit animation.
    func s0PhDone() {
        s0Dbg("017fc2")
        if v0.blastflag != 0 {                   // bridge-blast knock-back: no damage
            v0.pstate = 0
            v0.blastflag = 0
            return
        }
        // ph_lose_man
        if v0.estate == 8 {
            // all_dead uses the caller's a5 = $1e(a6), loaded by the kernel HUD update (read_input).
            s0AllDead(a5: s0Man)
        }
        k_queue_text(0xe)                        // "YOU'RE HIT"
        let a5 = s0Man
        mem.w16(a5 + 4, mem.r16(a5 + 4) &+ 1)
        if mem.r16(a5 + 4) >= 5 { mem.w16(a5 + 4, 4) }
        s0MoraleSub(UInt16(enhancements.section0.difficulty.hitMorale ?? 0x800))   // ENHANCEMENT M10 (nil = $800)
        k_hud_wounds()
        s0DissolveOut(a1: Platoon.s0DissolveA1AfterHudWounds, d4: Platoon.s0DissolveD4AfterHudWounds)
        if v0.morale == 0 { s0Exit() }
        v0.pstate = 5
        if v0.level != 5 { v0.pstate = 0 }
        s0EnemyReset()
        v0.pframe = 8
        s0KillPlayerBullets()
        s0ManSelect()
    }

    // MARK: states 9/10 — bridge

    /// $18050 pl_st9_blocked: frozen at the un-blown bridge.
    func s0PlSt9Blocked() {
        if v0.py >= 0x50 {
            v0.py = 0x50
            v0.pframe = 8
            return
        }
        v0.py = v0.py &+ 8
    }

    /// $18076 pl_st10_plant: land, kneel 5 ticks, then forced walk right.
    func s0PlSt10Plant() {
        if v0.py != 0x50 {
            v0.py = v0.py &+ 8
            if v0.py < 0x50 { return }
            v0.py = 0x50
            return
        }
        if v0.pcnt != 0 {
            v0.pcnt = v0.pcnt &- 1
            v0.pframe = 0xa
            v0.pfacing = 0
            return
        }
        v0.input = (v0.input & ~0x08) | 0x02
        s0PlMove(v0.input)
    }

    // MARK: fire / grenade input

    /// $1736a player_fire_input: FIRE = rifle (auto-fire every 2 ticks), SPACE alone = grenade.
    func s0PlayerFireInput() {
        if v0.pstate != 0 {
            if v0.pstate != 5 { return }
            if v0.pframe >= 0xc { return }
            s0PfFire()
            return
        }
        if v0.input & 0x10 != 0 { s0PfGrenade(); return }
        s0PfFire()
    }

    /// $1739c pf_fire.
    func s0PfFire() {
        if v0.input & 0x80 == 0 { return }
        if v0.firecool != 0 { return }
        let a5 = s0Man
        if mem.r16(a5 + 2) == 0 { return }
        var a0: UInt32 = 0x60c48
        var found = false
        for _ in 0...2 {
            if mem.r16(a0) == 0 { found = true; break }
            a0 &+= 6
        }
        if !found { return }
        // pf_spawn_bullet $173d6
        v0.firecool = 2
        mem.w16(a0 + 2, v0.py)
        let d0: UInt16 = v0.pframe < 0xa ? 7 : 0xe
        mem.w16(a0 + 2, mem.r16(a0 + 2) &+ d0)
        let xd: UInt32 = v0.pfacing == 0 ? 0x000a_0098 : 0xfff6_0090
        mem.w16(a0 + 0, UInt16(truncatingIfNeeded: xd))
        mem.w16(a0 + 4, UInt16(xd >> 16))
        s0Sfx(0x82)
        if v0.dx == 0 {                          // firing pose only when not moving
            v0.firetoggle ^= 1
            v0.pframe = v0.pframe &+ 1
        }
        if !enhancements.infiniteAmmo {              // ENHANCEMENT hook (default off = original)
            mem.w16(a5 + 2, mem.r16(a5 + 2) &- 1)
        }
        s0NoiseAdd(8)
    }

    /// $1744e noise_add: spawn chance += d0, clamped at $ff.
    func s0NoiseAdd(_ d0: UInt16) {
        v0.noise = v0.noise &+ d0
        if v0.noise < 0xff { return }
        v0.noise = 0xff
    }

    /// $1746a pf_grenade.
    func s0PfGrenade() {
        if v0.grenadeBusy != 0 { s0PfFire(); return }
        if v0.input & 0xf != 0 { s0PfFire(); return }
        let a5 = s0Man
        if mem.r16(a5 + 0) == 0 { s0PfFire(); return }
        s0Sfx(0xa)
        mem.w16(a5 + 0, mem.r16(a5 + 0) &- 1)
        mem.w8(0x60c42, 0xff)                    // st.b v_grenade_busy
        v0.grenadeT = 8
        v0.pstate = 7
        v0.pcnt = 2
        v0.pframe = 0x2f
        s0NoiseAdd(0x20)
    }

    // MARK: movement / scrolling

    /// $1896e pl_move: d0 = direction bits, 4 px per tick; falls into calc_player_pos.
    func s0PlMove(_ d0: UInt8) {
        let d6: UInt16 = 4
        if mem.r16(0x60c5c) != 0 { return }     // cannot walk while the own grenade is in the air
        s0ScrollStep(d0, d6)
        s0CalcPlayerPos()
    }

    /// $18980 calc_player_pos: $60c28/$60c2a/$60c2c/$60c30/$60cb2/$60c32.
    func s0CalcPlayerPos() {
        mem.w32(0x60c28, mem.r32(0x60c24))
        v0.pcol = ((v0.c34 &+ 0x1b) >> 3) &+ v0.T
        var a0 = s0MapLevel(v0.level)
        a0 = s0AddW(a0, v0.pcol)
        a0 = s0AddW(a0, 0xb4)
        v0.pmapptr = a0
        v0.pworld = (v0.T &<< 3) &+ v0.c34 &+ 0x1c
        let d0 = (v0.scrollcnt &+ 0x10) & 0xf
        v0.hscroll = d0
        v0.align = d0 & 7
    }

    /// $189fe scroll_step (d0 = direction bits, d6 = pixels).
    func s0ScrollStep(_ d0: UInt8, _ d6: UInt16) {
        cpu(Platoon.s0CyclesScrollStep)
        if d0 & 8 != 0 { s0ScrollLeftChk(d6); return }
        if v0.pfacing != 0 { s0ToggleFacing(); return }     // first press only turns round
        if v0.bridge == 2 && v0.level == 1 && v0.pworld == 0x238 {
            k_queue_text(0x18)                               // PLEASE DON'T ATTEMPT SUICIDE!!
            return
        }
        if enhancements.section0.bridgeFailsafeOn && s0BridgeFailsafeBlocks() { return }   // ENHANCEMENT S6 (default off)
        // scroll_right $18a3e
        if v0.align == 0 {
            v0.probeY = v0.py &+ 8
            v0.probeX = v0.px &+ 0x20
            if s0SolidAt() { v0.pframe = 8; return }
        }
        // sr_move
        v0.dx = 0xfffc
        if mem.r8(0x60cb7) & 1 != 0 { v0.pframe = (v0.pframe &+ 1) & 7 }
        v0.scrollcnt = (v0.scrollcnt &- d6) & 0xf
        if v0.scrollcnt != 0xc { return }
        v0.c34 = v0.c34 &+ 2
        if v0.c34 < 8 { return }
        if v0.c34 >= 0xfff9 { return }
        v0.c34 = 0
        v0.T = v0.T &+ 1
        // shift the attribute window left by one tile column (8 bytes), 18 rows of $38 bytes
        cpu(Platoon.s0CyclesAttrShift)
        var src: UInt32 = 0x600bc, dst: UInt32 = 0x600b4
        for _ in 0...0x11 {
            for i in 0..<48 { mem.w8(dst &+ UInt32(i), mem.r8(src &+ UInt32(i))) }
            src &+= 48 + 8; dst &+= 48 + 8
        }
        var a1 = s0MapLevel(v0.level)
        a1 = s0AddW(a1, v0.T)
        a1 &+= 6
        s0AttrCopyCols(dest: 0x600e4, map: a1, colsRows: 0x0001_0003)
    }

    /// $18b46 scroll_left_chk / scroll_left.
    func s0ScrollLeftChk(_ d6: UInt16) {
        if v0.pfacing == 0 { s0ToggleFacing(); return }
        if v0.bridge == 2 && v0.level == 1 && v0.pworld == 0x246 {
            k_queue_text(0x18)
            return
        }
        if v0.align == 0 {
            v0.probeY = v0.py &+ 8
            v0.probeX = v0.px &- 0x10
            if s0SolidAt() { v0.pframe = 8; return }
        }
        // sl_move
        v0.dx = 4
        if mem.r8(0x60cb7) & 1 != 0 { v0.pframe = (v0.pframe &+ 1) & 7 }
        v0.scrollcnt = (v0.scrollcnt &+ d6) & 0xf
        if v0.scrollcnt != 0 { return }
        v0.c34 = v0.c34 &- 2
        if v0.c34 < 8 { return }
        if v0.c34 >= 0xfff9 { return }
        v0.c34 = 0
        v0.T = v0.T &- 1
        // shift the attribute window right by 8 bytes (backwards long copy, 18 rows)
        cpu(Platoon.s0CyclesAttrShift)
        var src: UInt32 = 0x6049c, dst: UInt32 = 0x604a4
        for _ in 0...0x11 {
            for _ in 0..<48 { src &-= 1; dst &-= 1; mem.w8(dst, mem.r8(src)) }
            src &-= 8; dst &-= 8
        }
        var a1 = s0MapLevel(v0.level)
        a1 = s0AddW(a1, v0.T)
        s0AttrCopyCols(dest: 0x600b4, map: a1, colsRows: 0x0001_0003)
    }

    /// $18c7c toggle_facing.
    func s0ToggleFacing() { v0.pfacing ^= 1 }
}
