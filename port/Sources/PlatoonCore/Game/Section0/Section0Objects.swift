// Section 0 bullets, explosions and world objects: booby traps, explosives box / planted charge, supply
// crates, the bridge. Spec: re/jungle/NOTES.md §b.7, §b.8 (bridge also re/village/NOTES.md §b.11).

extension Platoon {
    /// Hit handlers passed in a2 to bullet_move_one (code addresses in the original, never stored in RAM).
    enum S0BulletHit { case pbullet, grenade, ebullet }   // $1768e / $1770e / $1772a

    static let s0PBullets: UInt32 = 0x60c48   // 3 x {x,y,dx}
    static let s0Grenade: UInt32 = 0x60c5a
    static let s0EBullet: UInt32 = 0x60c60

    // MARK: bullets

    /// $174d2 bullets_update: player bullets, enemy bullet, grenade (or only the runner's shots).
    func s0BulletsUpdate() {
        if v0.firecool != 0 { v0.firecool = v0.firecool &- 1 }
        if v0.runnerShots != 0 {                          // runner shots active: only they are processed
            var d0 = v0.runnerShots &- 1
            var a0 = Platoon.s0PBullets
            mem.w32(0x60c88, mem.r32(0x5f880))
            while true {
                s0BulletMoveOne(a0, bob: 0x30 &+ d0, hit: .ebullet)   // d1 = $30 + dbra counter
                a0 &+= 6
                if d0 == 0 { break }
                d0 &-= 1
            }
            return
        }
        // bu_normal
        mem.w32(0x60c88, mem.r32(0x5f880))                // target = player
        s0BulletMoveOne(Platoon.s0EBullet, bob: 0x4e, hit: .ebullet)
        mem.w32(0x60c88, mem.r32(0x5f88a))                // target = enemy
        var a0 = Platoon.s0PBullets
        for _ in 0...2 {
            s0BulletMoveOne(a0, bob: 0x4e, hit: .pbullet)
            a0 &+= 6
        }
        let g = Platoon.s0Grenade
        if mem.r16(g + 2) == 0 { return }
        if v0.grenadeT == 0 { s0BulletKill(g); return }  // end of flight -> explosion
        let d0 = mem.r16(Platoon.s0GrenadeArc &+ UInt32(v0.grenadeT &<< 1))
        mem.w16(g + 2, (0 &- d0) &+ 0x70)
        v0.grenadeT = v0.grenadeT &- 1
        s0BulletMoveOne(g, bob: 0x53, hit: .grenade)
    }

    /// $175b6 bullet_move_one (a0 = bullet {x,y,dx}, d1 = bob, a2 = hit handler).
    func s0BulletMoveOne(_ a0: UInt32, bob d1: UInt16, hit a2: S0BulletHit) {
        if mem.r16(a0 + 2) == 0 { return }
        v0.probeY = mem.r16(a0 + 2)
        v0.probeX = mem.r16(a0 + 0)
        if s0SolidAt() { s0BulletKill(a0); return }       // hits a tree / wall
        mem.w32(0x60c8c, mem.r32(a0))
        mem.w16(a0, mem.r16(a0) &+ mem.r16(a0 + 4))
        if mem.r16(a0) >= 0x140 && Int16(bitPattern: mem.r16(a0 + 4)) < 0 { mem.w16(a0, 0) }  // left edge
        mem.w32(0x60c90, mem.r32(a0))
        if !s0BulletXRangeTest() { s0BulletDraw(a0, bob: d1); return }
        switch a2 {
        case .pbullet: s0HitPBullet(a0, bob: d1)
        case .grenade: s0HitGrenade(a0, bob: d1)
        case .ebullet: s0HitEBullet(a0, bob: d1)
        }
    }

    /// $17610 bullet_draw.
    func s0BulletDraw(_ a0: UInt32, bob d1: UInt16) {
        cpu(Platoon.s0CyclesBulletDraw)
        if mem.r16(a0) == 0 { s0BulletKill(a0); return }
        if mem.r16(a0) >= 0x140 { s0BulletKill(a0); return }
        v0.probeY = mem.r16(a0 + 2)
        v0.probeX = mem.r16(a0 + 0)
        if s0SolidAt() { s0BulletKill(a0); return }
        s0DrawBob(mem.r32(a0), d1)
    }

