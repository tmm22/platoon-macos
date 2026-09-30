import Foundation
import PlatoonCore

// assist: [assist] agent — read-only assists and overlays (S8 message log / captions / speech, M2 objectives /
// briefings / numeric HUD, M16 speedrun timer + service record, M17 replays, M11 practice).
// Only the owner edits this file. Everything here is host-only and read-only except practice drills (which load a
// prepared game and are marked assisted) and the "full solution" objectives tier (marks the run assisted while shown).
// Implementation: PlatoonApp/Assist/*, models in PlatoonCore/Game/Assist/*.

enum AssistPrefs {
    // S8
    static let logEnabled = "assist.log.enabled"
    static let captions = "assist.captions"
    static let captionSize = "assist.captionSize"
    static let captionPlace = "assist.captionPlace"
    static let captionHold = "assist.captionHold"
    static let speech = "assist.speech"
    static let speechRate = "assist.speechRate"
    static let speechScreens = "assist.speechScreens"
    // M2
    static let objectives = "assist.objectives"
    static let objectivesTier = "assist.objectivesTier"
    static let objectivesPlace = "assist.objectivesPlace"
    static let briefings = "assist.briefings"
    static let hud = "assist.hud"
    static let hudPlace = "assist.hudPlace"
    // M16
    static let timer = "assist.timer"
    static let timerSplits = "assist.timerSplits"
    static let serviceRecord = "assist.serviceRecord"
    static let medalToasts = "assist.medalToasts"
    // M17
    static let replayRecord = "assist.replay.record"
    // M11
    static let practiceRetry = "assist.practice.retryOnDeath"
    static let practiceBadge = "assist.practice.badge"
}

