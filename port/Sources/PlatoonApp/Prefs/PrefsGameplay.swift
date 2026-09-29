import Foundation
import PlatoonCore

// core: [core] agent — core gameplay options: difficulty presets (M10), assisted-run/hiscore policy (S5), enhancement registry.
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "core.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var gameplayCoreSections: [PrefSection] {
        []
    }
}
