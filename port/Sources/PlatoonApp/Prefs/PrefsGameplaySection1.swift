import Foundation
import PlatoonCore

// section1: [section1] agent — tunnels & flare options (M4, S9 section-1 fixes).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "section1.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var gameplaySection1Sections: [PrefSection] {
        []
    }
}
