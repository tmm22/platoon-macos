import AppKit
import PlatoonCore

// assist: [assist] agent — read-only assists and overlays (S8, M2, M16, M17) and practice (M11).
// Only the owner edits this file.
//  - `assistMenus`: the Assist menu (message log, practice, service record, replays). Pref toggles (captions, speech,
//    objectives, numeric HUD, timer) appear there automatically through PrefItem.inMenu(.assist).
//  - `assistInstall`: AssistCenter (Assist/AssistCenter.swift) wires everything at launch.

extension MenuRegistry {
    static func assistMenus(_ app: AppServices) -> [MenuContribution] {
        let c = AssistCenter.shared
        let practice = PracticeDrills.all.map { d in
            ClosureMenuItem(d.title, state: { c.practice.drill == d }, enabled: { app.host != nil && c.practice.preparing == nil }) {
                c.practice.start(d)
            }
        }
        let practiceMenu = ClosureMenuItem.submenu("Practice", practice + [
            .separator(),
            ClosureMenuItem("Restart Drill", key: "p", mods: [.command, .option], enabled: { c.practice.drill != nil }) { c.practice.restart() },
            ClosureMenuItem("Stop Practice", enabled: { c.practice.drill != nil }) { c.practice.stop() },
        ])
        let replay = ClosureMenuItem.submenu("Replays", [
            ClosureMenuItem("Save Replay of This Game…", key: "s", mods: [.command, .option], enabled: { app.host != nil }) { c.replays.saveInteractively() },
            ClosureMenuItem("Play Replay…", key: "o", mods: [.command, .option], enabled: { app.host != nil }) { c.replays.playInteractively() },
            ClosureMenuItem("Play Last Game", enabled: { FileManager.default.fileExists(atPath: ReplayController.directory.appendingPathComponent("last.plreplay").path) }) {
                c.replays.play(url: ReplayController.directory.appendingPathComponent("last.plreplay"))
            },
            ClosureMenuItem("Play Best Game", enabled: { FileManager.default.fileExists(atPath: ReplayController.directory.appendingPathComponent("best.plreplay").path) }) {
                c.replays.play(url: ReplayController.directory.appendingPathComponent("best.plreplay"))
            },
            ClosureMenuItem("Stop Replay (take over)", enabled: { c.replays.isPlaying }) { c.replays.stopPlayback() },
            .separator(),
            ClosureMenuItem("Show Replays in Finder") {
                try? FileManager.default.createDirectory(at: ReplayController.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([ReplayController.directory])
            },
        ])
        return [
            MenuContribution(menu: .assist, order: 10, separatorBefore: false, items: [
                ClosureMenuItem("Message Log", key: "l", mods: [.command, .option], enabled: { app.host != nil }) { c.showLog() },
                ClosureMenuItem("Copy Message Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.messageLog.exportText(), forType: .string)
                },
                ClosureMenuItem("Objectives Detail", dynamicTitle: {
                    "Objectives Detail: " + ["", "Goals", "Goals + Hints", "Full Solution"][max(1, min(3, Prefs.int(AssistPrefs.objectivesTier)))]
                }) {
                    Prefs.set(AssistPrefs.objectivesTier, Prefs.int(AssistPrefs.objectivesTier) % 3 + 1)
                },
            ]),
            MenuContribution(menu: .assist, order: 20, items: [
                practiceMenu,
                replay,
                ClosureMenuItem("Service Record…", key: "r", mods: [.command, .shift, .option]) { c.showServiceRecord() },
            ]),
            MenuContribution(menu: .assist, order: 600, items: [
                ClosureMenuItem("Assist Preferences…") { app.openPreferences(tab: .assist) },
            ]),
        ]
    }
}

extension FeatureHooks {
    static func assistInstall(_ app: AppServices) {
        AssistCenter.shared.install(app)
    }
}