    /// $17644 bullet_kill: free the slot; the grenade starts its explosion.
    func s0BulletKill(_ a0: UInt32) {
        if a0 == Platoon.s0Grenade {
            v0.explFrame = 0
            v0.explTimer = 3
            v0.explX = mem.r16(a0)
            v0.explY = 0x50
            v0.grenadeBusy = 0
            s0Sfx(0x85)
        }
        // bullet_zero
        mem.w16(a0 + 0, 0)
        mem.w16(a0 + 2, 0)
        mem.w16(a0 + 4, 0)
    }

    /// $1768e hit_pbullet: player bullet touched the enemy x-range.
    func s0HitPBullet(_ a0: UInt32, bob d1: UInt16) {
        if v0.estate == 2 { s0EnemyShot(a0); return }
        if v0.estate == 5 { s0HitPbState5(a0, bob: d1); return }
        if v0.estate != 4 { s0BulletDraw(a0, bob: d1); return }
        if v0.hutKilled != 0 { s0BulletDraw(a0, bob: d1); return }
        s0EnemyShot(a0)
    }

    /// $176bc enemy_shot, falls into enemy_killed_common.
    func s0EnemyShot(_ a0: UInt32) {
        s0BulletKill(a0)
        s0EnemyScore()
        s0EnemyKilledCommon()
    }

    /// $176c4 enemy_killed_common.
    func s0EnemyKilledCommon() {
        s0Sfx(0x80)
        if v0.estate == 5 { s0EnemyClear(); return }
        v0.estate = 3
        v0.ebase = 0x10
        v0.eframe = 0x1f
    }

    /// $176f2 hit_pb_state5: only the grenade at the end of its flight (never true for rifle bullets).
    func s0HitPbState5(_ a0: UInt32, bob d1: UInt16) {
        if a0 != Platoon.s0Grenade { s0BulletDraw(a0, bob: d1); return }
        if v0.grenadeT >= 2 { s0BulletDraw(a0, bob: d1); return }
        s0EnemyShot(a0)
    }

    /// $1770e hit_grenade.
    func s0HitGrenade(_ a0: UInt32, bob d1: UInt16) {
        if v0.estate == 2 { s0EnemyShot(a0); return }
        if v0.estate != 5 { s0BulletDraw(a0, bob: d1); return }
        s0EnemyShot(a0)
    }

    /// $1772a hit_ebullet: enemy bullet touched the player x-range.
    func s0HitEBullet(_ a0: UInt32, bob d1: UInt16) {
        if v0.pstate == 9 { s0PlayerHit(); return }       // bullet continues (not drawn this tick)
        if v0.pstate != 5 && v0.pstate != 0 { s0BulletDraw(a0, bob: d1); return }
        s0BulletKill(a0)
        s0PlayerHit()
    }

    /// $17750 player_hit: state 8 (skipped while invincible).
    func s0PlayerHit() {
        if v0.invincible != 0 { return }
        v0.blastflag = 0
        v0.pstate = 8
        v0.pcnt = 0x10
        v0.pframe = 0x31
        s0Sfx(0x81)
    }

    /// $17788 bullet_xrange_test: hit iff max(old,new) >= t and min(old,new)+4 < t+$18 (x only).
    func s0BulletXRangeTest() -> Bool {
        var d0 = v0.bulOldX, d1 = v0.bulNewX
        if !(d1 < d0) { swap(&d0, &d1) }                  // d0 = max, d1 = min
        d1 = d1 &+ 4
        var d2 = v0.hitTargetX
        if d0 < d2 { return false }
        d2 = d2 &+ 0x18
        return d1 < d2
    }

    // MARK: explosions

    /// $18870 explosion_update: grenade explosion animation (4 frames x 3 ticks).
    func s0ExplosionUpdate() {
        if v0.explTimer == 0 { return }
        v0.explTimer = v0.explTimer &- 1
        if v0.explTimer != 0 { s0ExplosionDraw(); return }
        v0.explTimer = 3
        s0ExplosionDraw()
        v0.explFrame = v0.explFrame &+ 1
        if v0.explFrame < 4 { return }
        v0.explTimer = 0
    }

