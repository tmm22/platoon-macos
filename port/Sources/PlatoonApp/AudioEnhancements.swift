import AppKit
import PlatoonCore

// OWNER: [audio]. App side of the audio enhancements (S10 mixer, M12 ghost voices, M22 output timing, M25 BLEP /
// ambience / replacement soundtrack). Everything is host presentation: nothing here writes game RAM, so no option
// taints a run. Settings live in UserDefaults (declared in Prefs/PrefsAudio.swift) and are applied to the running
// machine's Paula and to the AudioOutput once per displayed frame (cheap compares), so every way of changing a
// pref (Preferences window, menus, PLATOON_PREFS, debug scripts) takes effect at once, and after every reset.

enum AudioPrefs {
    static let musicVolume = "audio.musicVolume"
    static let sfxVolume = "audio.sfxVolume"
    static let panPreset = "audio.panPreset"
    static let pan = ["audio.pan0", "audio.pan1", "audio.pan2", "audio.pan3"]
    static let ghostVoices = "audio.ghostVoices"
    static let synthesis = "audio.synthesis"
    static let ambience = "audio.ambience"
    static let ambienceLevel = "audio.ambienceLevel"
    static let sync = "audio.outputSync"
    static let latency = "audio.latencyMs"
    static let soundtrack = "audio.replacementSoundtrack"
    static let soundtrackFolder = "audio.soundtrackFolder"
    static let debugLog = "audio.debugLog"

    /// Pan presets (voice 0..3); index 0 = the Amiga's L R R L; the last entry = custom sliders.
    static let panPresets: [(String, [Float])] = [
        ("Amiga (L R R L)", [-1, 1, 1, -1]),
        ("Swapped (R L L R)", [1, -1, -1, 1]),
        ("Soft (L R R L at 50 %)", [-0.5, 0.5, 0.5, -0.5]),
        ("Mono", [0, 0, 0, 0]),
        ("Custom (sliders below)", []),
    ]
    static var customPan: Int { panPresets.count - 1 }
    static let ambienceChoices: [PaulaAmbience] = [.off, .auto, .jungle, .hut, .tunnels, .night, .bunker]
    static let latencies = [20, 40, 60, 100, 150]
}

final class AudioEnhancements {
    static let shared = AudioEnhancements()
    let soundtrack = SoundtrackController()

    /// Current values -> the host's Paula and AudioOutput (only assigns what changed).
    func sync(_ host: GameHost) {
        let p = host.machine.chip.paula
        let mg = Float(Prefs.double(AudioPrefs.musicVolume)), sg = Float(Prefs.double(AudioPrefs.sfxVolume))
        if p.musicGain != mg { p.musicGain = mg }
        if p.sfxGain != sg { p.sfxGain = sg }
        let preset = Prefs.int(AudioPrefs.panPreset)
        let pan: [Float] = preset >= 0 && preset < AudioPrefs.customPan ? AudioPrefs.panPresets[preset].1
            : AudioPrefs.pan.map { Float(Prefs.double($0)) }
        if p.pan != pan { p.pan = pan }
        let g = Prefs.bool(AudioPrefs.ghostVoices)
        if p.ghostVoices != g { p.ghostVoices = g }
        let syn: PaulaSynthesis = Prefs.int(AudioPrefs.synthesis) == 1 ? .blep : .legacy
        if p.synthesis != syn { p.synthesis = syn }
        let ai = Prefs.int(AudioPrefs.ambience)
        let amb = ai >= 0 && ai < AudioPrefs.ambienceChoices.count ? AudioPrefs.ambienceChoices[ai] : .off
        if p.ambience != amb { p.ambience = amb }
        let al = Float(Prefs.double(AudioPrefs.ambienceLevel))
        if p.ambienceLevel != al { p.ambienceLevel = al }
        let s = host.audio.stream
        // M22: a host running slower than real time (game speed < 100 %, sets `stream.speedHint`) needs the
        // rate-controlled stream (lower pitch instead of underrun stutter), whatever the buffer-control choice.
        let slow = (s.speedHint ?? 1) < 0.999
        let mode: HostAudioStream.Mode = Prefs.int(AudioPrefs.sync) == 1 || slow ? .adaptive : .legacy
        if s.mode != mode { s.mode = mode }
        let lat = Double(max(10, Prefs.int(AudioPrefs.latency))) / 1000
        if abs(s.latency - lat) > 1e-9 { s.latency = lat }
    }

