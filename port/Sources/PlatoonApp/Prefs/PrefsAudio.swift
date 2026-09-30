import AppKit
import PlatoonCore

// audio: [audio] agent — mixer, voices, audio robustness (S10, S12 sound flags, M12, M22, M25 audio).
// Only the owner edits this file. Declare Preferences sections here (see Prefs/PrefsRegistry.swift for the
// item kinds and modifiers: .toggle/.choice/.slider/.action/.note, .gameplay(enhancement:), .restart(),
// .onChange { }, .config { cfg in }, .enabled(if:), .inMenu(.game)). Suggested tab: .audio.
// Keys should be namespaced "audio.<name>". Gameplay-changing items MUST be default-off and use .gameplay().
//
// Every item here is host presentation (no gameplay effect, applies live; AudioEnhancements.sync). The core's
// audio.* enhancement options (Enhance/AudioOptions.swift, for platoon-headless --enh) are covered by these rows.

private extension PrefItem {
    /// Hides the automatic row of core option `k` without marking this item restart-only (it applies live).
    func coveringLive(_ k: String...) -> PrefItem { var c = self; c.covers += k; return c }
}

extension PrefsRegistry {
    static var audioSections: [PrefSection] {
        let pct: (Double) -> String = { $0 == 0 ? "Muted" : "\(Int(($0 * 100).rounded()))%" }
        let panFmt: (Double) -> String = { v in abs(v) < 0.01 ? "Centre" : v < 0 ? "L \(Int((-v * 100).rounded()))%" : "R \(Int((v * 100).rounded()))%" }
        let sync: () -> Void = { if let h = AppServices.shared.host { AudioEnhancements.shared.sync(h) } }
        let customPan = { Prefs.int(AudioPrefs.panPreset) == AudioPrefs.customPan }
        return [
            PrefSection(tab: .audio, title: "Mixer", footer: "S10. Each of Paula's four voices is tagged by its owner "
                        + "(the music driver or a sound effect), so music and effects get their own volume. Pan places the four voices; "
                        + "the Stereo separation slider above still narrows them. Everything at 100 % / Amiga is the original sound.",
                        order: 20, items: [
                .slider(AudioPrefs.musicVolume, "Music volume", default: 1, range: 0...2, step: 0.05, format: pct)
                    .coveringLive("audio.musicVolume").onChange(sync),
                .slider(AudioPrefs.sfxVolume, "Sound effects volume", default: 1, range: 0...2, step: 0.05, format: pct)
                    .coveringLive("audio.sfxVolume").onChange(sync),
                .choice(AudioPrefs.panPreset, "Voice panning", default: 0, AudioPrefs.panPresets.enumerated().map { ($0.offset, $0.element.0) })
                    .coveringLive("audio.pan0", "audio.pan1", "audio.pan2", "audio.pan3").onChange(sync),
                .slider(AudioPrefs.pan[0], "Voice 1 pan", default: -1, range: -1...1, step: 0.05, format: panFmt).enabled(if: customPan).onChange(sync),
                .slider(AudioPrefs.pan[1], "Voice 2 pan", default: 1, range: -1...1, step: 0.05, format: panFmt).enabled(if: customPan).onChange(sync),
                .slider(AudioPrefs.pan[2], "Voice 3 pan", default: 1, range: -1...1, step: 0.05, format: panFmt).enabled(if: customPan).onChange(sync),
                .slider(AudioPrefs.pan[3], "Voice 4 pan", default: -1, range: -1...1, step: 0.05, format: panFmt).enabled(if: customPan).onChange(sync),
            ]),
            PrefSection(tab: .audio, title: "Music", order: 30, items: [
                .toggle(AudioPrefs.ghostVoices, "Ghost voices: music survives sound effects", default: false,
                        help: "M12. Every shot takes one or two of Paula's four channels away from the music. With this on, the "
                        + "missing parts play on four extra host voices while the effect lasts, so the full arrangement keeps going.")
                    .coveringLive("audio.ghostVoices").onChange(sync).inMenu(.sound),
                .toggle(AudioPrefs.soundtrack, "Replacement soundtrack", default: false,
                        help: "M25. Plays your own audio files instead of the game's tunes (nothing is included). Sound effects are "
                        + "unchanged; tunes without a file play as usual. Follows F10 and the GAME OVER fade.")
                    .onChange { AudioEnhancements.shared.soundtrack.rescan() },
                .action("audio.soundtrackChoose", "Soundtrack folder", button: "Choose Folder…",
                        help: "Files named by tune: song0 (or 0, title), song1 (hiscore), song2 (jungle), song3 (loading, plays once), "
                        + "song4 (tunnels), song5 (finaljungle), song6 (flare). m4a, mp3, wav, aiff, caf, flac.") {
                    SoundtrackUI.chooseFolder()
                },
                .action("audio.soundtrackShow", "", button: "Show Folder in Finder") { SoundtrackUI.showFolder() },
            ]),
            PrefSection(tab: .audio, title: "Sound character", footer: "M25. Band-limited synthesis removes the metallic aliasing of "
                        + "Paula's hard sample steps (most audible on the high synth sounds with the A500 filter off). Legacy is the "
                        + "port's original output, bit for bit.", order: 40, items: [
                .choice(AudioPrefs.synthesis, "Synthesis", default: 0, [(0, "Legacy (original)"), (1, "Band-limited (BLEP)")])
                    .coveringLive("audio.synthesis").onChange(sync),
                .choice(AudioPrefs.ambience, "Ambience", default: 0, [(0, "Off (original)"), (1, "Automatic (per area)"), (2, "Jungle"),
                                                                        (3, "Hut"), (4, "Tunnels"), (5, "Night"), (6, "Bunker")],
                        help: "Reverb on the sound effects only (the music stays dry): open jungle, huts, tunnel echo, the flare night, "
                        + "the bunker. Automatic follows the area you are in.")
                    .coveringLive("audio.ambience").onChange(sync),
                .slider(AudioPrefs.ambienceLevel, "Ambience amount", default: 1, range: 0...2, step: 0.1, format: pct)
                    .coveringLive("audio.ambienceLevel").enabled(if: { Prefs.int(AudioPrefs.ambience) != 0 }).onChange(sync),
            ]),
            PrefSection(tab: .audio, title: "Output timing", footer: "M22. Smooth keeps the sound buffer at the chosen latency by "
                        + "resampling up to ±0.5 % instead of dropping whole blocks, so drifting clocks, variable-refresh displays and "
                        + "hiccups don't click. If the game runs slower than real time the sound follows at a lower pitch instead of stuttering.",
                        order: 50, items: [
                .choice(AudioPrefs.sync, "Buffer control", default: 0, [(0, "Original (drop when ahead)"), (1, "Smooth (dynamic rate control)")]).onChange(sync),
                .choice(AudioPrefs.latency, "Latency", default: 60, AudioPrefs.latencies.map { ($0, "\($0) ms") },
                        help: "Lower is more responsive, higher survives busy moments without gaps.").onChange(sync),
                .toggle(AudioPrefs.debugLog, "Log audio diagnostics (Console)", default: false,
                        help: "Every 2 s: buffer fill, resampling ratio, underruns, mixer state. Applies after relaunch."),
            ]),
        ]
    }
}

enum SoundtrackUI {
    static func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.directoryURL = SoundtrackController.folder
        p.message = "Choose the folder with your replacement tunes (song0 … song6)."
        if p.runModal() == .OK, let u = p.url {
            UserDefaults.standard.set(u.path, forKey: AudioPrefs.soundtrackFolder)
            AudioEnhancements.shared.soundtrack.rescan()
            let found = SoundtrackController.scan(u)
            AppServices.shared.toast(found.isEmpty ? "No tunes found in \(u.lastPathComponent)" :
                                        "Soundtrack: \(found.count) tune\(found.count == 1 ? "" : "s") (\(found.keys.sorted().map(String.init).joined(separator: ", ")))")
        }
    }
    static func showFolder() {
        let u = SoundtrackController.folder
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
}
