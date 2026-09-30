// CHEATS (owner: core). The original developer cheats as a switch, plus extra cheats. Every option is OFF by default
// and gameplay-changing: a game played with any of them on is assisted (F4/S5, never ranked in the original table).
// Hooks in translated code are marked `// ENHANCEMENT CHEAT-<ID>` and read `enhancements.cheats.<field>`:
//
//   CHEAT-ORIG   original      kernel: k_title_start, k_start_new_game (after a carry block), live switch
//                              (Cheats.swift cheatApplyOriginal): the RAM effects of typing HAMBURGER and KEYPAD- HILL
//                              on the title ($115b3 := 0, $115c2 := 0 -> "CHEAT!!!" / "MEGA CHEAT" on the credits page,
//                              $70(a6) |= 3). The section code then offers the original keys (see re/kernel/NOTES.md §g).
//   CHEAT-INV    invincible    S0 hit_ebullet, draw_enemy (contact), trap_update (tripwire), item_booby_trap, the S6
//                              bridge guard (implied, so the bridge runner can't softlock an invincible player);
//                              S1 player_hit (tunnel corridor / room guard / water enemies), enemy_hits_player (flare
//                              night: the enemy keeps shooting harmlessly); S2 player_hit (soldiers, sniper, mines,
//                              barbed wire, Barnes). Not the napalm time-out (see freezeTimer).
//   CHEAT-AMMO   infiniteAmmo  every rifle shot: S0 player_fire_input, S1 input_tunnel / shot_jitter_tunnel /
//                              shot_jitter_flare, S2 pl_shoot.
//   CHEAT-GREN   infiniteGrenades  S0 pf_grenade, S2 throw_grenade.
//   CHEAT-FLARE  infiniteFlares    tunnels: the flare count is kept at the exit's requirement of 8 (the cap of the
//                              BOX OF FLARES pick-up). The flare night is left alone: there the count is the countdown
//                              to dawn (the night is survived when the last flare burns out).
//   CHEAT-MORALE infiniteMorale    morale never drops: S0 main loop (per tick) + morale_sub, S1 morale_sub,
//                              S2 player_hit.
//   CHEAT-TIMER  freezeTimer   kernel vbl_timer: the mission countdown (only the final jungle's 2:00 napalm timer
//                              runs in the game) stands still.
//   CHEAT-MEN    infiniteMen   the platoon can't be wiped out: when the last available soldier is killed he is
//                              patched up (wounds 0) instead of the game ending: S0 man_select, S1 killed_in_action,
//                              S2 obj_player_dead_wait (the usual "ONE MORE CHANCE" restart).
//
// The host may switch cheats while a game runs (`PlatoonGame.setCheats`, from Machine.frameHook): switching one on
// marks the current game assisted. Cheat reasons are per game (not per session): a new game started after
// switching every cheat off is an ordinary game again.

public struct CheatOptions: EnhancementGroup, Equatable {
    public init() {}
    public static let prefix = "cheat"
    public static let title = "Cheats"
    public static let owner = "core (cheats)"

    /// CHEAT-ORIG: the original developer cheats (HAMBURGER + KEYPAD- HILL) are on from the title screen.
    public var original = false
    /// CHEAT-INV: nothing hurts the player.
    public var invincible = false
    /// CHEAT-AMMO: firing does not use rounds.
    public var infiniteAmmo = false
    /// CHEAT-GREN: throwing does not use grenades.
    public var infiniteGrenades = false
    /// CHEAT-FLARE: 8 flares in the tunnels.
    public var infiniteFlares = false
    /// CHEAT-MORALE: morale never drops.
    public var infiniteMorale = false
    /// CHEAT-TIMER: the airstrike countdown stands still.
    public var freezeTimer = false
    /// CHEAT-MEN: the platoon can't be wiped out.
    public var infiniteMen = false

    public static let options: [EnhancementOption<CheatOptions>] = [
        .bool("original", \.original, id: "cheat", gameplay: true,
              help: "Original developer cheats (as if HAMBURGER and KEYPAD- HILL were typed on the title): jungle F1-F4 warps, "
                  + "F5/F6 invincibility; HELP skips the tunnels / the flare night; CAPS LOCK wins the final jungle."),
        .bool("invincible", \.invincible, id: "cheat", gameplay: true,
              help: "Invincibility: bullets, knives, snipers, traps, tripwires, mines, barbed wire and Barnes can't hurt you."),
        .bool("infiniteAmmo", \.infiniteAmmo, id: "cheat", gameplay: true,
              help: "Firing does not use rounds (every section)."),
        .bool("infiniteGrenades", \.infiniteGrenades, id: "cheat", gameplay: true,
              help: "Throwing does not use grenades (jungle and final jungle)."),
        .bool("infiniteFlares", \.infiniteFlares, id: "cheat", gameplay: true,
              help: "Tunnels: you always carry the 8 flares the exit needs (the flare night still ends with the last flare)."),
        .bool("infiniteMorale", \.infiniteMorale, id: "cheat", gameplay: true,
              help: "Morale never drops."),
        .bool("freezeTimer", \.freezeTimer, id: "cheat", gameplay: true,
              help: "Final jungle: the 2:00 countdown to the napalm strike stands still."),
        .bool("infiniteMen", \.infiniteMen, id: "cheat", gameplay: true,
              help: "The platoon can't be wiped out: the last soldier is patched up instead of the game ending."),
    ]

    /// Any cheat on.
    public var anyOn: Bool { self != CheatOptions() }

    /// Assist reasons ("cheat.<key>") of the cheats that are on.
    public var assistReasons: Set<String> {
        let def = CheatOptions()
        return Set(CheatOptions.options.filter { $0.get(self) != $0.get(def) }.map { "cheat.\($0.key)" })
    }

    /// Keys of the cheats (without the prefix), in catalogue order.
    public static var keys: [String] { options.map(\.key) }

    /// All cheats on (original included) / off.
    public static var all: CheatOptions {
        var c = CheatOptions()
        for o in options { try? o.set(&c, "1") }
        return c
    }
}
