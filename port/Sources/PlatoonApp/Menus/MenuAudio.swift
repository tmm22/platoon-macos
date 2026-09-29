import AppKit
import PlatoonCore

// audio: [audio] agent — mixer, voices, audio robustness (S10, S12 sound flags, M12, M22, M25 audio).
// Only the owner edits this file.
//  - `audioMenus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `audioInstall`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func audioMenus(_ app: AppServices) -> [MenuContribution] {
        []
    }
}

extension FeatureHooks {
    static func audioInstall(_ app: AppServices) {
    }
}