    func install(_ app: AppServices) {
        app.onHostReady { [weak self] host in self?.sync(host); self?.soundtrack.reset() }
        app.onReset { [weak self] host in self?.sync(host); self?.soundtrack.reset() }
        app.onDisplay { [weak self] ctx in self?.sync(ctx.host) }
        app.onFrame { [weak self] ctx in self?.soundtrack.update(ctx.host) }
        app.onPauseChange { [weak self] paused in self?.soundtrack.hostPaused(paused) }
        if let path = ProcessInfo.processInfo.environment["PLATOON_DEBUG_AUDIO_WAV"] {   // app-level audio tests
            app.onHostReady { host in
                host.audio.startRecording(to: URL(fileURLWithPath: path))
                NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    host.audio.stopRecording()
                }
            }
        }
        if Prefs.bool(AudioPrefs.debugLog) {
            var n = 0
            app.onDisplay { ctx in
                n += 1
                guard n % 100 == 0 else { return }
                let st = ctx.host.audio.stream.stats, p = ctx.machine.chip.paula
                NSLog("audio: frame=\(ctx.frame) mixer=\(p.mixerActive) ghosts=\(p.ghostVoices) syn=\(p.synthesis.rawValue) amb=\(p.ambience.rawValue)/\(p.ambienceArea.rawValue) "
                      + "sync=\(ctx.host.audio.stream.mode) fill=\(st.fillFrames) ratio=\(String(format: "%.5f", st.ratio)) under=\(st.underruns) over=\(st.overruns) drops=\(st.droppedBlocks) "
                      + "speed=\(String(format: "%.3f", st.producerSpeed)) soundtrack=\(self.soundtrack.status)")
            }
        }
    }
}

