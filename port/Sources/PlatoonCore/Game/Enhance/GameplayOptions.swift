// Cross-section gameplay options (owner: core defines the flags; the section owners implement the section parts).
//
// M15 full platoon / extra lives (port/ENHANCEMENT_IDEAS.md M15):
//   game.lives        2 = original (sections 1 and 2 use men 0 and 1 only). 3..5: allow that many men in S1/S2 by
//                     replacing the `$22(a6) == 1` / `a6+6` second-man logic with "next record with hits < 4".
//                     Hooks: section1 (section1_start ~180, s1_killedInAction), section2 (s2_fj_entry, s2_second_chance).
//   game.fullPlatoon  also carry wounds / ammo / KIA over from the jungle: S1/S2 skip their men re-init loops, and the
//                     kernel's k_section_start picks the first living man (KernelFlow.swift, ENHANCEMENT M15).
// Both taint the run (S2 becomes much easier: each death restarts at room 105 with a fresh 2:00).

public struct GameplayOptions: EnhancementGroup {
    public init() {}
    public static let prefix = "game"
    public static let title = "Gameplay (all sections)"
    public static let owner = "core (flags) / section1, section2 (hooks)"

    /// M15 (a): men available in sections 1 and 2 (2 = original).
    public var lives = 2
    /// M15 (b): the jungle platoon (wounds, ammo, KIA) carries over into sections 1 and 2.
    public var fullPlatoon = false

    public static let options: [EnhancementOption<GameplayOptions>] = [
        .int("lives", \.lives, range: 2...5, id: "M15", gameplay: true,
             help: "Soldiers available in the tunnels and the final jungle (original 2)."),
        .bool("fullPlatoon", \.fullPlatoon, id: "M15", gameplay: true,
              help: "Your jungle platoon (wounds, ammo, killed men) carries over into the later sections."),
    ]

    /// True when men beyond the original two may play in sections 1/2.
    public var extendedMen: Bool { lives != 2 || fullPlatoon }
}
