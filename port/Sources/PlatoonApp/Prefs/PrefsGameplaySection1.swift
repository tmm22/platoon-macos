import Foundation
import PlatoonCore

// section1: [section1] agent — tunnels & flare options (M3 automap, M4, S9 section-1 fixes, M10, L2, L3, M25).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "section1.<name>". Gameplay-changing items MUST be default-off and use .gameplay().
//
// The core options s1.* (keep items, flare-night retry, checkpoint respawn, explored map window, the S9 fixes,
// direct aiming, randomiser, difficulty knobs) get their Preferences rows automatically from the enhancement
// catalogue (Gameplay tab). This file adds the host-only items: the M3 automap overlay and the M25 turn slide.

extension PrefsRegistry {
    static var gameplaySection1Sections: [PrefSection] {
        [
            PrefSection(tab: .assist, title: "Tunnel map", footer:
                "A map of the tunnel maze beside the game that fills in as you explore (fog of war). Rooms are numbered "
                + "when you enter them, with what you found there. It only reads the game, so it does not affect the "
                + "hiscore table - except \"Reveal the whole maze\", which marks the run as assisted. Press M in the "
                + "tunnels to hide or show it.", order: 130, items: [
                .toggle(TunnelMapPanel.kEnabled, "Show the tunnel map", default: false,
                        help: "Draws the corridors and rooms you have seen, with your position and heading.")
                    .inMenu(.assist),
                .toggle(TunnelMapPanel.kItems, "List what you found in each room", default: true,
                        help: "Flares, compass, map, ammunition, medical supplies and the exit, with a tick once taken.")
                    .enabled(if: { Prefs.bool(TunnelMapPanel.kEnabled) }),
                .toggle(TunnelMapPanel.kReveal, "Reveal the whole maze (spoiler)", default: false,
                        help: "Shows every corridor and every room's contents. Marks the run as assisted.")
                    .enabled(if: { Prefs.bool(TunnelMapPanel.kEnabled) }),
                .slider(TunnelMapPanel.kSize, "Map size", default: 5, range: 3...10, step: 1,
                        format: { "\(Int($0)) pt per cell" })
                    .enabled(if: { Prefs.bool(TunnelMapPanel.kEnabled) }),
                .choice(TunnelMapPanel.kPlace, "Position", default: 0,
                        [(0, "Right of the game"), (1, "Top-right corner of the game"), (2, "Left of the game")],
                        help: "Beside the game needs a wide window (or full screen); otherwise the map goes into the corner.")
                    .enabled(if: { Prefs.bool(TunnelMapPanel.kEnabled) }),
            ]),
            PrefSection(tab: .video, title: "Tunnels", order: 130, items: [
                .toggle(TunnelTurnSlide.kEnabled, "Slide the view when turning", default: false,
                        help: "When you turn left or right in the tunnels the old view slides out and the new one in (a few frames, presentation only)."),
            ]),
        ]
    }
}
