import AppKit
import PlatoonCore

// OWNER: [app] — built-in preferences: pause behaviour (S4), pause menu (M1), fast-forward (S11), disk (M23), and
// the pre-existing video / audio settings (same UserDefaults keys as before, so user settings persist). The old
// Gameplay ▸ Trainer toggles became the Cheats tab (Prefs/PrefsCheats.swift, settings migrated at launch).

enum BuiltinPrefs {
    static let pauseOnFocus = "app.pauseOnFocusLoss"
    static let pauseOnSleep = "app.pauseOnSleep"
    static let pauseOnController = "app.pauseOnControllerDisconnect"
    static let pauseForDialogs = "app.pauseForDialogs"
    static let escPauseMenu = "app.escOpensPauseMenu"
    static let padMenuHold = "app.padMenuHoldOpensPauseMenu"
    static let showPauseBadge = "app.showPauseBadge"
    static let ffKey = "app.fastForwardKey"
    static let ffPad = "app.fastForwardPad"
    static let ffSpeed = "app.fastForwardSpeed"
    static let ffVolume = "app.fastForwardVolume"
    static let originalCredits = "app.originalCredits"
    static let soundModeAtBoot = "app.soundModeAtBoot"
    static let fastKeys = "app.fasterKeyDelivery"
    static let lastSoundFlags = "app.lastSoundFlags"
    static let gameSpeed = "app.gameSpeed"
}

extension PrefsRegistry {
    static var builtinSections: [PrefSection] {
        let video: () -> Void = { AppServices.shared.app?.applyVideoSettings() }
        let audio: () -> Void = { AppServices.shared.host?.applyAudioSettings() }
        return [
            PrefSection(tab: .general, title: "Pause", footer: "The host pause stops the whole machine: no timers, no enemies, no sound. "
                        + "Anything still held when the game resumes is ignored until you let go, so the press that resumes doesn't fire a shot.",
                        order: 0, items: [
                .choice(BuiltinPrefs.pauseOnFocus, "When the window loses focus", default: 0,
                        [(0, "Keep running (original)"), (1, "Pause, resume when back"), (2, "Pause and open the pause menu")],
                        help: "Also applies when the window is minimised or the app is hidden."),
                .choice(BuiltinPrefs.pauseOnSleep, "When the Mac or the display sleeps", default: 0,
                        [(0, "Keep running (original)"), (1, "Pause and open the pause menu")]),
                .choice(BuiltinPrefs.pauseOnController, "When a game controller disconnects", default: 0,
                        [(0, "Keep running (original)"), (1, "Pause and open the pause menu")]),
                .toggle(BuiltinPrefs.pauseForDialogs, "Pause while a dialog is open", default: false,
                        help: "Controls, disk import and other host dialogs."),
            ]),
            PrefSection(tab: .general, title: "Pause menu", order: 10, items: [
                .toggle(BuiltinPrefs.escPauseMenu, "Esc opens the pause menu", default: true,
                        help: "The game never reads the Amiga Esc key, so this takes nothing away."),
                .toggle(BuiltinPrefs.padMenuHold, "Hold the controller Menu button to open the pause menu", default: false,
                        help: "A short press still pauses in-game (TAB), sent when the button is released."),
                .toggle(BuiltinPrefs.showPauseBadge, "Show a PAUSED badge while the game is paused", default: true),
            ]),
            PrefSection(tab: .general, title: "Fast-forward", footer: "Fast-forward runs the unchanged game faster (for intros, text screens and loading). "
                        + "⌘T toggles a sticky turbo that is not remembered between launches.", order: 20, items: [
                .toggle(BuiltinPrefs.ffKey, "Hold ` (backquote) to fast-forward", default: true),
                .toggle(BuiltinPrefs.ffPad, "Hold the controller's left stick button (L3) to fast-forward", default: true),
                .choice(BuiltinPrefs.ffSpeed, "Speed", default: 4, [(2, "2×"), (3, "3×"), (4, "4×"), (6, "6×"), (8, "8×")]),
                .slider(BuiltinPrefs.ffVolume, "Sound while fast-forwarding", default: 0.25, range: 0...1, step: 0.05,
                        format: { $0 == 0 ? "Muted" : "\(Int(($0 * 100).rounded()))%" }),
            ]),
            PrefSection(tab: .general, title: "Game speed", footer: "Slow motion gives you more time to react. The game itself is "
                        + "unchanged, it just runs fewer frames per second (the sound follows at a lower pitch). Any speed below "
                        + "100 % marks the game as assisted.", order: 22, items: [
                PrefItem(key: BuiltinPrefs.gameSpeed, title: "Game speed",
                         kind: .choice(default: 100, options: [(100, "100 % (original)"), (90, "90 %"), (80, "80 %"), (70, "70 %"), (60, "60 %")].map { (value: $0.0, title: $0.1) }),
                         help: "Accessibility: the whole game runs slower, including the timers.", isGameplay: true)
                    .onChange { AppServices.shared.host?.applySpeedSetting() },
            ]),
            PrefSection(tab: .general, title: "Keyboard", order: 25, items: [
                .toggle(BuiltinPrefs.fastKeys, "Faster key response", default: false,
                        help: "The original keyboard handling takes 3 frames per key event, so quick SPACE / Alt / Y / N presses lag by 6-9 frames. This delivers one per frame instead.")
                    .onChange { AppServices.shared.host?.applyInputSettings() },
            ]),
            PrefSection(tab: .general, title: "Game disk", order: 30, items: [
                .action("app.importDisk", "Use a different Platoon disk image", button: "Import Disk Image…",
                        help: "Copies the .adf to Application Support/Platoon/Platoon.adf after a health check.") {
                    AppServices.shared.app?.importDiskInteractively()
                },
                .action("app.checkDisk", "Check the current disk image", button: "Check Disk…") {
                    AppServices.shared.app?.showDiskHealth()
                },
            ]),
            PrefSection(tab: .general, title: "Title screen and high scores", footer: "The original high-score table only takes "
                        + "games played without gameplay options, cheats, loaded saves, rewind or section starts; the others "
                        + "go to hiscores-recruit / -veteran / -custom / -assisted.bin next to it.", order: 40, items: [
                .toggle(BuiltinPrefs.originalCredits, "Original Ocean credits text", default: true,
                        help: "Restores \"GAME DESIGN (C)1988 OCEAN.\" / \"CONVERSION BY CHOICE\" that the cracked disk replaced. Applies after a reset.")
                    .enhancement("kernel.originalCredits"),
                .toggle("app.separateCheatScores", "Games with the original cheat codes use the assisted table", default: false,
                        help: "With HAMBURGER / MEGA CHEAT typed on the title screen, the game's score goes to the assisted "
                            + "table instead of the original one. Applies after a reset.")
                    .enhancement("kernel.separateCheatScores"),
            ]),

            PrefSection(tab: .video, title: "Display", order: 0, items: [
                .choice("filter", "Filter", default: 0, MetalRenderer.Filter.allCases.map { ($0.rawValue, $0.title) }).onChange(video),
                .toggle("aspect", "Correct aspect ratio (PAL pixels)", default: true).onChange(video),
                .toggle("integer", "Integer scaling", default: false).onChange(video),
                .toggle("overscan", "Show overscan", default: false).onChange(video),
                .toggle("curvature", "CRT curvature", default: true).onChange(video),
                .slider("scanlines", "CRT scanline strength", default: 0.35, range: 0...1, step: 0.05,
                        format: { "\(Int(($0 * 100).rounded()))%" }).onChange(video),
            ]),
            PrefSection(tab: .audio, title: "Music / sound FX at power-on (F10)", order: 10, items: [
                PrefItem.choice(BuiltinPrefs.soundModeAtBoot, "Mode at start-up", default: 0,
                                [(0, "Original (music and FX)"), (1, "Remember the last F10 choice"), (2, "Music only"), (3, "Sound FX only"), (4, "Off")],
                                help: "F10 still cycles the modes in the game. Applies after a reset.")
                    .covers("kernel.soundFlagsAtBoot")
                    .config { c in
                        let flags: Int?
                        switch Prefs.int(BuiltinPrefs.soundModeAtBoot) {
                        case 1: flags = UserDefaults.standard.object(forKey: BuiltinPrefs.lastSoundFlags) == nil ? nil : Prefs.int(BuiltinPrefs.lastSoundFlags)
                        case 2: flags = 1
                        case 3: flags = 2
                        case 4: flags = 0
                        default: flags = nil
                        }
                        if let f = flags { _ = c.enhancements.apply(["kernel.soundFlagsAtBoot=\(f & 3)"]) }
                    },
            ]),
            PrefSection(tab: .audio, title: "Output", order: 0, items: [
                .slider("volume", "Volume", default: 1.0, range: 0...1, step: 0.05, format: { $0 == 0 ? "Muted" : "\(Int(($0 * 100).rounded()))%" }).onChange(audio),
                .slider("separation", "Stereo separation", default: 0.7, range: 0...1, step: 0.05,
                        format: { $0 == 0 ? "Mono" : $0 >= 1 ? "Amiga (hard)" : "\(Int(($0 * 100).rounded()))%" }).onChange(audio),
                .toggle("a500filter", "A500 low-pass filter", default: true).onChange(audio),
                .toggle("interpolate", "Smooth sample interpolation", default: false).onChange(audio),
            ]),
        ]
    }
}

