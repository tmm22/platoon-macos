import Foundation
import PlatoonCore

// assist: [assist] agent — read-only assists and overlays (S8, M2, M3, M5, M6, M16).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .assist.
// Keys should be namespaced "assist.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var assistSections: [PrefSection] {
        []
    }
}
