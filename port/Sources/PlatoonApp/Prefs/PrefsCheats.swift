import AppKit
import PlatoonCore

// Cheats tab (Preferences ▸ Cheats) and the shared model of Game ▸ Cheats and the pause-menu cheat rows.
// The switches are the core's cheat options (Enhance/CheatOptions.swift, `cheat.*` enhancement keys): every one is
// off by default, they apply at once (GameHost.syncCheats pushes them into the running game every frame) and any of
// them marks the game as assisted (it goes to the assisted high-score table, never the original one).
// The actions tap the original developer-cheat keys; they are enabled only where the game reads the key
// (GameContext: section, area, screen, and the cheat flags $70(a6)).

enum CheatPrefs {
    /// UserDefaults keys = the core enhancement keys.
    static let original = "cheat.original"
    static let invincible = "cheat.invincible"
    static let ammo = "cheat.infiniteAmmo"
    static let grenades = "cheat.infiniteGrenades"
    static let flares = "cheat.infiniteFlares"
    static let morale = "cheat.infiniteMorale"
    static let timer = "cheat.freezeTimer"
    static let men = "cheat.infiniteMen"

    /// The extra cheats: key, title (Preferences), menu title, help.
    static let extras: [(key: String, title: String, menu: String, help: String)] = [
        (invincible, "Invincibility", "Invincibility",
         "Nothing can hurt you in any section: bullets, knives and bodily contact, the hut guard, snipers, tripwires and "
            + "booby traps, the tunnel and water enemies, the flare-night enemies, mines, barbed wire and Barnes. "
            + "(In the jungle it also stops you before the bridge while it isn't mined, like \"Bridge failsafe\". The napalm "
            + "strike at 0:00 still comes: use Freeze the airstrike timer.)"),
        (ammo, "Infinite ammunition", "Infinite Ammunition", "Firing never uses rounds (all sections)."),
        (grenades, "Infinite grenades", "Infinite Grenades", "Throwing never uses grenades (jungle and final jungle)."),
        (flares, "Infinite flares (tunnels)", "Infinite Flares (Tunnels)",
         "You always carry the 8 flares the tunnel exit asks for. In the flare night the flares count down to dawn "
            + "(the night is over when the last one burns out), so they are used up there as usual."),
        (morale, "Infinite morale", "Infinite Morale", "Morale never drops (no loss per hit, per villager or over time)."),
        (timer, "Freeze the airstrike timer", "Freeze the Airstrike Timer",
         "Final jungle: the two-minute countdown to the napalm strike stands still."),
        (men, "Infinite soldiers", "Infinite Soldiers",
         "The platoon can't be wiped out: when your last soldier is killed he is patched up and carries on (the "
            + "section's usual \"one more chance\" restart). Morale at zero still ends the game."),
    ]
    static var allKeys: [String] { [original] + extras.map(\.key) }

    /// The cheat switches as the preferences hold them.
    static var current: CheatOptions {
        var c = CheatOptions()
        c.original = Prefs.bool(original); c.invincible = Prefs.bool(invincible)
        c.infiniteAmmo = Prefs.bool(ammo); c.infiniteGrenades = Prefs.bool(grenades); c.infiniteFlares = Prefs.bool(flares)
        c.infiniteMorale = Prefs.bool(morale); c.freezeTimer = Prefs.bool(timer); c.infiniteMen = Prefs.bool(men)
        return c
    }
    static var anyOn: Bool { current.anyOn }

    static func setAll(_ on: Bool) {
        for k in allKeys where Prefs.bool(k) != on { Prefs.set(k, on) }
        PrefsModel.shared.bump()
        AppServices.shared.toast(on ? "All cheats on — this game is marked as assisted" : "All cheats off", seconds: 2.5)
    }
    static func toggle(_ k: String) {
        Prefs.set(k, !Prefs.bool(k))
        PrefsModel.shared.bump()
    }

