import AppKit
import PlatoonCore

// core: [core] agent — core gameplay options: difficulty presets (M10), assisted-run/hiscore policy (S5), enhancement registry.
// Only the owner edits this file.
//  - `gameplayCoreMenus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `gameplayCoreInstall`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func gameplayCoreMenus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func gameplayCoreInstall(_ app: AppServices) {
    }
}
