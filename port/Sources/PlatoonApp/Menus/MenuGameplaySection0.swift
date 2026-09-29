import AppKit
import PlatoonCore

// section0: [section0] agent — jungle & village options (S6, S7, S9 section-0 fixes, M14, M11 section 0).
// Only the owner edits this file.
//  - `gameplaySection0Menus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplaySection0Install`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplaySection0Menus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func gameplaySection0Install(_ app: AppServices) {
    }
}
