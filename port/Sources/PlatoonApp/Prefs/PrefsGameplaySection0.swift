import Foundation
import PlatoonCore

// section0: [section0] agent — jungle & village options (S6, S7, S9 section-0 fixes, M14, M11 section 0).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "section0.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var gameplaySection0Sections: [PrefSection] {
        []
    }
}
