import AppKit
import PlatoonCore

// presentation: [presentation] agent — renderer, shaders, framing looks (S14, S16, M19, M20, M21, M24).
// Only the owner edits this file.
//  - `videoMenus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `videoInstall`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func videoMenus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func videoInstall(_ app: AppServices) {
    }
}