extension PrefsRegistry {
    static var assistSections: [PrefSection] {
        let onPicture = [(0, "Beside the game (if there is room)"), (1, "On the picture")]
        return [
            PrefSection(tab: .assist, title: "Messages and captions (S8)", footer:
                "The game shows its clues as a one-line message that fades after a second, and silently drops a message "
                + "when four are waiting. The log keeps every one (Assist ▸ Message Log, ⌥⌘L, or the pause menu). "
                + "Captions and speech only read the game; they never change it.", order: 10, items: [
                .toggle(AssistPrefs.logEnabled, "Keep a message log", default: true,
                        help: "Every HUD message of the current game, with the time, repeats folded, and the ones the game dropped marked."),
                .toggle(AssistPrefs.captions, "Large captions", default: false,
                        help: "Shows the current HUD message in large, high-contrast text.").inMenu(.assist),
                .slider(AssistPrefs.captionSize, "Caption size", default: 22, range: 14...44, step: 2, format: { "\(Int($0)) pt" })
                    .enabled(if: { Prefs.bool(AssistPrefs.captions) }),
                .choice(AssistPrefs.captionPlace, "Caption position", default: 0,
                        [(0, "Below the game (if there is room)"), (1, "Bottom of the picture"), (2, "Top of the picture")])
                    .enabled(if: { Prefs.bool(AssistPrefs.captions) }),
                .slider(AssistPrefs.captionHold, "Keep each caption at least", default: 2.5, range: 0...8, step: 0.5,
                        format: { $0 == 0 ? "as long as the game" : String(format: "%.1f s", $0) },
                        help: "Messages that the game replaces after one tick stay readable.")
                    .enabled(if: { Prefs.bool(AssistPrefs.captions) }),
                .toggle(AssistPrefs.speech, "Read messages aloud", default: false,
                        help: "Speaks every new HUD message (with VoiceOver running, as a VoiceOver announcement).").inMenu(.assist),
                .toggle(AssistPrefs.speechScreens, "Also read the full-screen texts", default: true,
                        help: "Section intros, ONE MORE CHANCE, the endings.")
                    .enabled(if: { Prefs.bool(AssistPrefs.speech) }),
                .slider(AssistPrefs.speechRate, "Speaking rate", default: 0.5, range: 0.3...0.7, step: 0.05,
                        format: { "\(Int(($0 * 200).rounded()))%" })
                    .enabled(if: { Prefs.bool(AssistPrefs.speech) }),
            ]),
            PrefSection(tab: .assist, title: "Objectives and briefings (M2)", footer:
                "Platoon never says what to do. The checklist follows your progress from the game's own memory. "
                + "\"Full solution\" gives exact places and the final-jungle route; it marks the game as assisted while shown.",
                        order: 20, items: [
                .toggle(AssistPrefs.objectives, "Show objectives", default: false,
                        help: "A checklist of the current section's goals.").inMenu(.assist),
                .choice(AssistPrefs.objectivesTier, "Detail", default: 1,
                        [(1, "Goals only"), (2, "Goals + hints"), (3, "Full solution (spoilers)")])
                    .enabled(if: { Prefs.bool(AssistPrefs.objectives) }),
                .choice(AssistPrefs.objectivesPlace, "Objectives position", default: 0, onPicture)
                    .enabled(if: { Prefs.bool(AssistPrefs.objectives) }),
                .toggle(AssistPrefs.briefings, "Briefing when a section loads", default: false,
                        help: "A short mission card over the LOADING and ENTERING THE COMBAT ZONE screens (the game's own "
                            + "waiting time is not changed). Shows the difficulty and assists of the game. Click to hide."),
                .toggle(AssistPrefs.hud, "Numeric HUD", default: false,
                        help: "Morale in percent, ammunition, grenades, wounds, flares and the timer as numbers.").inMenu(.assist),
                .choice(AssistPrefs.hudPlace, "Numeric HUD position", default: 0, onPicture)
                    .enabled(if: { Prefs.bool(AssistPrefs.hud) }),
            ]),
            PrefSection(tab: .assist, title: "Speedrun timer and service record (M16)", footer:
                "The timer counts game frames (50 per second) from the start of a game, without TAB pauses; host pauses and "
                + "fast-forward don't change it. Personal bests are kept per category (original, difficulty presets, "
                + "assisted, start section). The service record keeps your career statistics and medals "
                + "(Assist ▸ Service Record). Medals are not awarded in assisted games.", order: 30, items: [
                .toggle(AssistPrefs.timer, "Show the speedrun timer", default: false).inMenu(.assist),
                .toggle(AssistPrefs.timerSplits, "Show splits", default: true,
                        help: "Explosives, bridge, village, torch, map, trap door, flares, tunnel exit, dawn, bunker, Barnes, "
                            + "Huey, with the difference to your personal best.")
                    .enabled(if: { Prefs.bool(AssistPrefs.timer) }),
                .toggle(AssistPrefs.serviceRecord, "Keep a service record", default: true,
                        help: "Games, wins, time played, soldiers lost, best scores, medals."),
                .toggle(AssistPrefs.medalToasts, "Announce medals", default: false,
                        help: "A short message when you earn a medal.")
                    .enabled(if: { Prefs.bool(AssistPrefs.serviceRecord) }),
            ]),
            PrefSection(tab: .assist, title: "Replays (M17)", footer:
                "The port is deterministic, so your joystick and key presses from the start of a game reproduce it exactly. "
                + "Assist ▸ Save Replay of This Game writes them to a file; Play Replay shows it again (you can pause, "
                + "fast-forward and take over with Stop Replay). Replay files are also platoon-headless scripts. "
                + "A loaded save state ends the recording.", order: 40, items: [
                .toggle(AssistPrefs.replayRecord, "Record the current game", default: true,
                        help: "Keeps the input of the game since the last reset in memory (a few KB)."),
            ]),
            PrefSection(tab: .assist, title: "Practice (M11)", footer:
                "Assist ▸ Practice starts a drill: the bridge, the village, the tunnels, the flare night, the final jungle "
                + "or Sgt Barnes, prepared from recorded play in a moment. Practice games are marked as assisted and never "
                + "enter the high-score table.", order: 50, items: [
                .toggle(AssistPrefs.practiceRetry, "Restart the drill when a soldier dies", default: true),
                .toggle(AssistPrefs.practiceBadge, "Show the practice badge (attempts and time)", default: true),
            ]),
        ]
    }
}
