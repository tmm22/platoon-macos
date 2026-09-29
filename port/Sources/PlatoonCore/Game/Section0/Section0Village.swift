// Section 0 village: hut doors, entering/leaving huts (player states 4/6), the hut interior (state 5),
// hut occupants (hut-1 trap-door prop, hut-2 VC guard), the search table and the trap door that ends the
// section. Spec: re/village/NOTES.md §b.2-§b.10 (code $17abc-$17ee7, $1880e-$18853).

extension Platoon {
    static let s0HutDoors: UInt32 = 0x1aaf4        // 6 door columns (hut 5..0)
    static let s0VillageItems: UInt32 = 0x1aafa    // 20 x {lo, hi, msg, msg_after}
    static let s0TrapdoorBonus: UInt32 = 0x60c98   // 4-byte BCD, kernel $f80c gets a0 = $60c9c

    // MARK: doors

    /// $1880e hut_door_check: player column must be a door column (low byte compared, dbeq over the 6
    /// table bytes) and |$60c34| must be 7 or < 2. Returns (fail = d7 != 0, d1 = hut number 5..0).
    func s0HutDoorCheck() -> (fail: Bool, hut: UInt16) {
        var a0 = Platoon.s0HutDoors
        let d0 = UInt8(truncatingIfNeeded: v0.pcol)
        var d1: UInt16 = 5
        var found = false
        while true {                                   // cmp.b (a0)+,d0 ; dbeq d1
            let b = mem.r8(a0); a0 &+= 1
            if b == d0 { found = true; break }
            if d1 == 0 { d1 = 0xffff; break }
            d1 &-= 1
        }
        if !found { return (true, d1) }
        let d = s0Abs(v0.c34)
        if d == 7 { return (false, d1) }
        if d >= 2 { return (true, d1) }
        return (false, d1)
    }

    // MARK: state 4 — walking into a hut

    /// $17abc pl_st4_enter_hut: back-view walk frames $11..$14 while y rises to < $3d, then level 5.
    func s0PlSt4EnterHut() {
        v0.pframe = v0.pcnt
        v0.pcnt = (v0.pcnt &+ 1) & 3
        v0.pframe = v0.pframe &+ 0x11
        v0.pfacing = 0
        v0.pathofs = v0.pathofs &- 2
        v0.py = v0.pathofs &+ 0x38
        if v0.py >= 0x3d { return }
        v0.pfacing = v0.savefacing
        s0EnemyReset()
        v0.pstate = 5
        v0.level = 5
        s0HutSetupEnemy()
        s0LevelEnter()
    }

    /// $17b2c hut_setup_enemy: hut 1 = trap-door prop (dummy enemy state 4), hut 2 = VC guard (or his body).
    /// Also called every tick by en_st0_spawn while the enemy state is 0 on level 5.
    func s0HutSetupEnemy() {
        if v0.hut == 1 { s0HutSetupDoor2(); return }
        if v0.hut != 2 { return }
        v0.efacing = 1
        v0.eframe = 0x33                              // dead body
        if v0.hutKilled == 0 {
            v0.eframe = 0x34                          // aiming
            v0.ecnt = 0xf                             // first shot after 15 ticks
        }
        v0.estate = 4
        mem.w32(0x5f88a, 0x00d0_003d)
        var d0 = v0.pworld &- 0x1e4
        d0 = d0 &<< 3                                 // asl.w #3
        d0 = 0 &- d0
        v0.ex = v0.ex &+ d0
    }

    /// $17b96 hut_setup_door2 (hut 1): trap-door prop position; dummy enemy state 4 (frame 0 = invisible).
    func s0HutSetupDoor2() {
        v0.efacing = 0
        mem.w32(0x60c72, 0x00d0_003d)
        var d0 = v0.pworld &- 0x1bc
        d0 = d0 &<< 3
        d0 = 0 &- d0
        v0.hutPropX = v0.hutPropX &+ d0
        v0.estate = 4
    }

    // MARK: state 5 — inside a hut

    /// $17bc4 pl_st5_in_hut: trap door (hut 1), UP = search (once per press), DOWN at the door = leave.
    func s0PlSt5InHut() {
        mem.w32(0x5f880, 0x0094_003d)
        if v0.align != 0 { s0PlKeepWalking(); return }
        if v0.T == 0x35 && v0.c34 == 0 && v0.align == 0 && v0.pfacing == 0 {
            s0TrapdoorPrompt()
            v0.input = (v0.input | 0x08) & ~0x02      // fake LEFT: turn round and step away
            s0ToggleFacing()
            k_wait_swap()
        }
        // ih_input $17c20
        let d0 = v0.input & 5
        if d0 == 0 || d0 == 5 {
            v0.searchLatch = 0
            s0PlHorizontal()
            return
        }
        if d0 & 4 != 0 {                              // UP: search
            if v0.searchLatch == 0 { s0HutSearch() }
            v0.searchLatch = 0xff
            v0.pframe = 0x11
            return
        }
        // ih_down_leave $17c66
        v0.searchLatch = 0
        if s0HutDoorCheck().fail {
            v0.pframe = 8
            return
        }
        v0.pathofs = 0xfff2
        v0.pstate = 6
        v0.savefacing = v0.pfacing
    }

