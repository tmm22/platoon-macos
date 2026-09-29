import AppKit
import PlatoonCore

// section1: [section1] agent — tunnels & flare options (M4, S9 section-1 fixes).
// Only the owner edits this file.
//  - `gameplaySection1Menus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplaySection1Install`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplaySection1Menus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func gameplaySection1Install(_ app: AppServices) {
    }
}
