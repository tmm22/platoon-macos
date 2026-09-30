import Foundation
import QuartzCore
import PlatoonCore

/// Owns the running game and paces it at 50 Hz (PAL) independent of the display refresh rate.
final class GameHost {
    let disk: Disk
    private(set) var machine: Machine
    let audio = AudioOutput()
    let inputManager = InputManager()
    /// F1 context probe + F2 game events + F4 assisted marking (core, Enhance/GameProbe.swift). One per host,
    /// reused across resets, so observers registered on it stay valid. `probe.context` is refreshed every frame.
    let probe = GameProbe()

    // MARK: pause (S4)
    /// The game runs only while no reason is set.
    private(set) var pauseReasons = Set<PauseReason>()
    /// Compatibility switch: true adds the `.user` reason; false clears every reason.
    var paused: Bool {
        get { !pauseReasons.isEmpty }
        set { if newValue { pause(.user) } else { resumeAll() } }
    }
    func pause(_ r: PauseReason) {
        let was = paused
        pauseReasons.insert(r)
        if !was { didChangePause() }
    }
    func resume(_ r: PauseReason) {
        guard pauseReasons.remove(r) != nil, !paused else { return }
        didChangePause()
    }
    func resumeAll() {
        guard paused else { return }
        pauseReasons.removeAll()
        didChangePause()
    }
    private func didChangePause() {
        if paused { inputManager.suspend(); audio.flush() } else { inputManager.resume() }
        last = 0
        AppServices.shared.dispatchPause(paused)
    }

    // MARK: speed (S11)
    /// Sticky turbo (⌘T; not persisted).
    var turbo = false
    /// Momentary fast-forward: true while the fast-forward key / button is held.
    var fastForwardHeld = false
    /// Emulated frames per real frame while fast-forwarding or in turbo.
    var fastForwardSpeed: Int { max(2, min(8, Prefs.int(BuiltinPrefs.ffSpeed))) }
    var isFastForwarding: Bool { (fastForwardHeld || turbo) && !paused }

    private var last: CFTimeInterval = 0
    private var acc: Double = 0
    static let frameTime = 1.0 / 50.0

    // MARK: game speed (accessibility slow motion, M22 audio side)
    /// 0.6 ... 1.0 of real time (General ▸ Game speed). Below 1 the run is assisted.
    private(set) var speed: Double = 1
    /// `mark`: a change during a run marks it assisted (at game start the gameplay pref itself does, via the config).
    func applySpeedSetting(mark: Bool = true) {
        let pct = Prefs.int(BuiltinPrefs.gameSpeed)
        speed = pct >= 60 && pct < 100 ? Double(pct) / 100 : 1
        audio.stream.speedHint = speed < 1 ? speed : nil        // Smooth rate control follows at a lower pitch
        if speed < 1 && mark { markAssisted("Game speed") }       // same reason as the gameplay pref at game start
    }

    // MARK: run state (host-side, main thread)
    /// Load section currently being played (probe context), nil on the title / loading / game over.
    var currentSection: Int? { probe.context.section }
    /// The a6 globals at the start of the current section (for "Restart section").
    private(set) var sectionStartCarry: [UInt8]?
    /// The a6 globals at the start of each section of the current game (a rewind or checkpoint retry goes back
    /// within the same game, possibly into the previous section: "Restart section" then still restarts with the
    /// platoon that arrived there, instead of a fresh one).
    private var sectionCarries: [Int: [UInt8]] = [:]
    /// Host-side reasons why the current run is assisted (F4/S5), in addition to the core's own
    /// (enhancements, cheats, start section) which are in `probe.context.assistReasons`.
    private var hostAssistedReasons: [String] = []
    var assistedReasons: [String] { Array(Set(hostAssistedReasons + probe.context.assistReasons)).sorted() }
    var isAssisted: Bool { !assistedReasons.isEmpty }
    /// The enhancements of the current run (as passed at game start).
    private(set) var runEnhancements = Enhancements()
    /// Values of restart-only prefs when this run started (for the "applies after restart" hint).
    private(set) var runPrefsSnapshot: [String: String] = [:]
    /// Section-start reports from the game thread, delivered on the main thread at the next frame boundary.
    private var pendingSectionStarts: [(Int, [UInt8])] = []
    private let pendingLock = NSLock()

    /// Reasons that come from the settings of the current run (they stay across new games from the title).
    private var configAssistedReasons: [String] = []
    /// Reasons already marked in the current game by `markAssistedOnce` (a new game or a reset re-arms them).
    private var markedThisGame = Set<String>()

    init(disk: Disk) {
        self.disk = disk
        machine = Machine(disk: disk)
        // A new game from the title (no Machine reset): the core forgets the previous game's marks, so the host
        // does too, and features that mark "once per game" are re-armed.
        probe.addObserver { [weak self] r in
            guard let self, case .newGame = r.event else { return }
            self.hostAssistedReasons = self.configAssistedReasons
            self.markedThisGame.removeAll()
            self.sectionCarries.removeAll()
            // live gameplay prefs (game speed) count for this game only if they are still on now (the core marks
            // the cheats that are on itself)
            for reason in PrefsRegistry.liveGameplayReasons() { self.markAssisted(reason) }
            AppServices.shared.dispatchNewGame(self)
        }
        wire()
        let cfg = makeConfig()
        machine.start { PlatoonGame.main($0, config: cfg) }
    }