    /// One-time migration of the old Game ▸ Trainer switches (UserDefaults cheatAmmo / cheatMorale / cheatInvuln).
    static func migrateLegacy() {
        let d = UserDefaults.standard
        let map: [(old: String, new: [String])] = [("cheatAmmo", [ammo, grenades]), ("cheatMorale", [morale]), ("cheatInvuln", [invincible])]
        for (old, new) in map where d.object(forKey: old) != nil {
            if d.bool(forKey: old) { for k in new where d.object(forKey: k) == nil { d.set(true, forKey: k) } }
            d.removeObject(forKey: old)
        }
    }

    // MARK: original-cheat key actions

    struct Action {
        let id: String
        let title: String
        let key: UInt8
        let keyName: String
        let section: Int
        let areas: Set<GameContext.Area>
        /// Bits of $70(a6) the section code tests (jungle: any, tunnels / final jungle: MEGA CHEAT).
        let flags: Int
        let help: String
        var menuTitle: String { "\(title) (\(keyName))" }
    }
    static let jungle: Set<GameContext.Area> = [.jungle, .village, .hut]
    static let actions: [Action] = [
        Action(id: "warp1", title: "Warp to the Start", key: 0x50, keyName: "F1", section: 0, areas: jungle, flags: 3,
               help: "Restart the jungle at its start (level 1, column 5). Every warp re-equips all five soldiers."),
        Action(id: "warp2", title: "Warp Near the Explosives", key: 0x51, keyName: "F2", section: 0, areas: jungle, flags: 3,
               help: "Restart on the rear path (level 4, column 45), just before the box of explosives."),
        Action(id: "warp3", title: "Warp to the Bridge", key: 0x52, keyName: "F3", section: 0, areas: jungle, flags: 3,
               help: "Restart on the river path (level 1, column 65), just before the bridge."),
        Action(id: "warp4", title: "Warp to the Village", key: 0x53, keyName: "F4", section: 0, areas: jungle, flags: 3,
               help: "Restart in the village street (level 0, column 65)."),
        Action(id: "invOn", title: "Original Invincibility On", key: 0x54, keyName: "F5", section: 0, areas: jungle, flags: 3,
               help: "The developers' invincibility (jungle & village only; \"CHEAT!\" is shown while it is on)."),
        Action(id: "invOff", title: "Original Invincibility Off", key: 0x55, keyName: "F6", section: 0, areas: jungle, flags: 3,
               help: "Switch the developers' invincibility off again."),
        Action(id: "skipTunnels", title: "Skip to the Flare Night", key: 0x5f, keyName: "HELP", section: 1, areas: [.tunnels], flags: 2,
               help: "Leave the tunnels at once with 9 flares (\"LET'S GO TO THE FLARE SCREEN!\")."),
        Action(id: "skipNight", title: "Survive the Night", key: 0x5f, keyName: "HELP", section: 1, areas: [.flare], flags: 2,
               help: "End the flare night as survived (\"WELL DONE, YOU MADE IT THROUGH THE NIGHT\"): on to the final jungle."),
        Action(id: "winGame", title: "Win the Game", key: 0x62, keyName: "CAPS LOCK", section: 2, areas: [.finalJungle, .bunker], flags: 2,
               help: "Final jungle: \"YOU MADE IT! A HUEY IS ON IT'S WAY...\" at once (then the usual game over and high score)."),
    ]
    static func action(_ id: String) -> Action { actions.first { $0.id == id }! }

    static var context: GameContext? { AppServices.shared.host?.probe.context }

    /// The action's key does something right now.
    static func available(_ a: Action, _ c: GameContext? = context) -> Bool {
        guard let c, c.screen == .playing, c.section == a.section, a.areas.contains(c.area) else { return false }
        return c.cheats & a.flags != 0
    }
    /// Why an action is greyed out (for help texts).
    static var unavailableHint: String {
        "Needs the original cheats (the switch above, or HAMBURGER / KEYPAD- HILL typed on the title) and the right part of the game."
    }
    static func perform(_ a: Action) {
        guard let h = AppServices.shared.host, available(a) else { return }
        h.holdKey(a.key)
    }

