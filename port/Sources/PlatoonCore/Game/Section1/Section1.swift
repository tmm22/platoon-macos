// Load section 1 ("THE TUNNEL & FLARE SECTIONS"), code $17000-$19374, data $19374-$3d7c4.
// Spec: re/tunnels/NOTES.md (engine + tunnels), re/flare/NOTES.md (flare section).
// Listing: re/flare/section1_full_with_flare_labels.s (all section-1 code) / re/tunnels/tunnels.s.
//
// This file: section entry ($17000), tunnel (re)start ($170c4), the tunnel main loop ($171c6), the
// end-of-game / soldier-lost exits ($17252-$17302), text screens, and the dispatch of code addresses
// that the original keeps in RAM (object handlers, room item handlers).
//
// Register conventions kept from the original: a6 = $12dde (globals), a5 = $1e(a6) (current soldier
// record; every kernel HUD call reloads a5 from $1e(a6), so a computed accessor is exact), a3 = the object
// record passed to object handlers.

/// Addresses of section-1 variables and tables (all in the original RAM layout).
enum S1 {
    // tunnel objects: 8 x 18 bytes at $19d32 (0 crosshair, 1 enemy shot, 2 corridor enemy, 3 water enemy, 4 room guard)
    static let objs: UInt32 = 0x19d32
    static let obj1: UInt32 = 0x19d44
    static let obj2: UInt32 = 0x19d56
    static let obj3: UInt32 = 0x19d68
    static let obj4: UInt32 = 0x19d7a
    // flare object lists
    static let list1: UInt32 = 0x19e0a        // [0] flare, [2..6] enemies
    static let list1Enemies: UInt32 = 0x19e2e
    static let list2: UInt32 = 0x19eac        // [0] crosshair, [k] muzzle flash of list1[k] (= +$90)
    static let spawnSlots: UInt32 = 0x19f4e   // 8 x {b used, b 0, w x}
    static let palStepDur: UInt32 = 0x19f6e   // bytes
    static let palSeq: UInt32 = 0x19f76       // 7 longs
    // palettes / constants
    static let palWork: UInt32 = 0x1a012
    static let palTunnel: UInt32 = 0x1a032
    static let palText: UInt32 = 0x1a052
    static let palHud: UInt32 = 0x1a06e
    static let mapCachePtrs: UInt32 = 0x1a08e
    static let mapCacheIdx: UInt32 = 0x1a096
    static let score300End: UInt32 = 0x1a0a4
    static let score500End: UInt32 = 0x1a0a8
    static let score30000End: UInt32 = 0x1a0ac
    static let crossSpeed: UInt32 = 0x1a0ae
    static let posX: UInt32 = 0x1a0b0       // word x<<8|y
    static let posY: UInt32 = 0x1a0b1
    // tables
    static let messages: UInt32 = 0x19374
    static let txtIntro: UInt32 = 0x1981c
    static let txtDestroyed: UInt32 = 0x19851
    static let txtWithdrawn: UInt32 = 0x198a3
    static let txtOneMoreChance: UInt32 = 0x198fc
    static let itemHandlers: UInt32 = 0x199bc
    static let roomPicByType: UInt32 = 0x19a14
    static let roomType: UInt32 = 0x19a24
    static let roomItems: UInt32 = 0x19a38
    static let items: UInt32 = 0x19a60
    static let roomEntries: UInt32 = 0x19aec
    static let hotspotsByType: UInt32 = 0x19b00
    static let swayTable: UInt32 = 0x19bc2
    static let dirDelta: UInt32 = 0x19cc2
    static let viewOffsets: UInt32 = 0x19cca
    static let waterPos: UInt32 = 0x19cf2
    static let waterFrames: UInt32 = 0x19d12
    static let viewTiles: UInt32 = 0x1a400
    static let viewMaps: UInt32 = 0x1c400
    static let bobBank: UInt32 = 0x1e220
    static let animTable: UInt32 = 0x1e020
    static let mapTiles: UInt32 = 0x29220
    static let maze: UInt32 = 0x29720
    static let bgRLE: UInt32 = 0x36242
    static let bgClean: UInt32 = 0x68000
    // self-modified immediate byte of `move.b #x,(a0)` at $177b2 (saved map cell under the arrow)
    static let smcMapCell: UInt32 = 0x177b5
    static let fadeActive: UInt32 = 0x18a40
    // variables at $3b220.. (cleared at section entry)
    static let palIndex: UInt32 = 0x3b222     // w flare: next palette index
    static let palCount: UInt32 = 0x3b224     // b flare: iterations until next palette step
    static let spawnCount: UInt32 = 0x3b226   // w flare spawn countdown
    static let spawnBase: UInt32 = 0x3b228    // w
    static let killBonus: UInt32 = 0x3b22a    // w
    static let viewCodeL: UInt32 = 0x3b22c
    static let viewCodeR: UInt32 = 0x3b22d
    static let enemyHit: UInt32 = 0x3b22e
    static let shotFlag: UInt32 = 0x3b22f
    static let inRoom: UInt32 = 0x3b230
    static let lightCycle: UInt32 = 0x3b231
    static let walkToggle: UInt32 = 0x3b232
    static let walked: UInt32 = 0x3b233
    static let destroyed: UInt32 = 0x3b235
    static let soldierLost: UInt32 = 0x3b236
    static let spawnTimer: UInt32 = 0x3b237
    static let fireLatch: UInt32 = 0x3b238
    static let turnLatch: UInt32 = 0x3b23a
    static let mapAtEntry: UInt32 = 0x3b23c
    static let roomIndex2: UInt32 = 0x3b23e
    static let roomType2: UInt32 = 0x3b240
    static let roomPic: UInt32 = 0x3b242
    static let posBeforeRoom: UInt32 = 0x3b246
    static let charRowTab: UInt32 = 0x3b248   // 25 l n*$140
    static let mazeRowTab: UInt32 = 0x3b2ac   // 43 l n*43
    static let viewMapTab: UInt32 = 0x3b358   // 40 l n*180
    static let colLeft: UInt32 = 0x3b3f8      // l byte column of the left view half / room picture
    static let colRight: UInt32 = 0x3b3fe
    static let lineTab: UInt32 = 0x3b402      // 200 l n*40
    static let fadePal: UInt32 = 0x3b722
    static let bobScratch: UInt32 = 0x3b742
    static let nightTemp: UInt32 = 0x3cd22
    static let mapCache0: UInt32 = 0x3d182
}