    /// The GameConfig for a new run: hiscores, section-start reporting, and every pref's enhancement / config
    /// plumbing from the Preferences registry.
    func makeConfig(startSection: Int? = nil, carry: [UInt8]? = nil) -> GameConfig {
        var c = GameConfig()
        // PLATOON_SUPPORT_DIR (tests) replaces Application Support/Platoon, as for the disk and the assist files
        let supportDir = ProcessInfo.processInfo.environment["PLATOON_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Platoon", isDirectory: true)
        if let dir = supportDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            c.hiscoreURL = dir.appendingPathComponent("hiscores.bin")
        }
        c.startSection = startSection
        c.carry = carry
        c.onSectionStart = { [weak self] section, a6 in
            // game thread: the host thread is blocked in runFrame, so this is serialized with the main thread
            // Section 0 re-initialises the platoon, so only the later sections are worth continuing from.
            // A replay being watched or a practice drill is not the player's game: it must not move the player's
            // Continue point (AssistCenter was created at launch; the main thread is parked in runFrame here).
            let assist = AssistCenter.shared
            if section > 0 && !assist.replays.isReplayGame && assist.practice.drill == nil {
                Settings.shared.continueSection = section
                Settings.shared.continueCarry = Data(a6)
            }
            guard let self else { return }
            self.pendingLock.lock(); self.pendingSectionStarts.append((section, a6)); self.pendingLock.unlock()
        }
        hostAssistedReasons = PrefsRegistry.apply(to: &c)
        // Restart-only host gameplay prefs (randomiser modes ...) hold for every game of this run; the live ones
        // (game speed; cheats in the core) are marked per game at its start (newGame observer / markAssisted), so switching
        // them off before a new game from the title gives an ordinary game again.
        configAssistedReasons = hostAssistedReasons.filter { !PrefsRegistry.isLiveGameplayReason($0) }
        markedThisGame.removeAll()
        // host-only gameplay prefs without an enhancement key taint through the core's F4 flag too
        c.assistedReasons.formUnion(configAssistedReasons)
        c.probe = probe
        runEnhancements = c.enhancements
        runPrefsSnapshot = PrefsRegistry.restartSnapshot()
        return c
    }

    /// Marks the run as assisted (F4/S5). The core's tainted-run flag is set through the enhancement registry
    /// when it exists; until then the host keeps the reasons for display.
    func markAssisted(_ reason: String) {
        if !hostAssistedReasons.contains(reason) { hostAssistedReasons.append(reason) }
        probe.markAssisted(reason)
    }
    /// Marks the game assisted the first time a feature acts in it (cheap to call every frame).
    func markAssistedOnce(_ reason: String) {
        if markedThisGame.insert(reason).inserted { markAssisted(reason) }
    }

    // MARK: cheats (Prefs/PrefsCheats.swift; core Enhance/CheatOptions.swift)

    /// The legacy host trainer: only active while a replay recorded with it (`# trainer` header) plays back.
    var legacyTrainer = Trainer()
    /// Keeps the running game's cheats in line with the Cheats preferences (every frame, game thread parked).
    /// Not while a replay plays: it runs with the cheats it was recorded with.
    private func syncCheats(_ m: Machine) {
        guard !AssistCenter.shared.replays.isPlaying, let running = PlatoonGame.cheats(m) else { return }
        let want = CheatPrefs.current
        if running != want { PlatoonGame.setCheats(m, want) }
    }

    /// Keys held for a few frames by `holdKey` (original cheat keys: the section loops test them once per tick).
    private var heldKeys: [(code: UInt8, frames: Int)] = []
    /// Presses an Amiga key and releases it `frames` frames later (long enough for a 2- or 4-frame game tick to
    /// see it, also with the faster key delivery).
    func holdKey(_ code: UInt8, frames: Int = 10) {
        machine.input.key(code, down: true)
        heldKeys.append((code, frames))
    }
    private func releaseHeldKeys(_ m: Machine) {
        guard !heldKeys.isEmpty else { return }
        for i in heldKeys.indices { heldKeys[i].frames -= 1 }
        for k in heldKeys where k.frames <= 0 { m.input.key(k.code, down: false) }
        heldKeys.removeAll { $0.frames <= 0 }
    }

    /// Audio of the current emulated frame is kept (false = dropped: fast-forward keeps only the last frame of
    /// each batch so the output stays real-time instead of overrunning the ring buffer).
    private var keepAudio = true
    private var audioGain: Float = 1

    private func wire() {
        heldKeys.removeAll()
        machine.frameHook = { [weak self] m in
            guard let self else { return }
            if self.legacyTrainer.isActive { self.legacyTrainer.apply(to: m) }   // (the core marks it assisted)
            self.syncCheats(m)
            self.releaseHeldKeys(m)
            // S18: while the name is typed on the keyboard, letter keys / Space must not also press fire
            self.inputManager.keyboardFireSuppressed = self.runEnhancements.kernel.keyboardNameEntry && self.probe.context.screen == .nameEntry
            self.deliverSectionStarts()
            AppServices.shared.dispatchFrame(self)
        }
        machine.chip.paula.output = { [weak self, audio] buf in
            guard let self, self.keepAudio else { return }
            if self.audioGain == 1 { audio.push(buf) } else { audio.push(buf, gain: self.audioGain) }
        }
        inputManager.input = machine.input
        applyAudioSettings()
        applyInputSettings()
        applySpeedSetting(mark: false)
    }

    /// Host input options on the current machine (M25 faster key delivery; 2 = original pacing).
    func applyInputSettings() {
        machine.input.keyGapFrames = Prefs.bool(BuiltinPrefs.fastKeys) ? 0 : 2
    }

    private func deliverSectionStarts() {
        pendingLock.lock(); let p = pendingSectionStarts; pendingSectionStarts.removeAll(); pendingLock.unlock()
        for (s, a6) in p {
            sectionStartCarry = a6
            sectionCarries[s] = a6
            AppServices.shared.dispatchSection(s)
        }
    }

    func applyAudioSettings() {
        let s = Settings.shared, p = machine.chip.paula
        p.interpolate = s.interpolate; p.filterEnabled = s.a500Filter
        p.stereoSeparation = Float(s.separation); p.volume = Float(s.volume)
    }

    /// Taps an Amiga key (press now, release a few frames later).
    func tapKey(_ code: UInt8) {
        machine.input.key(code, down: true)
        machine.input.key(code, down: false)
    }

    func reset(startSection: Int? = nil, carry: [UInt8]? = nil) {
        machine.stop()
        machine = Machine(disk: disk)
        wire()
        audio.flush()
        sectionStartCarry = nil; sectionCarries.removeAll(); hostAssistedReasons = []
        pendingLock.lock(); pendingSectionStarts.removeAll(); pendingLock.unlock()
        let cfg = makeConfig(startSection: startSection, carry: carry)
        machine.start { PlatoonGame.main($0, config: cfg) }
        acc = 0; last = 0
        inputManager.releaseAll()
        AppServices.shared.dispatchReset(self)
    }

    /// Replaces the running game with a restored one (snapshot agent: savestates / checkpoints / rewind).
    /// `start` receives a fresh Machine and the current config and must start the game thread on it
    /// (e.g. `{ m, cfg in PlatoonGame.resume(m, from: snap, config: cfg) }`). The run is marked assisted.
    /// `sameGame`: the snapshot comes from the game being played (rewind, checkpoint retry), so the section-start
    /// platoon of `section` is still known; otherwise (a loaded slot, a replay, a drill) it is not.
    func restoreGame(section: Int, reason: String, sameGame: Bool = false, _ start: (Machine, GameConfig) -> Void) {
        machine.stop()
        machine = Machine(disk: disk)
        wire()
        audio.flush()
        pendingLock.lock(); pendingSectionStarts.removeAll(); pendingLock.unlock()
        let cfg = makeConfig()
        if !sameGame { sectionCarries.removeAll() }
        sectionStartCarry = sectionCarries[section]
        start(machine, cfg)
        markAssisted(reason)
        for r in PrefsRegistry.liveGameplayReasons() { markAssisted(r) }   // no newGame event in a resumed game
        acc = 0; last = 0
        inputManager.releaseAll()
        AppServices.shared.dispatchReset(self)
    }

    private func runFrames(_ n: Int) {
        for k in 0..<n {
            keepAudio = n == 1 || k == n - 1
            machine.runFrame()
        }
        keepAudio = true
    }

    /// Runs as many emulated frames as are due. Returns true if a new frame was produced.
    @discardableResult func tick() -> Bool {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard !paused, last > 0 else { return false }
        let dt = min(0.25, now - last)
        let perTick = isFastForwarding ? fastForwardSpeed : 1
        audioGain = perTick > 1 ? Float(Prefs.double(BuiltinPrefs.ffVolume)) : 1
        let ft = GameHost.frameTime / speed
        // Display running at ~50 Hz (e.g. a variable-refresh display): one Amiga frame per display frame,
        // so every frame is shown exactly once and scrolling stays perfectly smooth.
        if speed >= 1 && abs(dt - ft) < ft * 0.15 {
            runFrames(perTick)
            acc = 0
            return true
        }
        acc += dt
        var ran = false, n = 0
        while acc >= ft && n < 5 {
            runFrames(perTick)
            acc -= ft; ran = true; n += 1
        }
        if n == 5 { acc = 0 }
        return ran
    }

    /// Runs exactly one emulated frame regardless of pacing/pause (debug scripts).
    func stepFrame() { runFrames(1) }
}