    /// $188aa explosion_draw.
    func s0ExplosionDraw() {
        let d1 = v0.explFrame &+ 0x34
        v0.explX = v0.explX &+ v0.dx
        if v0.explX >= 0x130 { v0.explTimer = 0; return }
        s0DrawBob(mem.r32(0x60c6a), d1)
    }

    // MARK: booby trap

    /// $19b72 trap_spawn: tripwire at the screen edge ahead (keeps the high byte of $60c34: quirk).
    func s0TrapSpawn() {
        if v0.trapState != 0 { return }
        if v0.dx == 0 { return }
        if v0.align != 0 { return }
        if s0Rand() & 3 != 0 { return }
        var d0 = v0.c34
        if v0.pfacing != 0 {
            var a0 = v0.pmapptr
            d0 = (d0 & 0xff00) | UInt16(mem.r8(a0 &- 2))
            a0 &-= 2
            if mem.r8(a0) >= 5 { return }
            if mem.r8(a0) == 2 { return }
            mem.w32(0x60c76, 0x0000_0050)
            v0.trapX = v0.trapX &+ d0
            v0.trapState = 1
            return
        }
        let a0 = v0.pmapptr &+ 2
        d0 = (d0 & 0xff00) | UInt16(mem.r8(a0))
        if mem.r8(a0) >= 5 { return }
        if mem.r8(a0) == 2 { return }
        mem.w32(0x60c76, 0x0128_0050)
        v0.trapX = v0.trapX &+ d0
        v0.trapState = 1
    }

    /// $18f82 trap_update: scroll, player contact (kills the man), explosion, draw.
    func s0TrapUpdate() {
        if v0.trapState == 0 { return }
        if v0.trapState == 2 { s0TrapExploding(); return }
        v0.trapX = v0.trapX &+ v0.dx
        if v0.trapX >= 0x130 { s0TrapClear(); return }
        if v0.trapX >= 0x8c && v0.trapX < 0x9c && v0.pstate == 0 {
            s0PlayerHit()
            mem.w16(s0Man + 4, 3)                 // death on the following hit count
            v0.trapState = 2
            v0.trapxTimer = 3
            v0.trapxFrame = 0
            s0Sfx(0x85)
            return
        }
        s0TrapDraw()
        // $19002-$19027 (unreachable "trap kills enemy" code after `bra trap_draw`) not translated.
    }

    /// $19028 trap_draw.
    func s0TrapDraw() {
        v0.flip = 0
        s0DrawBob(mem.r32(0x60c76), 0xf)
    }

    /// $1903c trap_exploding.
    func s0TrapExploding() {
        v0.trapxTimer = v0.trapxTimer &- 1
        if v0.trapxTimer != 0 { s0TrapExplDraw(); return }
        v0.trapxTimer = 3
        s0TrapExplDraw()
        v0.trapxFrame = v0.trapxFrame &+ 1
        if v0.trapxFrame < 4 { return }
        s0TrapClear()
    }

    /// $19066 trap_clear.
    func s0TrapClear() {
        v0.trapState = 0
        mem.w32(0x60c76, 0)
    }

    /// $19074 trap_expl_draw.
    func s0TrapExplDraw() {
        let d1 = v0.trapxFrame &+ 0x34
        v0.trapX = v0.trapX &+ v0.dx
        s0DrawBob(mem.r32(0x60c76), d1)
    }

    // MARK: explosives, crate

    /// $19094 bomb_update: explosives box (level 4) / planted charge (bridge).
    func s0BombUpdate() {
        if mem.r32(0x60c7c) == 0 { return }
        v0.bombX = v0.bombX &+ v0.dx
        if v0.bombX >= 0x140 { s0BombClear(); return }
        let d0 = mem.r32(0x60c7c)
        v0.flip = 0
        s0DrawBob(d0, 0x33)
    }

    /// $190ca crate_update.
    func s0CrateUpdate() {
        if v0.crateY == 0 { return }
        v0.crateX = v0.crateX &+ v0.dx
        if v0.crateX >= 0x141 { s0CrateClear(); return }
        s0DrawBob(mem.r32(0x60c84), 0x3a)
    }

