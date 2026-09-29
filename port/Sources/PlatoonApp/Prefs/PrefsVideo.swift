import Foundation
import PlatoonCore

// presentation: [presentation] agent — renderer, shaders, framing looks (S14, S16, M19, M20, M21, M24).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .video.
// Keys should be namespaced "presentation.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var videoSections: [PrefSection] {
        []
    }
}
