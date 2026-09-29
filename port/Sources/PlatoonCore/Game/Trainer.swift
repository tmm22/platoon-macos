/// Host-side trainer options (enhancement): applied to the platoon's globals (a6 block at $12dde) at the start
/// of every frame while a section is running. Default off = original game. An active trainer marks the running
/// game as assisted (F4/S5: its score goes to the assisted hiscore table, never the original one).
public struct Trainer {
    public var infiniteAmmo = false, infiniteMorale = false, invulnerable = false
    public init(infiniteAmmo: Bool = false, infiniteMorale: Bool = false, invulnerable: Bool = false) {
        self.infiniteAmmo = infiniteAmmo; self.infiniteMorale = infiniteMorale; self.invulnerable = invulnerable
    }
    public var isActive: Bool { infiniteAmmo || infiniteMorale || invulnerable }

    public func apply(to m: Machine) {
        guard isActive else { return }
        PlatoonGame.markAssisted(m, "trainer")
        let a6: UInt32 = 0x12dde, mem = m.memory
        let man = mem.r32(a6 + 0x1e)                                  // current man record (a6 + 6 * index)
        guard man >= a6, man <= a6 + 24, (man - a6) % 6 == 0 else { return }
        if infiniteAmmo { mem.w16(man, 9); mem.w16(man + 2, 0x90) }   // grenades 9, ammo $90
        if infiniteMorale { mem.w16(a6 + 0x2e, 0x9000) }
        if invulnerable && mem.r16(man + 4) < 4 { mem.w16(man + 4, 0) }  // wounds
    }
}
