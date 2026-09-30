import AppKit
import UniformTypeIdentifiers
import PlatoonCore

// [assist] M17 input replays, app side. Records the input of every game since the last reset (InputRecorder,
// read-only), saves it as a .plreplay file (a platoon-headless script with a commented header), and plays replays
// back in a fresh Machine with the recorded configuration while the player's own input is muted.
// The last finished game and the best-scoring game are also kept automatically in
// Application Support/Platoon/replays/ (last.plreplay, best.plreplay).
//
// A played-back game is marked assisted ("Replay"): its score never enters the original table. Stop Replay hands
// the controls over at the current frame; the recording continues seamlessly, so "save replay" afterwards gives a
// file that reproduces both parts.

final class ReplayController {
    private(set) var recorder: InputRecorder?
    private(set) var player: InputPlayer?
    var isPlaying: Bool { player != nil }
    /// A replayed game (not counted in the service record / personal bests). False for test input fed with
    /// `inject … game`, which stands in for a player.
    var isReplayGame: Bool { player != nil && !injectedAsPlayer }
    private var injectedAsPlayer = false
    /// The replay being started (consumed by the next reset).
    private var pendingPlayback: InputReplay?
    /// Input.keyGapFrames for the pending playback: 0 for the app's own replays (they record key DELIVERIES), 2 for
    /// plain headless scripts (their key edges are paced by the queue like in platoon-headless: a press and its
    /// release on the same frame would otherwise reach the game within one frame and be missed).
    private var pendingKeyGap = 0
    static func keyGap(forFile text: String) -> Int { text.hasPrefix(ReplayHeader.magic) ? 0 : 2 }
    private var startConfigKnown = false
    private var header = ReplayHeader()
    /// The cheats the recorded game runs with (read from the game once it started; nil before).
    private var cheatsAtStart: CheatOptions?
    private var savedKeySink: ((UInt8, Bool) -> Void)?
    private var installedTransformOn: ObjectIdentifier?
    private weak var host: GameHost?
    private var finishedToastShown = false

    static let fileExtension = "plreplay"
    static var directory: URL { AssistCenter.supportDir.appendingPathComponent("replays", isDirectory: true) }

    func install(_ app: AppServices) {
        app.onHostReady { [weak self] h in self?.hostDidReset(h) }
    }

    // MARK: lifecycle

    func hostDidReset(_ h: GameHost) {
        host = h
        installMute(h)
        if let r = pendingPlayback {
            pendingPlayback = nil
            player = InputPlayer(r)
            injectedAsPlayer = false
            finishedToastShown = false
            h.machine.input.keyGapFrames = pendingKeyGap   // replays: keys are delivered at their recorded frame
            pendingKeyGap = 0
            header = r.header
            header.created = Date()
            startConfigKnown = true
        } else {
            if player != nil { endPlayback(h, toast: nil) }
            header = ReplayHeader()
            header.adfTag = GameSnapshot.adfTag(h.disk)
            startConfigKnown = false
        }
        // (a played-back replay keeps its header, incl. a legacy `# trainer` line; new recordings have none: the
        // cheats are enhancement options, recorded in `# enh`)
        cheatsAtStart = nil
        recorder = Prefs.bool(AssistPrefs.replayRecord) || player != nil ? InputRecorder(machine: h.machine) : nil
        if let rec = recorder, !rec.valid { rec.invalidate("the game was restored from a save state") }
    }

    /// Every emulated frame (after the input layer ran).
    func frame(_ ctx: FrameContext) {
        let m = ctx.machine
        if let p = player {
            p.apply(m)
            if p.finished && !finishedToastShown {
                finishedToastShown = true
                endPlayback(ctx.host, toast: "Replay finished — you have the controls")
            }
        }
        guard let rec = recorder else { return }
        if !startConfigKnown, m.frameCount > 0, let cfg = PlatoonGame.runConfiguration(m) {
            startConfigKnown = true
            header.startSection = cfg.startSection
            header.carry = cfg.carry
            header.enhancements = cfg.enhancements.changed
            header.deterministic = cfg.deterministic
            if cfg.enhancements.section1.directAim { header.warnings.append("s1.directAim: pointer aiming is not in the input stream") }
        }
        rec.observe(m)
        if let c = PlatoonGame.cheats(m) {
            if cheatsAtStart == nil { cheatsAtStart = c }
            else if c != cheatsAtStart { rec.invalidate("the cheats were changed during the game") }
        }
    }