/// M25 user-supplied replacement soundtrack: while the game plays tune N and a file for N is in the soundtrack
/// folder, the file plays instead (music-tagged Paula voices and ghosts muted, sound effects unchanged). Follows the
/// driver's playing flag ($2d9f: F10 music off, game over), the song starts it cues (md_init_song) and the master
/// volume $2d98 (GAME OVER fade). Tune 3 (LOADING / message screens) plays once, the others loop. Nothing is bundled.
final class SoundtrackController {
    static let songNames: [[String]] = [
        ["title"], ["hiscore", "highscore", "hiscores"], ["jungle", "village", "section0"], ["loading", "intro", "message"],
        ["tunnels", "tunnel", "section1"], ["finaljungle", "foxhole", "section2"], ["flare", "bunker", "night"],
    ]
    static let extensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "flac", "aac", "mp4"]

    private var lastCue = -1
    private var currentSong = -1
    private var hostIsPaused = false
    private var files: [Int: URL] = [:]
    private var filesScanned: Date?
    private(set) var status = "off"

    static var defaultFolder: URL {
        if let d = ProcessInfo.processInfo.environment["PLATOON_SUPPORT_DIR"] { return URL(fileURLWithPath: d).appendingPathComponent("Soundtrack", isDirectory: true) }
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return sup.appendingPathComponent("Platoon/Soundtrack", isDirectory: true)
    }
    static var folder: URL {
        if let s = UserDefaults.standard.string(forKey: AudioPrefs.soundtrackFolder), !s.isEmpty { return URL(fileURLWithPath: s, isDirectory: true) }
        return defaultFolder
    }

    /// Song number for a file name ("song2.mp3", "2 - Jungle.m4a", "tunnels.wav", ...), nil if none.
    static func song(forFileName name: String) -> Int? {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let compact = base.filter { $0.isLetter || $0.isNumber }
        for n in 0..<7 {
            if compact == "song\(n)" || compact == "tune\(n)" { return n }
        }
        if let f = base.first, let d = f.wholeNumberValue, d < 7 {
            let rest = base.dropFirst()
            if rest.isEmpty || !(rest.first!.isNumber) { return d }
        }
        for (n, names) in songNames.enumerated() where names.contains(compact) { return n }
        return nil
    }

    static func scan(_ dir: URL) -> [Int: URL] {
        var out: [Int: URL] = [:]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where extensions.contains(u.pathExtension.lowercased()) {
            if let n = song(forFileName: u.lastPathComponent), out[n] == nil { out[n] = u }
        }
        return out
    }

    /// Files found for each tune (rescanned at most every 2 s).
    var availableFiles: [Int: URL] {
        if filesScanned == nil || Date().timeIntervalSince(filesScanned!) > 2 { files = SoundtrackController.scan(SoundtrackController.folder); filesScanned = Date() }
        return files
    }
    func rescan() { filesScanned = nil }

    /// Set by `reset()`: the next update keeps a file that is still playing if the new machine plays the same tune
    /// (a loaded save, checkpoint retry or rewind restores the game mid-tune; the file should not restart).
    private var adopting = false

    func reset() {
        lastCue = -1; adopting = currentSong >= 0
        if !adopting { AppServices.shared.host?.audio.stopSoundtrack() }
        status = Prefs.bool(AudioPrefs.soundtrack) ? (adopting ? status : "idle") : "off"
    }

    func hostPaused(_ p: Bool) {
        hostIsPaused = p
        AppServices.shared.host?.audio.pauseSoundtrack(p)
    }

    /// Every emulated frame (frameHook: the game thread is parked, RAM reads are race-free).
    func update(_ host: GameHost) {
        let p = host.machine.chip.paula, audio = host.audio
        let enabled = Prefs.bool(AudioPrefs.soundtrack)
        p.cueSongs = enabled
        guard enabled else {
            if currentSong >= 0 || p.musicReplaced { audio.stopSoundtrack(); currentSong = -1; p.musicReplaced = false; status = "off" }
            return
        }
        let mem = host.machine.memory
        let playing = mem.r8(0x2d9f) != 0                        // driver: playing flag (0 after stop / F10 off)
        let song = p.cuedSong >= 0 ? p.cuedSong : Int(mem.r16(0x12cce) & 0xff)   // kernel $12cce current tune
        let cue = p.songCues
        if adopting {
            adopting = false
            if playing && song == currentSong && audio.soundtrackPlaying { lastCue = cue }   // same tune: keep the file going
        }
        if playing {
            if cue != lastCue || song != currentSong {
                lastCue = cue; currentSong = song
                if let url = availableFiles[song], audio.playSoundtrack(url, loop: song != 3) {
                    if hostIsPaused { audio.pauseSoundtrack(true) }
                    status = "tune \(song): \(url.lastPathComponent)"
                } else {
                    audio.stopSoundtrack()
                    status = "tune \(song): original (no file)"
                }
            }
        } else if currentSong >= 0 {
            audio.stopSoundtrack(); currentSong = -1; lastCue = cue
            status = "idle"
        }
        let replaced = playing && audio.soundtrackPlaying
        if p.musicReplaced != replaced { p.musicReplaced = replaced }
        if replaced {
            let master = Float(min(64, Int(mem.r16(0x2d98)))) / 64
            let ff: Float = host.isFastForwarding ? Float(Prefs.double(BuiltinPrefs.ffVolume)) : 1
            audio.soundtrackVolume = master * Float(Prefs.double(AudioPrefs.musicVolume)) * Float(Settings.shared.volume) * ff
        }
    }
}
