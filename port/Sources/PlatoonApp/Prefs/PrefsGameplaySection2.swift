import Foundation
import PlatoonCore

// section2: [section2] agent — final jungle & foxhole options (M5 navigator, M25 room slide, S9 section-2 fixes,
// M10 section-2 knobs via the automatic rows, M15 via the core's game.* rows).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "section2.<name>". Gameplay-changing items MUST be default-off and use .gameplay().

extension PrefsRegistry {
    static var gameplaySection2Sections: [PrefSection] {
        [
            PrefSection(tab: .assist, title: "Final jungle navigator (M5)",
                        footer: "Read-only overlay beside or on the game picture, shown in the final jungle. The route guide, "
                            + "and the heading while you carry no compass, mark the game as assisted (separate hiscore "
                            + "table).", order: 150, items: [
                .choice("section2.navigator", "Navigator", default: 0,
                        [(0, "Off"), (1, "Heading and exits"), (2, "Heading + map of visited rooms"), (3, "Heading + map + route guide")],
                        help: "Heading shows which way you face (N/E/S/W) even without the compass, and which side exits the room "
                            + "has. The map fills in the rooms you have been in. The guide tells you which exit leads to the "
                            + "nearest bunker (shortest route) and how many rooms are left."),
                .choice("section2.navigatorPlace", "Position", default: 0, [(0, "Beside the game (if there is room)"), (1, "On the picture")]),
                .toggle("section2.compassAssist", "Start with the compass (HUD heading)", default: false,
                        help: "The one-write compass assist: the game's own HUD shows the heading in the final jungle and the "
                            + "hint becomes GET GOING!. Changes the game (assisted).").gameplay(enhancement: "s2.compassAssist"),
            ]),
            PrefSection(tab: .video, title: "Final jungle", order: 150, items: [
                .toggle("section2.roomSlide", "Directional room slide (M25)", default: false,
                        help: "Instead of the fade to black between final-jungle rooms, the old view slides out to the side "
                            + "you turned to and the next room slides in. Presentation only: the game is unchanged."),
                .slider("section2.roomSlideFrames", "Slide length", default: 12, range: 6...16, step: 1,
                        format: { "\(Int($0)) frames" })
                    .enabled(if: { Prefs.bool("section2.roomSlide") }),
            ]),
            PrefSection(tab: .gameplay, title: "Final jungle & foxhole: original bugs (S9)",
                        footer: "Each switch corrects one 1988 bug of the last section. Applied when a new game starts.",
                        order: 150, items: [
                .toggle("section2.fixRoomTimer", "Airstrike timer pauses between rooms", default: false,
                        help: "The original meant to stop the 2:00 timer while the screen is black between rooms but clears "
                            + "the wrong address; about 5 s over the shortest route. Changes the game (assisted).")
                    .gameplay(enhancement: "s2.fixRoomTimer"),
                .toggle("section2.napalmStopsTimer", "Timer stays at 00:00 during the napalm strike", default: false,
                        help: "No 59:59 on the HUD while the screen flashes white.").enhancement("s2.napalmStopsTimer"),
                .toggle("section2.withdrawnText", "Morale 0: 'WITHDRAWN FROM ACTION' screen", default: false,
                        help: "Shows the intended YOUR PLATOON HAS WITHDRAWN FROM ACTION text when morale runs out in the "
                            + "final jungle (the original shows the 'destroyed' text).").enhancement("s2.withdrawnText"),
                .toggle("section2.fixPhantomGrenades", "No automatic grenades after Barnes is dead", default: false,
                        help: "The original throws your remaining grenades one by one by itself once Barnes is dead "
                            + "(a register left over from another routine reads as the '.' key).").enhancement("s2.fixPhantomGrenades"),
            ]),
        ]
    }
}