extension MenuRegistry {
    static func builtinMenus(_ app: AppServices) -> [MenuContribution] {
        [MenuContribution(menu: .help, order: 10, separatorBefore: false, items: [
            ClosureMenuItem("Platoon Enhancements Guide") { HelpDocs.open("ENHANCEMENTS_GUIDE") },
            ClosureMenuItem("About This Port (README)") { HelpDocs.open("README") },
            .separator(),
            ClosureMenuItem("Controls & Bindings…") { ControlsWindowController.shared.show() },
            ClosureMenuItem("Preferences…") { app.openPreferences() },
        ])]
    }
}

/// The user guide files: bundled by build_app.sh (Contents/Resources), else the source tree next to the binary's
/// package (development builds).
enum HelpDocs {
    static func url(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "md") { return u }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            for c in [dir.appendingPathComponent("\(name).md"), dir.appendingPathComponent("port/\(name).md")]
            where FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return nil
    }
    static func open(_ name: String) {
        guard let u = url(name) else { AppServices.shared.toast("\(name).md is not available in this build"); return }
        // .md often has no default application: fall back to TextEdit instead of doing nothing
        if NSWorkspace.shared.urlForApplication(toOpen: u) == nil,
           let te = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([u], withApplicationAt: te, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(u)
    }
}

extension FeatureHooks {
    static func builtinInstall(_ app: AppServices) {
        // S12: remember the player's F10 music/FX mode
        app.onHostReady { host in
            host.probe.addObserver { r in
                if case .soundFlags(let f) = r.event { UserDefaults.standard.set(Int(f & 3), forKey: BuiltinPrefs.lastSoundFlags) }
            }
        }
    }
}