    func display(_ ctx: FrameContext) {}

    // MARK: muting the player's input during playback

    private func installMute(_ h: GameHost) {
        let id = ObjectIdentifier(h.inputManager)
        guard installedTransformOn != id else { return }
        installedTransformOn = id
        h.inputManager.joyTransforms.append { [weak self] j in
            if self?.isPlaying == true { j = InputManager.JoyState() }
        }
    }

    private func mute(_ h: GameHost) {
        savedKeySink = h.inputManager.keySink
        h.inputManager.releaseAll()
        h.inputManager.keySink = { _, _ in }
        h.inputManager.refresh()
    }
    private func unmute(_ h: GameHost) {
        h.inputManager.keySink = savedKeySink
        savedKeySink = nil
        h.inputManager.refresh()
    }

    // MARK: recording

    /// The replay of the current game, or a reason why there is none.
    func currentReplay() -> Result<InputReplay, ReplayError> {
        guard let rec = recorder else {
            return .failure(.message(Prefs.bool(AssistPrefs.replayRecord) ? "Nothing has been recorded yet." :
                                        "Recording is off (Preferences ▸ Assist ▸ Replays)."))
        }
        if let why = rec.brokenReason { return .failure(.message("This game can't be replayed: \(why).")) }
        var h = header
        if let host { h.score = host.probe.context.score }
        var r = rec.replay(header: h)
        // headless playback paces keys like the original (gap 2): fine as long as no two deliveries are closer
        r.header.keyGap = r.minKeySpacing.map { $0 >= 3 ? 2 : 0 } ?? 2
        return .success(r)
    }

    enum ReplayError: Error { case message(String) }

    func saveInteractively() {
        switch currentReplay() {
        case .failure(.message(let m)): AppServices.shared.toast(m, seconds: 3)
        case .success(let r):
            let p = NSSavePanel()
            p.allowedContentTypes = [UTType(filenameExtension: ReplayController.fileExtension) ?? .plainText, .plainText]
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
            p.nameFieldStringValue = "Platoon \(f.string(from: Date())).\(ReplayController.fileExtension)"
            p.directoryURL = ReplayController.directory
            try? FileManager.default.createDirectory(at: ReplayController.directory, withIntermediateDirectories: true)
            AppServices.shared.pause(.dialog)
            let resp = p.runModal()
            AppServices.shared.resume(.dialog)
            guard resp == .OK, let url = p.url else { return }
            do { try write(r, to: url); AppServices.shared.toast("Replay saved (\(r.header.frames / 50) s)") }
            catch { AppServices.shared.toast("Could not save the replay: \(error.localizedDescription)", seconds: 4) }
        }
    }

    func write(_ r: InputReplay, to url: URL) throws {
        try r.encoded().write(to: url, atomically: true, encoding: .utf8)
        if let c = r.carryData { try c.write(to: url.deletingPathExtension().appendingPathExtension("carry")) }
    }

    /// Game over of a recorded (not replayed) game: keep last.plreplay and, for a new best score, best.plreplay.
    func gameEnded(score: Int) {
        guard !isReplayGame, case .success(let r) = currentReplay() else { return }
        let dir = ReplayController.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? write(r, to: dir.appendingPathComponent("last.\(ReplayController.fileExtension)"))
        let bestURL = dir.appendingPathComponent("best.\(ReplayController.fileExtension)")
        let best = (try? String(contentsOf: bestURL, encoding: .utf8)).flatMap { try? InputReplay.decode($0) }?.header.score ?? -1
        if score > best { try? write(r, to: bestURL) }
    }