    /// $190fa crate_clear.
    func s0CrateClear() { mem.w32(0x60c84, 0) }

    /// $19c18 explosives_pickup (level 4 cols $31..$35).
    func s0ExplosivesPickup() {
        if v0.explosives != 0 { return }
        if v0.plevel != 4 { return }
        if v0.pcol >= 0x36 { s0BombClear(); return }
        if v0.pcol < 0x31 { s0BombClear(); return }
        if v0.pcol == 0x31 && v0.align == 0 && v0.c34 == 2 {
            mem.w32(0x60c7c, 0x0138_0050)         // ep_start_anim: box appears at the right edge
            return
        }
        if v0.bombX < 0x90 { return }
        if v0.bombX >= 0x98 { return }
        mem.w32(0x60c7c, 0)
        mem.w8(a6 + 0x28, 0xff)                   // st.b $28(a6)
        k_queue_text(0x10)                        // YOU HAVE FOUND SOME EXPLOSIVES
        k_hud_icons()
        k_add_score(after: Platoon.s0Score500End)
    }

    /// $19caa bomb_clear.
    func s0BombClear() { mem.w32(0x60c7c, 0) }

    /// $19cb2 bridge_logic (level 1 only): hint, plant, doom, blow.
    func s0BridgeLogic() {
        if v0.plevel != 1 { return }
        if v0.pcol >= 0x45 && v0.pcol < 0x4b && v0.bridge == 0 && v0.msgCount == 0 {
            k_queue_text(0x11)                    // SET THE EXPLOSIVES ON THE BRIDGE
        }
        if v0.pcol == 0x48 && v0.explosives != 0 && v0.bridge != 2 && v0.pstate != 0xa {
            v0.bombX = v0.px                      // PLANT
            v0.bombY = 0x50
            v0.pstate = 0xa
            v0.pcnt = 5
            v0.bridge = 1
            v0.explosives = 0
            k_hud_icons()
            return
        }
        // bridge_end
        if v0.pcol < 0x4e { return }
        if v0.bridge == 0 {                       // walked past without planting
            if v0.estate == 8 { return }
            v0.pstate = 9
            if v0.estate != 2 { return }
            s0EnemyKilledCommon()
            return
        }
        // bridge_blow $19dd0
        if v0.bridge == 2 { return }
        mem.w8(0x1b209, 0x95)                     // broken bridge tiles in the map
        mem.w8(0x1b20a, 0x96)
        s0PlayerHit()
        mem.w8(0x60cbc, 0xff)                     // st.b v_blastflag: knock-back only
        v0.bridge = 2
        k_add_score(after: Platoon.s0Score10000End)
    }

    /// $19e0a crate_open: random content when the player walks onto a supply crate.
    func s0CrateOpen() {
        if v0.crateY == 0 { return }
        if v0.crateX < 0x90 || v0.crateX >= 0x98 { return }
        let d0 = s0Rand() & 3
        switch d0 {
        case 0:                                   // crate_ammo
            k_queue_text(0x13)
            let a5 = s0Man
            mem.w16(a5 + 2, mem.r16(a5 + 2) &+ 0x48)
            if mem.r16(a5 + 2) >= 0x90 { mem.w16(a5 + 2, 0x90) }
        case 2:                                   // crate_empty: msg 0 "A FOOD PACKAGE"
            k_queue_text(0)
        case 3:                                   // crate_other: AN EMPTY BOX
            k_queue_text(0x14)
            mem.w32(0x60c84, 0)
            return
        default:                                  // 1: MEDICAL SUPPLIES
            k_queue_text(0xc)
            v0.morale = v0.morale &+ 0x300
            let a5 = s0Man
            if mem.r16(a5 + 4) != 0 {
                mem.w16(a5 + 4, mem.r16(a5 + 4) &- 1)
                k_hud_wounds()
            }
        }
        // crate_done
        v0.morale = v0.morale &+ 0x200
        mem.w32(0x60c84, 0)
        k_add_score(after: Platoon.s0Score500End)
    }
}