/// Globals block offsets used by section 1 (a6 = $12dde).
extension Platoon {
    var s1_a5: UInt32 { mem.r32(a6 + 0x1e) }
    var s1_dir: UInt16 { get { mem.r16(a6 + 0x2a) } set { mem.w16(a6 + 0x2a, newValue) } }
}

extension Platoon {
    // MARK: entry

    /// $17000 sec1_entry: build tables, intro text screen, soldier records, then the first life.
    func section1_start() -> Never {
        if config.deterministicRNG { mem.w32(0x12d70, UInt32(0x31415926)) }
        // lea $400,a7
        mem.fill(0x3b220, count: 0x1dc)                          // clr.b (a0)+ x $1dc
        var d0: UInt32 = 0
        for n in 0..<25 { mem.w32(S1.charRowTab + UInt32(4 * n), d0); d0 &+= 0x140 }
        var d1: UInt32 = 0
        for n in 0..<43 { mem.w32(S1.mazeRowTab + UInt32(4 * n), d1); d1 &+= 0x2b }
        d0 = 0
        for n in 0..<200 { mem.w32(S1.lineTab + UInt32(4 * n), d0); d0 &+= 0x28 }
        d1 = 0
        for n in 0..<40 { mem.w32(S1.viewMapTab + UInt32(4 * n), d1); d1 &+= 0xb4 }
        k_clear_screens()
        s1_textScreen(S1.txtIntro)
        mem.w32(a6 + 0x1e, a6)
        mem.w16(a6 + 0x22, 0)
        for i in 0..<5 {
            let r = a6 + UInt32(6 * i)
            mem.w16(r, 9); mem.w16(r + 2, 0x90); mem.w16(r + 4, 0)
        }
        mem.w32(a6 + 0x4a, S1.messages)
        mem.w8(a6 + 0x54, 0xff)
        mem.w16(S1.mapAtEntry, mem.r16(a6 + 0x24))
        s1_tunnelLives()
    }