    // MARK: playback

    func playInteractively() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: ReplayController.fileExtension) ?? .plainText, .plainText]
        p.directoryURL = ReplayController.directory
        AppServices.shared.pause(.dialog)
        let resp = p.runModal()
        AppServices.shared.resume(.dialog)
        guard resp == .OK, let url = p.url else { return }
        play(url: url)
    }

    func play(url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var r = try InputReplay.decode(text)
            if r.header.carry == nil, let c = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("carry")) {
                r.header.carry = [UInt8](c)
            }
            play(r, keyGap: ReplayController.keyGap(forFile: text))
        } catch {
            AppServices.shared.toast("Can't play this replay: \(error)", seconds: 4)
        }
    }

    func play(_ r: InputReplay, keyGap: Int = 0) {
        guard let h = AppServices.shared.host else { return }
        pendingKeyGap = keyGap
        var notes: [String] = []
        if r.header.adfTag != 0 && r.header.adfTag != GameSnapshot.adfTag(h.disk) { notes.append("recorded with a different disk image") }
        if r.header.buildTag != GameSnapshot.buildTag { notes.append("recorded with another build of the app") }
        notes += r.header.warnings
        // replays recorded before the cheats existed may carry the legacy host trainer (`# trainer` line): it is
        // applied during playback exactly as it was recorded; the cheats themselves come with the recorded `# enh`
        h.legacyTrainer = Trainer(infiniteAmmo: r.header.trainer.contains("ammo"), infiniteMorale: r.header.trainer.contains("morale"),
                                  invulnerable: r.header.trainer.contains("invulnerable"))
        pendingPlayback = r
        h.resumeAll()
        mute(h)
        h.restoreGame(section: r.header.startSection ?? 0, reason: "Replay") { m, cfg in
            var c = cfg
            c.enhancements = Enhancements()
            _ = c.enhancements.apply(r.header.enhancements)
            c.startSection = r.header.startSection
            c.carry = r.header.carry
            c.deterministicRNG = r.header.deterministic   // headless-made replays (verification scripts)
            c.hiscoreURL = nil                          // never write a hiscore file from a replay
            c.assistedReasons.insert("Replay")           // survives the replayed game's own new-game start
            m.start { PlatoonGame.main($0, config: c) }
        }
        AppServices.shared.toast("Playing replay" + (notes.isEmpty ? "" : " — " + notes.joined(separator: "; ")), seconds: notes.isEmpty ? 2 : 5)
    }

    /// Tests: feeds a replay's input into the running game from its current frame (no restart).
    func inject(url: URL, asPlayer: Bool = false) {
        guard let h = AppServices.shared.host, let t = try? String(contentsOf: url, encoding: .utf8),
              let r = try? InputReplay.decode(t) else { AppServices.shared.toast("inject: can't read \(url.path)"); return }
        mute(h)
        h.machine.input.keyGapFrames = ReplayController.keyGap(forFile: t)
        player = InputPlayer(r)
        injectedAsPlayer = asPlayer
        finishedToastShown = false
    }

    /// Hands the controls to the player (keeps the game running from here).
    func stopPlayback() {
        guard let h = host, player != nil else { return }
        endPlayback(h, toast: "Replay stopped — you have the controls")
    }

    private func endPlayback(_ h: GameHost, toast: String?) {
        player = nil
        injectedAsPlayer = false
        unmute(h)
        h.applyInputSettings()
        if h.legacyTrainer.isActive {
            h.legacyTrainer = Trainer()
            recorder?.invalidate("the replay's trainer ended with it")
        }
        // from here the Cheats preferences apply again (GameHost.syncCheats); if they differ from the replay's,
        // the recording of this game is invalidated at the next frame
        if let t = toast { AppServices.shared.toast(t, seconds: 3) }
    }

    var statusText: String? {
        guard let p = player else { return nil }
        return "REPLAY \(Int(p.progress * 100))%"
    }
}
