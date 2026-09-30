// Section 0 enemy: state machine ($5f888, table $1aad0) — only one enemy exists at a time.
// Spec: re/jungle/NOTES.md §b.6 (village branches in re/village/NOTES.md §b.10).

extension Platoon {
    /// Rifle/enemy RNG helper: kernel random byte (d0.l = 0..255) truncated to a word.
    @inline(__always) func s0Rand() -> UInt16 {
        cpu(Platoon.s0CyclesRand)
        return UInt16(truncatingIfNeeded: k_random())
    }

    /// $180da en_st0_spawn: no enemy; bridge runner or random spawn.
    func s0EnSt0Spawn() {
        if v0.pstate == 9 {                       // stuck at the unblown bridge: the runner
            v0.estate = 8
            v0.ex = 0; v0.ey = 0x50               // move.l #$50,v_ex
            v0.eframe = 0x15
            v0.ebase = 0x15
            v0.runnerSlot = 0x60c48
            v0.efacing = 0
            v0.ecnt = 0
            v0.runnerShots = 0
            return
        }
        // es_spawn_try
        if v0.pstate == 0xa { return }
        if v0.level == 5 { s0HutSetupEnemy(); return }
        if v0.plevel == 1 && v0.pcol >= 0x39 && v0.pcol < 0x56 { return }   // river/bridge: no spawns
        // es_roll
        if s0Rand() >= v0.noise { return }
        if v0.level != 0 {
            if s0Rand() & 0xf == 0 {              // tree sniper
                v0.eframe = 0x1e
                v0.ebase = 0x15
                v0.ex = 0x90; v0.ey = 0
                v0.efacing = 0
                v0.estate = 1
                v0.ecnt = 1
                return
            }
        }
        // es_try_trap: spider-hole VC 2 tiles ahead
        if UInt8(truncatingIfNeeded: s0Rand()) & 3 == 0 {
            let t = mem.r8(v0.pmapptr &+ 2)
            if t < 5 && t != 2 {
                v0.efacing = 0
                v0.estate = 5
                v0.ecnt = 4
                v0.eframe = 0x2b
                v0.ebase = 1
                let d0 = v0.c34
                v0.ex = 0x100; v0.ey = 0x50
                v0.ex = v0.ex &+ d0
                return
            }
        }
        // es_soldier
        v0.eframe = 0x15
        v0.ebase = 0x15
        v0.evillager = 0
        if v0.level == 0 && v0.T >= 0x33 && s0Rand() & 2 != 0 {   // innocent villager
            v0.eframe = 0x23
            v0.ebase = 0x23
            mem.w8(0x5f898, 0xff)                 // st.b v_evillager
        }
        // es_soldier2
        v0.estate = 2
        v0.ex = 0; v0.ey = 0x50
        v0.espeed = (s0Rand() & 1) &+ 5
        v0.ex = 1; v0.ey = 0x50
        v0.efacing = s0Rand() & 1
        if v0.efacing == 0 { return }
        v0.ex = 0x130; v0.ey = 0x50
    }

    /// $182c0 en_st1_drop: sniper dropping from the canopy.
    func s0EnSt1Drop() {
        v0.ey = v0.ey &+ v0.ecnt
        v0.ecnt = v0.ecnt &+ 2
        if v0.ey < 0x50 { return }
        v0.ey = 0x50
        v0.estate = 2
        s0EnMaybeTurn()
    }

    /// $182f2 en_st2_walk: walking soldier / villager.
    func s0EnSt2Walk() {
        let mask = UInt16(enhancements.section0.difficulty.shootMask ?? 0x1f)   // ENHANCEMENT M10 (nil = $1f)
        if s0Rand() & mask == 0 { s0EnTryShoot(); return }
        s0EwStep()
    }

