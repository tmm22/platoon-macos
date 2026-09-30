import AppKit
import PlatoonCore

// input: [input] agent — controls, key/controller bindings (S2, S3, S15, M7, M13, L2, S13).
// Only the owner edits this file.
//  - `inputMenus`: Controls & Bindings window (M7), and S3(c) menu items for the Amiga keys that laptops can only
//    reach with fn / F-keys (HELP, keypad minus) plus change soldier / SPACE for players without those keys.
//  - `inputInstall`: the input features (Input/InputFeature.swift).

extension MenuRegistry {
    static func inputMenus(_ app: AppServices) -> [MenuContribution] {
        let hasHost: () -> Bool = { AppServices.shared.host != nil }
        func tap(_ k: UInt8) -> () -> Void { { AppServices.shared.host?.inputManager.amigaTap(k, frames: 5) } }
        return [
            MenuContribution(menu: .game, order: 50, items: [
                ClosureMenuItem("Controls & Bindings…", key: "/", mods: [.command, .option]) { ControlsWindowController.shared.show() },
                ClosureMenuItem.submenu("Send Amiga Key", [
                    ClosureMenuItem("HELP (F11)", enabled: hasHost, tap(0x5f)),
                    ClosureMenuItem("Keypad − (F12)", enabled: hasHost, tap(0x4a)),
                    ClosureMenuItem("SPACE (grenade / flare)", enabled: hasHost, tap(0x40)),
                    ClosureMenuItem("Left Alt (change soldier)", enabled: hasHost, tap(0x64)),
                    ClosureMenuItem("Y (yes)", enabled: hasHost, tap(0x15)),
                    ClosureMenuItem("N (no)", enabled: hasHost, tap(0x36)),
                ]),
            ]),
        ]
    }
}

extension FeatureHooks {
    static func inputInstall(_ app: AppServices) {
        InputFeature.shared.install(app)
    }
}
