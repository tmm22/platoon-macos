import AppKit
import PlatoonCore

// section0: [section0] agent — jungle & village options (S6, S7, S9 section-0 fixes, M14, L3, M6 map, L4 widescreen).
// Only the owner edits this file.
//  - `gameplaySection0Menus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplaySection0Install`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplaySection0Menus(_ app: AppServices) -> [MenuContribution] {
        [
            MenuContribution(menu: .view, order: 120, items: [
                ClosureMenuItem("Widescreen Jungle", state: { Prefs.bool(JungleWideController.kEnabled) }) {
                    Prefs.set(JungleWideController.kEnabled, !Prefs.bool(JungleWideController.kEnabled))
                },
            ]),
        ]
    }
}

extension FeatureHooks {
    static func gameplaySection0Install(_ app: AppServices) {
        let map = JungleMapPanel.shared, hint = JungleHintPanel.shared, wide = JungleWideController.shared
        app.overlay.add(map)
        app.overlay.add(hint.panel)
        app.overlay.add(wide.left)
        app.overlay.add(wide.right)

        app.onFrame { ctx in
            map.sample(ctx)
            wide.frame(ctx)
        }
        app.onDisplay { ctx in
            map.refresh(ctx)
            hint.update(ctx)
            wide.display(ctx)
        }
        app.onSectionStart { s in
            guard s == 0 else { return }
            map.sectionStarted()
            hint.reset()
            if let seed = Section0Prefs.runSeed { app.toast("Village randomised (seed \(seed))", seconds: 3) }
        }
        app.onHostReady { host in wide.attach(host) }
        app.onReset { host in wide.attach(host) }
        Prefs.observe(JungleWideController.kEnabled) { if let h = app.host { wide.attach(h) } }
        for k in [JungleMapPanel.kEnabled, JungleMapPanel.kSpoilers, JungleMapPanel.kFog, JungleMapPanel.kSize, JungleMapPanel.kPlace] {
            Prefs.observe(k) { app.overlay.setNeedsLayout() }
        }

        // M: show/hide the jungle map (only while it is enabled and the jungle is on screen; otherwise M reaches
        // the game as before)
        var mDown = false
        app.keyHooks.append { code, down, isRepeat in
            guard code == 0x2e else { return false }
            if !down { let was = mDown; mDown = false; return was }
            guard map.enabled, let h = app.host, JungleMapPanel.inJungle(FrameContext(host: h)) else { return false }
            if !isRepeat { map.userHidden.toggle(); map.refresh(FrameContext(host: h)) }
            mDown = true
            return true
        }
        app.addPauseMenuItem(PauseMenuItem(id: "section0.map",
            title: { map.userHidden || !map.isVisible ? "Show Jungle Map" : "Hide Jungle Map" },
            order: 220,
            isEnabled: { map.enabled && app.host.map { JungleMapPanel.inJungle(FrameContext(host: $0)) } == true },
            action: { map.userHidden.toggle(); if let h = app.host { map.refresh(FrameContext(host: h)) }; return false }))
    }
}
