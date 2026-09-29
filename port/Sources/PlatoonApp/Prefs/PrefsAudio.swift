import Foundation
import PlatoonCore

// audio: [audio] agent — mixer, voices, audio robustness (S10, S12 sound flags, M12, M22, M25 audio).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .audio.
// Keys should be namespaced "audio.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var audioSections: [PrefSection] {
        []
    }
}
