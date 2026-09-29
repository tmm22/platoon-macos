import AppKit
import PlatoonCore

// section2: [section2] agent — final jungle & foxhole options (M15, S9 section-2 fixes).
// Only the owner edits this file.
//  - `gameplaySection2Menus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplaySection2Install`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplaySection2Menus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func gameplaySection2Install(_ app: AppServices) {
    }
}
