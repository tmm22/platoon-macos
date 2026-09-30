// Cheats: helpers of the `// ENHANCEMENT CHEAT-*` hooks (options: Enhance/CheatOptions.swift). None of this runs
// with every cheat off.

extension Platoon {
    /// CHEAT-ORIG: the RAM effects of the accepted title sequences (k_cheat_check $10e14): HAMBURGER clears the
    /// credits flag $115b3 ("CHEAT!!!") and sets $70(a6) bit 0; KEYPAD- HILL clears $115c2 ("MEGA CHEAT", further
    /// checks off) and sets bit 1.
    func cheatApplyOriginal() {
        let f1 = mem.r8(KA.cheat1Flag), f2 = mem.r8(KA.cheat2Flag)
        if cheatFlagBytes == nil && f1 != 0 && f2 != 0 { cheatFlagBytes = (f1, f2) }
        mem.w8(KA.cheat1Flag, 0)
        mem.w8(KA.cheat2Flag, 0)
        mem.w16(a6 + KV.cheats, mem.r16(a6 + KV.cheats) | 3)
    }

    /// CHEAT-ORIG switched off: undo cheatApplyOriginal (also codes that were typed by hand while it was on).
    func cheatRevertOriginal() {
        guard let (f1, f2) = cheatFlagBytes else { return }
        mem.w8(KA.cheat1Flag, f1)
        mem.w8(KA.cheat2Flag, f2)
        mem.w16(a6 + KV.cheats, mem.r16(a6 + KV.cheats) & ~3)
        k_cheat_reset()
        // the jungle's F5 invincibility could no longer be switched off with F6 (the keys need the flags)
        if loadedSection == 0 { mem.w16(0x60ca0, 0) }
    }

    /// Host: new cheat switches for the running game (PlatoonGame.setCheats; game thread parked).
    func cheatsSetLive(_ c: CheatOptions) {
        let old = enhancements.cheats
        guard c != old else { return }
        enhancements.cheats = c
        for r in c.assistReasons.subtracting(old.assistReasons) { markAssisted(r) }
        // the title flags live in the kernel image: only once k_init ran (else k_title_start applies the switch)
        guard mem.r8(KA.firstBootFlag) != 0 else { return }
        if c.original && !old.original { cheatApplyOriginal() }
        if !c.original && old.original { cheatRevertOriginal() }
    }

    /// CHEAT-MEN: patch up the man record at `a5` (wounds 0) so he can go on.
    func cheatPatchUp(_ a5: UInt32) {
        mem.w16(a5 &+ 4, 0)
    }
}