    /// The developers' invincibility flag of the jungle ($60ca0, section 0 RAM).
    static var originalInvincibility: Bool {
        guard let h = AppServices.shared.host, h.probe.context.loadedSection == 0 else { return false }
        return h.machine.memory.r16(0x60ca0) != 0
    }
    static func toggleOriginalInvincibility() {
        perform(action(originalInvincibility ? "invOff" : "invOn"))
    }

    /// Changes whenever the enabling of an action may change (to refresh the Preferences window).
    static func signature(_ c: GameContext) -> String {
        "\(c.screen.rawValue)/\(c.area.rawValue)/\(c.section ?? -1)/\(c.cheats)/\(originalInvincibility)"
    }
}

extension PrefsRegistry {
    static var cheatSections: [PrefSection] {
        func cheatToggle(_ key: String, _ title: String, _ help: String) -> PrefItem {
            // live (no restart): GameHost.syncCheats applies the value to the running game at once
            var i = PrefItem(key: key, title: title, kind: .toggle(default: false), help: help)
            i.isGameplay = true
            i.enhancement = key
            return i
        }
        func buttons(_ key: String, _ title: String, _ ids: [String], help: String) -> PrefItem {
            .buttons(key, title, help: help, ids.map { id in
                let a = CheatPrefs.action(id)
                return PrefButton(title: "\(a.title.replacingOccurrences(of: "Warp to the ", with: "").replacingOccurrences(of: "Warp ", with: "")) (\(a.keyName))",
                                  help: a.help, enabled: { CheatPrefs.available(a) }, run: { CheatPrefs.perform(a) })
            })
        }
        return [
            PrefSection(tab: .cheats, title: "All cheats", footer: "Cheats take effect at once. A game played with any cheat "
                        + "on (the original ones too) is marked as assisted: its score goes to the assisted high-score table "
                        + "(hiscores-assisted.bin), never to the original one. Switching them all off makes the next new game an "
                        + "ordinary one again.", order: 0, items: [
                .buttons("cheat.all", "Every cheat below", [
                    PrefButton(title: "Enable All Cheats", enabled: { !(CheatPrefs.current == CheatOptions.all) }) { CheatPrefs.setAll(true) },
                    PrefButton(title: "Disable All Cheats", enabled: { CheatPrefs.anyOn }) { CheatPrefs.setAll(false) },
                ]),
            ]),
            PrefSection(tab: .cheats, title: "Original developer cheats", footer: "The game's own cheats, normally switched on "
                        + "by typing HAMBURGER and then KEYPAD- HILL on the title screen. The buttons press the keys for you and "
                        + "work where the game reads them. " + CheatPrefs.unavailableHint, order: 10, items: [
                cheatToggle(CheatPrefs.original, "Original developer cheats (CHEAT!!! + MEGA CHEAT)",
                            "As if both codes had been typed: the credits page shows MEGA CHEAT, and the keys below work."),
                buttons("cheat.act.warp", "Jungle: warp", ["warp1", "warp2", "warp3", "warp4"],
                        help: "F1-F4 restart the jungle at one of four places (every warp re-equips all five soldiers)."),
                buttons("cheat.act.inv", "Jungle: invincibility", ["invOn", "invOff"],
                        help: "F5 / F6: the developers' own invincibility, jungle and village only (\"CHEAT!\" is shown while on)."),
                buttons("cheat.act.s1", "Tunnels / flare night", ["skipTunnels", "skipNight"],
                        help: "HELP: in the tunnels, go straight to the flare night (with 9 flares); in the flare night, survive it at once."),
                buttons("cheat.act.s2", "Final jungle", ["winGame"],
                        help: "CAPS LOCK: \"YOU MADE IT!\" - the game is won at once."),
            ]),
            PrefSection(tab: .cheats, title: "Extra cheats", order: 20,
                        items: CheatPrefs.extras.map { cheatToggle($0.key, $0.title, $0.help) }),
        ]
    }
}