    /// $170c4 tunnels_restart + $171c6 main loop + $172f6 exit_back_to_tunnels, as one loop:
    /// every life starts at $170c4; when a soldier is lost the "ONE MORE CHANCE" screen is shown and
    /// the section restarts at $170c4 (`bra tunnels_restart`).
    func s1_tunnelLives() -> Never {
        while true {
            s1_tunnelsRestart()
            s1_tunnelMainLoop()       // returns only when $3b236 (soldier lost) is set
            s1_textScreenMusic3(S1.txtOneMoreChance)
        }
    }

    /// $172f6 exit_back_to_tunnels (also the flare section's exit when a member died).
    func s1_exitBackToTunnels() -> Never {
        s1_textScreenMusic3(S1.txtOneMoreChance)
        s1_tunnelLives()
    }

    /// $170c4 tunnels_restart: start of each life.
    func s1_tunnelsRestart() {
        mem.w8(0x19d7b, 0)                        // guard frame
        mem.w32(0x19d84, 0x17b0c)                 // guard handler reset
        mem.w8(S1.walked, 0)
        let r = UInt8(truncatingIfNeeded: k_random())
        mem.w8(S1.spawnTimer, (r & 3) &+ 2)
        mem.w16(a6 + 0x24, mem.r16(S1.mapAtEntry))
        mem.w32(S1.colLeft, 0)
        mem.w32(S1.colRight, 0xa)
        if mem.r16(a6 + 0x24) == 0 {
            mem.w32(S1.colLeft, 0xa)
            mem.w32(S1.colRight, 0x14)
        }
        // movea.l $1e(a6),a5
        k_hud_init()
        mem.w8(S1.soldierLost, 0)
        mem.w8(S1.destroyed, 0)
        mem.w8(S1.posX, 0x15)
        mem.w8(S1.posY, 3)
        mem.w16(a6 + 0x2a, 3)
        mem.w16(a6 + 0x26, 0)
        mem.w16(a6 + 0x2c, 0)
        var a0 = S1.items
        while true {
            let d0 = mem.r16(a0)
            if d0 & 0x8000 != 0 { break }
            mem.w16(a0, d0 & ~0x80); a0 &+= 2
        }
        mem.w8(S1.inRoom, 0)
        s1_copyTunnelPalette()
        k_set_top_pal(S1.palWork)
        k_set_hud_pal(S1.palHud)
        k_hud_init()
        s1_recolourCrosshair()
        for i in 0..<0x321 { mem.w16(S1.mapCache0 + UInt32(2 * i), 0xffff) }
    }

    /// copy 8 longs $1a032 -> $1a012 (inline in $17176 and $172ce)
    func s1_copyTunnelPalette() {
        for i in 0..<8 { mem.w32(S1.palWork + UInt32(4 * i), mem.r32(S1.palTunnel + UInt32(4 * i))) }
    }

