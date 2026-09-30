import AppKit
import PlatoonCore

// input: [input] agent — controls, key/controller bindings (S2, S3, S15, M7, M13, L2, S13).
// Only the owner edits this file.
//  - `inputMenus`: S3(c) menu items for the Amiga keys that laptops can only reach with fn / F-keys (HELP, keypad
//    minus) plus SPACE / change soldier / Y / N for players without those keys.
//  - `inputInstall`: the input features (Input/InputFeature.swift), and M7: the app's Game ▸ Controls… (⌘/) item is
//    retargeted at launch to the Controls & Bindings window (the old NSAlert stays the fallback if that fails).

extension MenuRegistry {
    static func inputMenus(_ app: AppServices) -> [MenuContribution] {
        let hasHost: () -> Bool = { AppServices.shared.host != nil }
        func tap(_ k: UInt8) -> () -> Void { { AppServices.shared.host?.inputManager.amigaTap(k, frames: 5) } }
        return [
            MenuContribution(menu: .game, order: 50, items: [
                ClosureMenuItem.submenu("Send Amiga Key", [
                    ClosureMenuItem("HELP (F11)", enabled: hasHost, tap(0x5f)),
                    ClosureMenuItem("Keypad − (F12)", enabled: hasHost, tap(0x4a)),
                    ClosureMenuItem("SPACE (grenade / flare)", enabled: hasHost, tap(0x40)),
                    ClosureMenuItem("Left Alt (change soldier)", enabled: hasHost, tap(0x64)),
                    ClosureMenuItem("Y (yes)", enabled: hasHost, tap(0x15)),
                    ClosureMenuItem("N (no)", enabled: hasHost, tap(0x36)),
                    ClosureMenuItem("TAB (in-game pause)", enabled: hasHost, tap(0x42)),
                    ClosureMenuItem("F10 (music / sound effects)", enabled: hasHost, tap(0x59)),
                ]),
            ]),
        ]
    }
}

/// Target of the retargeted Controls… menu item.
final class InputMenuTarget: NSObject {
    static let shared = InputMenuTarget()
    @objc func showControlsWindow(_ s: Any?) { ControlsWindowController.shared.show() }

    /// Points every main-menu item whose action is `showControls:` at the Controls & Bindings window.
    /// Returns the number of items retargeted.
    @discardableResult
    static func retargetControlsItems(_ menu: NSMenu? = NSApp.mainMenu) -> Int {
        guard let menu else { return 0 }
        var n = 0
        for item in menu.items {
            if item.action == NSSelectorFromString("showControls:") {
                item.target = shared
                item.action = #selector(showControlsWindow(_:))
                item.title = "Controls & Bindings…"
                n += 1
            }
            if let sub = item.submenu { n += retargetControlsItems(sub) }
        }
        return n
    }
}

extension FeatureHooks {
    static func inputInstall(_ app: AppServices) {
        InputFeature.shared.install(app)
        // the main menu is built before the install hooks run
        if InputMenuTarget.retargetControlsItems() == 0 {
            DispatchQueue.main.async { InputMenuTarget.retargetControlsItems() }
        }
    }
}