    /// $18300 ew_step: walk cycle, tree probe, move, trap jump, turning, leaving the screen.
    func s0EwStep() {
        v0.ecnt = (v0.ecnt &+ 1) & 7
        v0.eframe = v0.ecnt &+ v0.ebase
        v0.probeY = v0.ey
        v0.probeX = v0.ex
        if v0.efacing == 0 {
            if v0.probeX >= 0x120 { v0.probeX = 0x11f }
            v0.probeX = v0.probeX &+ 0x20
        } else {
            if v0.probeX < 0x10 { v0.probeX = 0x10 }
            v0.probeX = v0.probeX &- 0x10
        }
        if s0SolidAt() { s0EnTurn() }
        // ew_move
        var d0 = v0.espeed
        if v0.efacing != 0 { d0 = 0 &- d0 }
        v0.ex = v0.ex &+ d0
        if v0.trapState != 0 {
            let d1 = v0.trapX &- v0.ex
            if s0Abs(d1) < 0x40 {
                let neg = Int16(bitPattern: d1) < 0
                if (v0.efacing != 0 && neg) || (v0.efacing == 0 && !neg) {
                    v0.estate = 7                  // jump over the trap
                    v0.ecnt = 0
                }
            }
        }
        // ew_face
        let f = v0.efacing
        if f != v0.pfacing {
            if f != 0 {
                if v0.ex < 0x50 { s0EnMaybeTurn() }
            } else {
                if v0.ex >= 0xf0 { s0EnMaybeTurn() }
            }
        }
        // ew_offscreen
        if v0.ex < 0x130 { return }
        if v0.ex >= 0x136 { s0EnemyClear(); return }
        s0EnMaybeTurn()
    }

    /// $18440 en_maybe_turn: 1/16 chance.
    func s0EnMaybeTurn() {
        if s0Rand() & 0xf != 0 { return }
        s0EnTurn()
    }

    /// $1844e en_turn.
    func s0EnTurn() { v0.efacing ^= 1 }

    /// $18458 en_try_shoot.
    func s0EnTryShoot() {
        if mem.r16(0x60c62) != 0 { s0EwStep(); return }     // enemy bullet already flying
        if v0.evillager != 0 { s0EwStep(); return }         // villagers never shoot
        var d1: UInt16 = 8
        if v0.estate == 5 {                                 // spider-hole VC fires to the left
            d1 = 0x18
            v0.efacing = 1
            s0EnFire(d1)
            v0.efacing = 0
            return
        }
        // ets_not5
        if v0.estate == 4 { s0EnFire(d1); return }
        if s0Rand() & 1 == 0 { s0EnFire(d1); return }
        d1 = 0x10                                           // kneel & fire
        v0.eframe = 0x21
        v0.estate = 6
        v0.ecnt = 3
        s0EnFire(d1)
    }

    /// $184ca en_fire: enemy bullet $60c60 at the enemy position, y + d1, 20 px/tick.
    func s0EnFire(_ d1: UInt16) {
        var d2: UInt16 = 0xa
        if v0.efacing != 0 { d2 = 0 &- d2 }
        mem.w16(0x60c64, d2)
        mem.w16(0x60c64, mem.r16(0x60c64) &<< 1)          // asl.w
        mem.w32(0x60c60, mem.r32(0x5f88a))
        mem.w16(0x60c62, mem.r16(0x60c62) &+ d1)
        if v0.estate == 8 { s0Sfx(0xa); return }
        s0Sfx(0x84)
    }

    /// $1850e en_drop_grenade: the bridge runner's 3 shots (uses the player bullet slots).
    func s0EnDropGrenade() {
        if v0.runnerTimer != 0 { v0.runnerTimer = v0.runnerTimer &- 1; return }
        v0.runnerTimer = 2
        if v0.runnerShots == 3 { return }
        v0.runnerShots = v0.runnerShots &+ 1
        let a0 = v0.runnerSlot
        v0.runnerSlot = v0.runnerSlot &+ 6
        mem.w16(a0 + 4, 8)
        mem.w32(a0 + 0, mem.r32(0x5f88a))
        mem.w16(a0 + 2, mem.r16(a0 + 2) &+ 7)
        if v0.runnerShots != 1 { return }
        s0Sfx(0xa)
    }

    /// $1856e en_st3_jumpdown: dying (small hop, fall); may drop a supply crate.
    func s0EnSt3JumpDown() {
        if v0.ebase == 0 { s0E3Land(); return }
        v0.ebase = v0.ebase &- 1
        let d0 = 0 &- (mem.r16(Platoon.s0JumpArc &+ UInt32(v0.ebase &<< 1)) >> 2)
        v0.ey = 0x50
        if v0.level == 5 { v0.ey = 0x3d }
        v0.ey = v0.ey &+ d0
        if v0.ebase >= 6 { return }
        if v0.ebase >= 3 { v0.eframe = 0x20; return }
        v0.eframe = 0x33
    }

