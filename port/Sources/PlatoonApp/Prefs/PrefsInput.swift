import Foundation
import PlatoonCore

// input: [input] agent — controls, key/controller bindings (S2, S3, S15, M7, M13, L2).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .input.
// Keys should be namespaced "input.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var inputSections: [PrefSection] {
        []
    }
}