    /// $171c6 tunnel main loop. One tick per 4 vblanks (the kernel vblank handler decrements $6a(a6)).
    /// Returns when the current soldier was lost ($3b236); the other exits never return.
    func s1_tunnelMainLoop() {
        while true {
            repeat {
                tickPoint(0x171c6)
                k_wait_vbl()
                k_hud_update()
            } while mem.s16(a6 + 0x6a) >= 0
            tickPoint(0x171d8)
            mem.w16(a6 + 0x6a, 3)
            s1_drawMap()
            s1_drawView()
            if mem.r8(S1.obj2) | mem.r8(S1.obj3) == 0 {
                let t = mem.r8(S1.spawnTimer) &- 1
                mem.w8(S1.spawnTimer, t)
                if t == 0 {
                    let r = UInt8(truncatingIfNeeded: k_random())
                    mem.w8(S1.spawnTimer, (r & 0x31) &+ 0x10)
                    if mem.r8(S1.inRoom) == 0 { s1_spawnEnemy() }
                }
            }
            s1_objectsTunnel()
            k_swap()
            mem.w16(S1.mapCacheIdx, mem.r16(S1.mapCacheIdx) ^ 4)
            if mem.r8(S1.soldierLost) != 0 { return }
            if mem.r16(a6 + 0x2e) == 0 { s1_exitMoraleZero() }
            if mem.r8(S1.destroyed) != 0 { s1_exitPlatoonDestroyed() }
        }
    }

    // MARK: exits and text screens

    /// $17252 exit_platoon_destroyed: "YOUR PLATOON HAS BEEN DESTROYED", then game over.
    func s1_exitPlatoonDestroyed() -> Never {
        s1_textScreenMusic3(S1.txtDestroyed)
        k_game_over()
    }

    /// $17262 exit_morale_zero: "...WITHDRAWN FROM ACTION", then game over.
    func s1_exitMoraleZero() -> Never {
        s1_textScreenMusic3(S1.txtWithdrawn)
        k_game_over()
    }

    /// $17272 text_screen_music3: tune 3, then the text screen.
    func s1_textScreenMusic3(_ a0: UInt32) {
        k_music(3)
        s1_textScreen(a0)
    }

    /// $1727e text_screen: clear, text palettes, print, wait 50 vblanks, wait for fire, tune 4,
    /// clear, tunnel palette back.
    func s1_textScreen(_ a0: UInt32) {
        k_clear_screens()
        k_set_top_pal(S1.palText)
        k_set_hud_pal(S1.palHud)
        r_print(a0)
        k_wait_frames(0x31)
        // L_0172ae: jsr $410 / btst #7,d0 / beq — a tight poll loop in the original; polled once per frame here.
        while r_joystick() & 0x80 == 0 {
            m.waitVBlank()
        }
        k_music(4)
        k_clear_screens()
        s1_copyTunnelPalette()
        k_set_top_pal(S1.palWork)
    }

    // MARK: dispatch of code addresses stored in RAM

    /// `jsr (a0)` with a0 = object handler l[a3+$a] (tunnel and flare object lists).
    func s1_objectHandler(_ addr: UInt32, _ a3: UInt32) {
        switch addr {
        // tunnels
        case 0x178be: s1_hCrosshair(a3)
        case 0x17936: s1_hFlash(a3)
        case 0x17968: s1_hEnemyWalk(a3)
        case 0x17996: s1_hEnemyAim(a3)
        case 0x179e4: s1_hEnemyFired(a3)
        case 0x17a08: s1_hEnemyDie(a3)
        case 0x17a4a: s1_hWater(a3)
        case 0x17ab4: s1_hWaterDie(a3)
        case 0x17b0c: s1_hRoomGuard(a3)
        case 0x17b76: s1_hRoomGuardDie(a3)
        case 0x17ba4: s1_hitEnemy(a3)
        case 0x1840e: break                       // rts (dead room guard keeps its body)
        // flare
        case 0x19048: s1_hFlareCrosshair(a3)
        case 0x1914c: s1_hFlareRise(a3)
        case 0x19174: s1_hEnemyRise(a3)
        case 0x191a2: s1_hFlareEnemyAim(a3)
        case 0x191cc: s1_hFlareEnemyShoot(a3)
        case 0x1925a: s1_hFlareEnemyDying(a3)
        case 0x192a0: s1_hMuzzleFlash(a3)
        default:
            fatalError(String(format: "section 1: no object handler at $%06X (object $%06X)", addr, a3))
        }
    }
}
