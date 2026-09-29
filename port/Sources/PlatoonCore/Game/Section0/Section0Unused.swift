// Section 0 code that the original never executes (kept for completeness of the translation; nothing calls
// these). Spec: re/jungle/NOTES.md §b.13.

extension Platoon {
    /// $19002-$19027 dead_19002: unreachable tail of trap_update (after `bra trap_draw`): an older
    /// "booby trap kills the enemy" test. Translated as written (never called).
    func s0DeadTrapKillsEnemy() {
        var d0 = v0.trapX
        if d0 >= v0.ex { s0TrapDraw(); return }
        d0 = d0 &+ 8
        if d0 >= v0.ex { s0TrapDraw(); return }
        s0EnemyKilledCommon()
        // L_018fe0: trap explodes
        v0.trapState = 2
        v0.trapxTimer = 3
        v0.trapxFrame = 0
        s0Sfx(0x85)
    }

    /// $19b1a-$19b70 unused_19b1a: unreferenced 17-pass wipe over the displayed buffer ($62(a6)^$8000):
    /// every even byte shifted right, every odd byte shifted left, one vblank per pass.
    func s0UnusedWipe() {
        let base = v0.backBuf ^ 0x8000
        for _ in 0...0x10 {
            var a0 = base
            for _ in 0...0xb3f {
                for k in 0..<8 {
                    let b = mem.r8(a0)
                    mem.w8(a0, k & 1 == 0 ? b >> 1 : b << 1)
                    a0 &+= 1
                }
            }
            k_wait_vbl()
        }
    }

    /// $19f88-$19fb8 unused_kernel_stubs / misc_19f92 / misc_19f9c / misc_19fa6: print d0 in hex (kernel
    /// jt07-jt10: 8/4/2/1 digits) followed by ',' ($404 putchar). Unreferenced debug helpers.
    func s0UnusedHexComma(digits: Int, _ d0: UInt32) {
        switch digits {
        case 8: k_hex32(d0)
        case 4: k_hex16(UInt16(truncatingIfNeeded: d0))
        case 2: k_hex8(UInt8(truncatingIfNeeded: d0))
        default: k_hex4(UInt8(truncatingIfNeeded: d0))
        }
        r_putchar(0x2c)
    }

    /// $19fba misc_19fba: prints "ESCAPE" ($19fc8) and enters the debug monitor with TRAP #14.
    /// Unreferenced; the debug monitor is not part of the port (PORTING.md rule 10).
    func s0UnusedEscapeToMonitor() -> Never {
        r_print(0x19fc8)
        log("section 0: TRAP #14 (debug monitor) — not translated")
        fatalError("section 0 debug monitor entry ($19fba) is not translated")
    }
}
