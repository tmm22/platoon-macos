import AppKit
import PlatoonCore

// section2: [section2] agent — final jungle & foxhole options (M5 navigator, M25 room slide, M15, S9 section-2 fixes).
// Only the owner edits this file.
//  - `gameplaySection2Menus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplaySection2Install`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplaySection2Menus(_ app: AppServices) -> [MenuContribution] {
        let levels: [(Int, String)] = [(0, "Off"), (1, "Heading"), (2, "Heading + Map"), (3, "Heading + Map + Route Guide")]
        let items = levels.map { v, t in
            ClosureMenuItem(t, state: { Prefs.int("section2.navigator") == v }) { Prefs.set("section2.navigator", v) }
        }
        let cycle = ClosureMenuItem("Cycle Final Jungle Navigator", key: "j", mods: [.command, .shift]) {
            let v = (Prefs.int("section2.navigator") + 1) % 4
            Prefs.set("section2.navigator", v)
            AppServices.shared.toast("Final jungle navigator: \(levels[v].1)")
        }
        return [
            MenuContribution(menu: .assist, order: 150, items: [ClosureMenuItem.submenu("Final Jungle Navigator", items + [.separator(), cycle])]),
            MenuContribution(menu: .view, order: 150, items: [
                ClosureMenuItem("Final Jungle Room Slide", state: { Prefs.bool("section2.roomSlide") }) {
                    Prefs.set("section2.roomSlide", !Prefs.bool("section2.roomSlide"))
                },
            ]),
        ]
    }
}

extension FeatureHooks {
    static func gameplaySection2Install(_ app: AppServices) {
        let nav = FinalNavigatorPanel()
        let slide = FinalRoomSlidePanel()
        app.overlay.add(slide)
        app.overlay.add(nav)
        app.onFrame { ctx in
            FinalNavigatorModel.shared.frame(ctx)
            slide.frame(ctx)
        }
        // The overlay manager updates only visible panels; hidden ones are polled here so they can show themselves
        // (the manager then updates them itself from the same display frame on).
        app.onDisplay { ctx in
            if !nav.isVisible { nav.update(ctx) }
            if !slide.isVisible { slide.update(ctx) }
        }
        app.onReset { _ in FinalNavigatorModel.shared.reset() }
        app.onSectionStart { s in if s == 2 { FinalNavigatorModel.shared.reset() } }
        Prefs.observe("section2.navigator") { app.overlay.setNeedsLayout() }
        Prefs.observe("section2.navigatorPlace") { app.overlay.setNeedsLayout() }
        // N (Mac keycode 0x2d) in the final jungle hides / shows the navigator, only while it is switched on (the
        // game never reads N in section 2; with the navigator off the key goes to the game unchanged).
        app.keyHooks.append { code, down, isRepeat in
            guard code == 0x2d, FinalNavigatorModel.shared.level != .off,
                  AppServices.shared.host?.probe.context.section == 2 else { return false }
            if down && !isRepeat { FinalNavigatorModel.shared.userHidden.toggle() }
            return true
        }
        app.addPauseMenuItem(PauseMenuItem(id: "section2.navigator",
                                           title: {
                                               let m = FinalNavigatorModel.shared
                                               return m.level != .off && !m.userHidden ? "Hide Final Jungle Navigator"
                                                                                        : "Show Final Jungle Navigator"
                                           },
                                           order: 225,
                                           isEnabled: { AppServices.shared.host?.probe.context.section == 2 },
                                           action: {
                                               let m = FinalNavigatorModel.shared
                                               if m.level == .off { Prefs.set("section2.navigator", 2); m.userHidden = false }
                                               else { m.userHidden.toggle() }
                                               return true
                                           }))
    }
}
