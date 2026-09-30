import AppKit
import PlatoonCore

// Game ▸ Cheats (replaces the old Game ▸ Trainer) and the cheat rows of the pause menu. Model: Prefs/PrefsCheats.swift.

enum CheatsMenu {
    /// The Game ▸ Cheats submenu.
    static func submenu() -> NSMenuItem {
        var items: [NSMenuItem] = [
            ClosureMenuItem("Enable All Cheats", enabled: { CheatPrefs.current != CheatOptions.all }) { CheatPrefs.setAll(true) },
            ClosureMenuItem("Disable All Cheats", enabled: { CheatPrefs.anyOn }) { CheatPrefs.setAll(false) },
            .separator(),
            toggle(CheatPrefs.original, "Original Developer Cheats (CHEAT!!! + MEGA CHEAT)",
                   help: "As if HAMBURGER and KEYPAD- HILL had been typed on the title screen."),
        ]
        for id in ["warp1", "warp2", "warp3", "warp4"] { items.append(action(id)) }
        let inv = ClosureMenuItem("Original Invincibility (F5 / F6)", state: { CheatPrefs.originalInvincibility },
                                  enabled: { CheatPrefs.available(CheatPrefs.action("invOn")) }) { CheatPrefs.toggleOriginalInvincibility() }
        inv.indentationLevel = 1
        inv.toolTip = CheatPrefs.action("invOn").help
        items.append(inv)
        for id in ["skipTunnels", "skipNight", "winGame"] { items.append(action(id)) }
        items.append(.separator())
        for e in CheatPrefs.extras { items.append(toggle(e.key, e.menu, help: e.help)) }
        items.append(.separator())
        items.append(ClosureMenuItem("Cheats Preferences…") { AppServices.shared.openPreferences(tab: .cheats) })
        return ClosureMenuItem.submenu("Cheats", items)
    }

    private static func toggle(_ key: String, _ title: String, help: String) -> NSMenuItem {
        let i = ClosureMenuItem(title, state: { Prefs.bool(key) }) { CheatPrefs.toggle(key) }
        i.toolTip = help
        return i
    }

    private static func action(_ id: String) -> NSMenuItem {
        let a = CheatPrefs.action(id)
        let i = ClosureMenuItem(a.menuTitle, enabled: { CheatPrefs.available(a) }) { CheatPrefs.perform(a) }
        i.indentationLevel = 1
        i.toolTip = a.help + " " + CheatPrefs.unavailableHint
        return i
    }
}

extension FeatureHooks {
    static func cheatsInstall(_ app: AppServices) {
        CheatPrefs.migrateLegacy()

        // pause menu: the original-cheat keys that work right now (hidden elsewhere)
        for (n, id) in ["warp1", "warp2", "warp3", "warp4", "skipTunnels", "skipNight", "winGame"].enumerated() {
            let a = CheatPrefs.action(id)
            app.addPauseMenuItem(PauseMenuItem(id: "cheat." + id, title: { "Cheat: " + a.menuTitle }, order: 250 + n,
                                               isShown: { CheatPrefs.available(a) },
                                               action: { CheatPrefs.perform(a); return true }))
        }
        app.addPauseMenuItem(PauseMenuItem(id: "cheat.inv",
            title: { "Cheat: Original Invincibility " + (CheatPrefs.originalInvincibility ? "Off (F6)" : "On (F5)") }, order: 249,
            isShown: { CheatPrefs.available(CheatPrefs.action("invOn")) },
            action: { CheatPrefs.toggleOriginalInvincibility(); return true }))

        // the Preferences window's action buttons follow the game (section, area, cheat flags)
        var last = ""
        app.onDisplay { ctx in
            let s = CheatPrefs.signature(ctx.game)
            if s != last { last = s; PrefsModel.shared.bump() }
        }
    }
}
