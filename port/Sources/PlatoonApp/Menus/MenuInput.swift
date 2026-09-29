import AppKit
import PlatoonCore

// input: [input] agent — controls, key/controller bindings (S2, S3, S15, M7, M13, L2).
// Only the owner edits this file.
//  - `inputMenus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `inputInstall`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func inputMenus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func inputInstall(_ app: AppServices) {
    }
}
