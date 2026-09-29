import Foundation
import PlatoonCore

// snapshot: [snapshot] agent — quick save / checkpoints / rewind (L1, M8, M9).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .general.
// Keys should be namespaced "snapshot.<name>". Gameplay-changing items MUST be default-off and use .gameplay().
//
// Taking checkpoints / rewind snapshots only reads the game, so these toggles are not gameplay options; USING a
// saved game, a checkpoint or rewind marks that run assisted (SaveStates.restore).

extension PrefsRegistry {
    static var saveStateSections: [PrefSection] {
        [
            PrefSection(tab: .general, title: "Save states", footer:
                "Quick Save ⇧⌘S / Quick Load ⇧⌘L, five slots in the Game menu and the pause menu. Saving happens at the next moment "
                + "the game is in play. Loading a game, retrying a checkpoint or rewinding marks the run as assisted: its score "
                + "does not go into the original hiscore table.", order: 60, items: [
                .toggle(SaveStates.kCheckpoints, "Automatic checkpoints", default: false,
                        help: "Keeps the start of the section and the last three milestones (explosives, bridge, village, huts, tunnel rooms and items, flare night, final-jungle rooms, bunker). Game › Retry from Checkpoint (⇧⌘R).")
                    .inMenu(.game),
                .toggle(SaveStates.kDeathPrompt, "Offer a retry when a soldier dies", default: false,
                        help: "Shows a short reminder of ⇧⌘R when the current soldier is killed (needs automatic checkpoints).")
                    .enabled(if: { Prefs.bool(SaveStates.kCheckpoints) }),
                .toggle(SaveStates.kRewind, "Rewind", default: false,
                        help: "Keeps a snapshot every second. Hold Backspace, ⌘Z or the controller's right-stick click (R3) to go back; release to continue from there, Esc cancels.")
                    .inMenu(.game),
                .slider(SaveStates.kRewindSeconds, "Rewind length", default: 30, range: 10...120, step: 10,
                        format: { "\(Int($0)) s" }, help: "How far back you can rewind (about 1.4 MB of memory per second).")
                    .enabled(if: { Prefs.bool(SaveStates.kRewind) }),
            ]),
        ]
    }
}
