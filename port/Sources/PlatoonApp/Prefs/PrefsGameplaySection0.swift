import Foundation
import PlatoonCore

// section0: [section0] agent — jungle & village options (S6, S7, S9 section-0 fixes, M14, L3, M6 map, L4 widescreen).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "section0.<name>". Gameplay-changing items MUST be default-off and use .gameplay().
//
// The core options s0.* are declared in PlatoonCore Enhance/Section0Options.swift; the rows below replace their
// automatic rows with friendlier ones (the M10 difficulty knobs s0.diff.* keep their automatic rows).

enum Section0Prefs {
    static let kVillageMode = "section0.villageRandom"
    static let kVillageSeed = "section0.villageSeedValue"
    /// Seed used for the current run (shown in a toast when the jungle starts).
    static var runSeed: Int?
}

extension PrefsRegistry {
    static var gameplaySection0Sections: [PrefSection] {
        [
            PrefSection(tab: .gameplay, title: "Jungle & village", footer:
                "These change the rules of the jungle, so games played with them are kept out of the original hiscore "
                + "table. They take effect when a new game starts.", order: 110, items: [
                .toggle("section0.bridgeFailsafe", "Bridge failsafe", default: false,
                        help: "Without the explosives you are stopped before the bridge (\"SET THE EXPLOSIVES ON THE BRIDGE\") instead of the whole platoon being wiped out.")
                    .gameplay(enhancement: "s0.bridgeFailsafe"),
                .toggle("section0.forgivingTraps", "Forgiving booby traps", default: false,
                        help: "Tripwires and booby-trapped drawers wound your soldier like a bullet instead of killing him.")
                    .gameplay(enhancement: "s0.forgivingTraps"),
                .toggle("section0.explicitJumpCrouch", "Separate jump and crouch controls", default: false,
                        help: "Jump and crouch get their own buttons (Input tab); up and down then only take paths and hut doors. Lets you jump on path tiles and at doors.")
                    .gameplay(enhancement: "s0.explicitJumpCrouch"),
                .choice(Section0Prefs.kVillageMode, "Village randomiser", default: 0,
                        [(0, "Off (original huts)"), (1, "New village at every reset"), (2, "Fixed village (seed below)")],
                        help: "Moves the torch, the map and the booby traps to other search spots in the huts.")
                    .gameplay()
                    .covers("s0.villageSeed")
                    .config { cfg in
                        switch Prefs.int(Section0Prefs.kVillageMode) {
                        case 1: let s = Int.random(in: 1...99_999); cfg.enhancements.section0.villageSeed = s; Section0Prefs.runSeed = s
                        case 2: let s = max(1, Prefs.int(Section0Prefs.kVillageSeed)); cfg.enhancements.section0.villageSeed = s; Section0Prefs.runSeed = s
                        default: Section0Prefs.runSeed = nil
                        }
                    },
                .slider(Section0Prefs.kVillageSeed, "Village seed", default: 1, range: 1...999, step: 1, format: { "\(Int($0))" })
                    .restart()
                    .enabled(if: { Prefs.int(Section0Prefs.kVillageMode) == 2 }),
            ]),
            PrefSection(tab: .gameplay, title: "Jungle & village: original bugs", footer:
                "Fixes for accidents in the 1988 code. Each one changes the game slightly, so these runs are kept out of "
                + "the original hiscore table.", order: 111, items: [
                .toggle("section0.fixMoraleWrap", "Morale bonuses stop at full", default: false,
                        help: "Crates, the torch and the map no longer wrap a nearly full morale bar round to almost nothing.")
                    .gameplay(enhancement: "s0.fixMoraleWrap"),
                .toggle("section0.fixHutDummy", "The trap-door hut is empty", default: false,
                        help: "The invisible 'enemy' in hut 1 can't be shot any more (it gave points and counted as killing the hut-2 guard).")
                    .gameplay(enhancement: "s0.fixHutDummy"),
                .toggle("section0.fixTripwireSpawn", "No tripwires behind you", default: false,
                        help: "With some scroll positions a tripwire appeared behind the player instead of ahead.")
                    .gameplay(enhancement: "s0.fixTripwireSpawn"),
                .toggle("section0.fixTrapdoorBonus", "Fair trap-door bonus", default: false,
                        help: "The 1000-per-soldier bonus counts your five soldiers (the original counts from the current one on).")
                    .gameplay(enhancement: "s0.fixTrapdoorBonus"),
            ]),
            PrefSection(tab: .assist, title: "Jungle map", footer:
                "A schematic of the six jungle strips beside the game: trees, paths between the strips, the river and "
                + "the huts, with your position. It only reads the game. Showing the hut contents is a spoiler and marks "
                + "the run as assisted. Press M in the jungle to hide or show it.", order: 120, items: [
                .toggle(JungleMapPanel.kEnabled, "Show the jungle map", default: false,
                        help: "Draws the jungle strips, paths and huts with your position.")
                    .inMenu(.assist),
                .choice(JungleMapPanel.kSpoilers, "Show", default: 0,
                        [(0, "Layout only"), (1, "Layout + objectives (explosives, bridge)"), (2, "Everything + hut contents (spoiler)")])
                    .enabled(if: { Prefs.bool(JungleMapPanel.kEnabled) }),
                .toggle(JungleMapPanel.kFog, "Only what you have explored", default: false,
                        help: "Columns appear on the map once you have been near them (kept after a death or a loaded game).")
                    .enabled(if: { Prefs.bool(JungleMapPanel.kEnabled) }),
                .slider(JungleMapPanel.kSize, "Map size", default: 4, range: 2...8, step: 1, format: { "\(Int($0)) pt per column" })
                    .enabled(if: { Prefs.bool(JungleMapPanel.kEnabled) }),
                .choice(JungleMapPanel.kPlace, "Position", default: 0,
                        [(0, "Below the game"), (1, "Top of the game image"), (2, "Above the game")],
                        help: "Outside the game needs a tall enough window; otherwise the map goes onto the top of the image.")
                    .enabled(if: { Prefs.bool(JungleMapPanel.kEnabled) }),
                .toggle(JungleHintPanel.kEnabled, "Warn about booby-trapped drawers", default: false,
                        help: "Inside a hut, a warning appears when you stand at a spot that is booby-trapped. Marks the run as assisted when it appears."),
            ]),
            PrefSection(tab: .video, title: "Widescreen jungle", footer:
                "The jungle scenery continues into the black bars at the sides of a wide window (background only - enemies "
                + "and you stay in the middle; the HUD keeps its width). Off inside the huts, during transitions and in "
                + "the other sections. It shows a little more of the way ahead.", order: 120, items: [
                .toggle(JungleWideController.kEnabled, "Extend the jungle into the side bars", default: false)
                    .onChange { if let h = AppServices.shared.host { JungleWideController.shared.attach(h) } },
                .slider(JungleWideController.kWidth, "Maximum width per side", default: 160, range: 16...256, step: 16,
                        format: { "\(Int($0)) px" })
                    .enabled(if: { Prefs.bool(JungleWideController.kEnabled) }),
                .toggle(JungleWideController.kFade, "Fade towards the edges", default: true)
                    .enabled(if: { Prefs.bool(JungleWideController.kEnabled) }),
            ]),
        ]
    }
}
