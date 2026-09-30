import AppKit
import PlatoonCore

// section1: [section1] agent — tunnels & flare options (M3 automap, M4, S9 section-1 fixes, M25 turn slide).
// Only the owner edits this file.
//  - `gameplaySection1Menus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplaySection1Install`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplaySection1Menus(_ app: AppServices) -> [MenuContribution] {
        []   // "Show the tunnel map" is in the Assist menu through its pref (.inMenu(.assist))
    }
}

extension FeatureHooks {
    static func gameplaySection1Install(_ app: AppServices) {
        let map = TunnelMapPanel.shared, slide = TunnelTurnSlide.shared
        app.overlay.add(map)
        app.overlay.add(slide)
        app.onFrame { ctx in map.sample(ctx) }
        app.onDisplay { ctx in slide.displayed(ctx); map.refresh(ctx) }
        app.onSectionStart { s in if s == 1 { map.sectionStarted() } }
        app.onHostReady { host in
            host.probe.addObserver { r in if case .newGame = r.event { map.sectionStarted() } }
            host.probe.onMessage { msg in if msg.section == 1, map.enabled { map.model.message(msg.index) } }
        }
        // M (Mac keycode 0x2e): show/hide the map in the tunnels (only while the option is on; otherwise the key goes
        // to the game, which never reads it in section 1).
        app.keyHooks.append { code, down, isRepeat in
            guard code == 0x2e, map.enabled, AppServices.shared.host?.probe.context.area == .tunnels else { return false }
            if down && !isRepeat { map.userHidden.toggle(); map.refresh(nil) }
            return true
        }
        app.addPauseMenuItem(PauseMenuItem(id: "section1.tunnelMap",
                                           title: { map.enabled && !map.userHidden ? "Hide Tunnel Map" : "Show Tunnel Map" },
                                           order: 220,
                                           isEnabled: { AppServices.shared.host?.probe.context.section == 1 },
                                           isShown: { AppServices.shared.host?.probe.context.section == 1 },
                                           action: {
                                               if !map.enabled { Prefs.set(TunnelMapPanel.kEnabled, true); map.userHidden = false }
                                               else { map.userHidden.toggle() }
                                               return true
                                           }))
    }
}