    /// $17c9c hut_search: every table entry whose [lo,hi] contains ($60c30-$18f).b gives a beep and a
    /// message; torch, booby trap and map entries have handlers that return the message number.
    /// (The original pushes $17cfa so that the handlers "rts" into the `jsr k_message` of the loop.)
    func s0HutSearch() {
        let d0w = v0.pworld &- 0x18f
        var d1: UInt16 = 0x13
        var a0 = Platoon.s0VillageItems
        while true {
            let d0 = UInt8(truncatingIfNeeded: d0w)
            // cmp.b d0+1,(a0) ; bcc skip   /   cmp.b d0,1(a0) ; bcs skip
            if !(mem.r8(a0) >= d0 &+ 1) && !(mem.r8(a0 &+ 1) < d0) {
                s0Sfx(0)
                let msg: UInt16
                switch mem.r8(a0 &+ 2) {
                case 0x10: msg = s0ItemTorch()
                case 0x0f: msg = s0ItemBoobyTrap(a0)
                case 0x17: msg = s0ItemMap()
                default:   msg = mem.r16(a0 &+ 2)       // kernel masks d0 with $ff -> byte 3 (msg_after)
                }
                k_queue_text(msg)
            }
            a0 &+= 4
            if d1 == 0 { break }
            d1 &-= 1
        }
    }

    /// $17d0c item_booby_trap: explosion at the player, one-shot (byte 2 := byte 3), kills the man.
    func s0ItemBoobyTrap(_ a0: UInt32) -> UInt16 {
        v0.explFrame = 0
        v0.explTimer = 3
        v0.explX = v0.px
        v0.explY = 0x3d
        mem.w8(a0 &+ 2, mem.r8(a0 &+ 3))
        s0PlayerHit()
        mem.w16(s0Man &+ 4, 3)
        return 0xf
    }

    /// $17d46 item_food (the torch spot): first time torch + morale + 500 points, later "A POT OF RICE".
    func s0ItemTorch() -> UInt16 {
        if v0.torch != 0 { return 3 }
        v0.torch = 0xff
        v0.morale = v0.morale &+ 0x200
        k_add_score(after: Platoon.s0Score500End)
        return 2
    }

    /// $17d74 item_map: needs the hut-2 guard dead; sets the map flag (HUD icon), morale, 500 points.
    func s0ItemMap() -> UInt16 {
        if v0.mapFound != 0 { return 7 }
        if v0.hutKilled == 0 { return 7 }
        mem.w8(a6 + 0x24, 0xff)                        // st.b $24(a6)
        k_hud_icons()
        v0.morale = v0.morale &+ 0x200
        k_add_score(after: Platoon.s0Score500End)
        return 8
    }

    // MARK: trap door

    /// $17dae trapdoor_prompt: own render loop until N (wait for the message queue to empty and return)
    /// or Y (without torch: message $d and return; with torch: bonus, dissolve, next section).
    func s0TrapdoorPrompt() {
        while true {
            tickPoint(0x17dae)
            s0ReadInput()
            if v0.msgCount == 0 { k_queue_text(0xb) }
            k_wait_swap()
            _ = s0DrawTiles()
            s0DrawEnemy()
            v0.pframe = 8
            s0DrawPlayer()
            s0Settle()
            k_swap()
            s0Dbg("017de4")
            if r_keytest(0x36) { s0WaitMessages(); return }     // N
            if !r_keytest(0x15) { continue }                     // Y?
            if v0.torch == 0 { k_queue_text(0xd); return }      // YOU NEED TO FIND A TORCH
            s0TrapdoorYes()
        }
    }

    /// $17e12 trapdoor_yes: +1000 BCD per living man (counting 5 records from the CURRENT man, quirk),
    /// dissolve out, kernel $f874 (load the next section).
    func s0TrapdoorYes() -> Never {
        var a5 = s0Man
        var d1: UInt32 = 0
        for _ in 0...4 {
            if mem.r16(a5 &+ 4) < 4 { d1 &+= 0x1000 }
            a5 &+= 6
        }
        mem.w32(Platoon.s0TrapdoorBonus, d1)
        k_add_score(after: Platoon.s0TrapdoorBonus &+ 4)
        s0DissolveOut(a1: Platoon.s0DissolveA1Trapdoor, d4: Platoon.s0DissolveD4Trapdoor)
        s0ReadInput()
        k_next_section()
    }

    /// $17e52 wait_messages: every 3 vblanks read input until the message queue is empty.
    func s0WaitMessages() {
        repeat {
            tickPoint(0x17e52)
            k_wait_vbl(); k_wait_vbl(); k_wait_vbl()
            s0ReadInput()
        } while v0.msgCount != 0
    }

    // MARK: state 6 — leaving a hut

    /// $17e72 pl_st6_leave_hut: front-view walk frames $0d..$10 down to y $50, then level 0.
    func s0PlSt6LeaveHut() {
        v0.pframe = v0.pcnt
        v0.pcnt = (v0.pcnt &+ 1) & 3
        v0.pframe = v0.pframe &+ 0xd
        v0.pfacing = 0
        v0.pathofs = v0.pathofs &+ 2
        v0.py = v0.pathofs &+ 0x50
        if v0.py != 0x50 { return }
        v0.pstate = 0
        v0.pframe = 0
        v0.level = 0
        v0.estate = 0
        v0.eframe = 0
        v0.pfacing = v0.savefacing
        s0LevelEnter()
    }
}
