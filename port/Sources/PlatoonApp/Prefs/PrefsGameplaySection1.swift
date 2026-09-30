import Foundation
import PlatoonCore

// section1: [section1] agent — tunnels & flare options (M3 automap, M4, S9 section-1 fixes, M10, L2, L3, M25).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .gameplay.
// Keys should be namespaced "section1.<name>". Gameplay-changing items MUST be default-off and use .gameplay().
//
// The core options s1.* get hand-made rows here (Gameplay tab: rules, original bugs; the randomiser as
// off / new every reset / fixed seed like the village one); the difficulty knobs s1.diff.* are on the shared
// Gameplay page (PrefsGameplay.swift). Host-only items: the M3 automap overlay and the M25 turn slide.

enum Section1Prefs {
    static let kTunnelMode = "section1.tunnelRandom"
    static let kTunnelSeed = "section1.tunnelSeedValue"
}

extension PrefsRegistry {
    static var gameplaySection1Sections: [PrefSection] {
        [
            PrefSection(tab: .gameplay, title: "Tunnels & flare night", footer:
                "These change the rules of the tunnels and the flare night, so games played with them are kept out of the "
                + "original hiscore table. They take effect when a new game starts.", order: 130, items: [
                .toggle("section1.keepItems", "Keep items when a soldier dies", default: false,
                        help: "The next soldier keeps the flares, the compass, a map found in the tunnels and the emptied drawers "
                            + "(the original takes everything away and refills the rooms). Dying in the flare night gives back "
                            + "the flares you took into it, so the exit still opens.")
                    .gameplay(enhancement: "s1.keepItems"),
                .toggle("section1.flareRetry", "Flare night: retry with the next soldier", default: false,
                        help: "A death in the flare night restarts the flare night with the next soldier and the flares you "
                            + "brought, instead of sending him back through the whole maze.")
                    .gameplay(enhancement: "s1.flareRetry"),
                .toggle("section1.checkpointRespawn", "Next soldier starts at the last room", default: false,
                        help: "The next soldier starts in front of the last room you entered instead of at the entrance.")
                    .gameplay(enhancement: "s1.checkpointRespawn"),
                .toggle("section1.exploredMap", "The game's map window shows what you explored", default: false,
                        help: "The tunnels' own map window is always open and draws the corridors you have seen, even without "
                            + "the map item (the tunnel plan still reveals everything).")
                    .gameplay(enhancement: "s1.exploredMap"),
                .toggle("section1.directAim", "Pointer aiming moves the crosshair directly", default: false,
                        help: "With assisted aiming (Input tab) the crosshair jumps to the mouse pointer or right-stick target "
                            + "instead of being steered there with the joystick (the original limits still apply).")
                    .gameplay(enhancement: "s1.directAim"),
                .choice(Section1Prefs.kTunnelMode, "Tunnel randomiser", default: 0,
                        [(0, "Off (original tunnels)"), (1, "New tunnels at every reset"), (2, "Fixed tunnels (seed below)")],
                        help: "Shuffles what lies behind each hotspot between rooms that look alike (flares, compass, maps, "
                            + "ammunition...); the real EXIT is behind the door of either ladder room.")
                    .gameplay()
                    .covers("s1.randomSeed")
                    .config { cfg in
                        switch Prefs.int(Section1Prefs.kTunnelMode) {
                        case 1: cfg.enhancements.section1.randomSeed = Int.random(in: 1...99_999)
                        case 2: cfg.enhancements.section1.randomSeed = max(1, Prefs.int(Section1Prefs.kTunnelSeed))
                        default: break
                        }
                    },
                .slider(Section1Prefs.kTunnelSeed, "Tunnel seed", default: 1, range: 1...999, step: 1, format: { "\(Int($0))" })
                    .restart()
                    .enabled(if: { Prefs.int(Section1Prefs.kTunnelMode) == 2 }),
            ]),
            PrefSection(tab: .gameplay, title: "Tunnels & flare night: original bugs", footer:
                "Fixes for accidents in the 1988 code. Each one changes the game slightly, so these runs are kept out of "
                + "the original hiscore table.", order: 131, items: [
                .toggle("section1.fixLastBullet", "Your last bullet can kill", default: false,
                        help: "The original checks the ammunition after the shot has used it, so the last round never hits. "
                            + "Tunnels and flare night.")
                    .gameplay(enhancement: "s1.fixLastBullet"),
                .toggle("section1.fixMoraleWrap", "Morale from room items stops at full", default: false,
                        help: "Instead of wrapping a nearly full morale bar round to almost nothing.")
                    .gameplay(enhancement: "s1.fixMoraleWrap"),
                .toggle("section1.fixFoodFarm", "Rotten food scores once", default: false,
                        help: "The rotten food gives its 500 points once per soldier, not on every click.")
                    .gameplay(enhancement: "s1.fixFoodFarm"),
                .toggle("section1.fixFlareSpawn", "Flare night: enemies keep coming", default: false,
                        help: "Heavy firing in the flare night can no longer switch the enemy spawns off for good.")
                    .gameplay(enhancement: "s1.fixFlareSpawn"),
            ]),
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