    /// $185e2 e3_land.
    func s0E3Land() {
        if v0.level == 5 {                        // e3_hut: the hut VC stays lying
            v0.hutKilled = 1
            v0.estate = 4
            v0.ey = 0x3d
            return
        }
        if v0.bridge != 2 { s0EnemyClear(); return }
        if v0.evillager != 0 { s0EnemyClear(); return }
        if s0Rand() & 3 != 0 { s0EnemyClear(); return }
        if v0.crateY != 0 { s0EnemyClear(); return }
        v0.crateX = v0.ex
        v0.crateY = 0x50
        s0EnemyClear()
    }

    /// $1864c en_st4_in_hut: the hut-2 guard fires every $19 ticks.
    func s0EnSt4InHut() {
        if v0.eframe != 0x34 { return }
        v0.ecnt = v0.ecnt &- 1
        if v0.ecnt != 0 { return }
        v0.ecnt = 0x19
        s0EnTryShoot()
    }

    /// $1866e enemy_score: villager = message + morale -$1200, else +300 points.
    func s0EnemyScore() {
        if v0.evillager != 0 {
            k_queue_text(0x17)
            s0MoraleSub(UInt16(enhancements.section0.difficulty.villagerMorale ?? 0x1200))   // ENHANCEMENT M10
            return
        }
        k_add_score(after: Platoon.s0Score300End)
    }

    /// $18696 en_st5_trap: spider-hole VC rises (frames $2b..$2e), fires once, sinks.
    func s0EnSt5Trap() {
        v0.ecnt = v0.ecnt &- 1
        if v0.ecnt != 0 { return }
        v0.ecnt = 3
        v0.eframe = v0.eframe &+ v0.ebase
        if v0.eframe < 0x2b { s0EnemyClear(); return }
        if v0.eframe < 0x2e { return }
        v0.ecnt = 4
        v0.ebase = 0xffff
        s0EnTryShoot()
    }

    /// $186e0 enemy_clear.
    func s0EnemyClear() {
        v0.eframe = 0
        v0.ex = 0
        v0.ecnt = 0
        v0.ebase = 0
        v0.estate = 0
        v0.evillager = 0
    }

    /// $18706 en_st6_crouchfire.
    func s0EnSt6CrouchFire() {
        v0.eframe = 0x21
        v0.ecnt = v0.ecnt &- 1
        if v0.ecnt != 0 { return }
        v0.estate = 2
    }

    /// $18722 en_st7_blown: jumping over a booby trap.
    func s0EnSt7Blown() {
        v0.eframe = 0x1d
        v0.ey = 0x50 &- mem.r16(Platoon.s0JumpArc &+ UInt32(v0.ecnt &<< 1))
        v0.probeY = v0.ey
        v0.probeX = v0.ex
        v0.probeX = v0.probeX &+ 0x20
        if v0.efacing != 0 { v0.probeX = v0.probeX &- 0x30 }
        if !s0SolidAt() {
            var d0 = v0.espeed
            if v0.efacing != 0 { d0 = 0 &- d0 }
            v0.ex = v0.ex &+ d0
        }
        if v0.ex >= 0x136 { s0EnemyClear(); return }
        v0.ecnt = (v0.ecnt &+ 1) & 0xf
        if v0.ecnt != 0 { return }
        v0.estate = 2
        v0.ey = 0x50
    }

    /// $187c6 en_st8_runner: the bridge runner, kneels at x=$21 and fires 3 shots.
    func s0EnSt8Runner() {
        v0.ecnt = (v0.ecnt &+ 1) & 7
        v0.eframe = v0.ecnt &+ v0.ebase
        v0.ex = v0.ex &+ 5
        if v0.ex < 0x20 { return }
        s0EnDropGrenade()
        v0.ex = 0x21
        v0.eframe = 0x34
    }

    /// $18854 enemy_reset: clear state/frame/villager and the enemy bullet.
    func s0EnemyReset() {
        v0.estate = 0
        v0.eframe = 0
        v0.evillager = 0
        s0BulletKill(0x60c60)
    }
}
