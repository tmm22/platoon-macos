import AppKit
import PlatoonCore

// [assist] App side of the read-only assists (S8, M2, M16, M17) and practice (M11). One object owns the models
// (PlatoonCore/Game/Assist/*) and wires them to the F1 context / F2 events of the host's GameProbe and to the
// AppServices frame hooks. Installed once at launch from Menus/MenuAssist.swift (FeatureHooks.assistInstall).
//
// Threading: everything runs on the main thread. onFrame observers run inside Machine.frameHook with the game
// thread parked (RAM reads safe); probe observers run in the same frameHook, right after it (GameProbe.poll).

final class AssistCenter {
    static let shared = AssistCenter()
    private init() {}

    // models
    let messageLog = MessageLog()
    let objectives = ObjectiveTracker()
    let timer = RunTimer()
    let recorder = ServiceRecorder()
    var records = SpeedrunRecords()
    /// The personal bests as they were when the current run started (the live deltas compare against these, so a
    /// run that just set a new PB still shows how much it gained).
    private(set) var comparison = SpeedrunRecords()
    let speech = AssistSpeech()
    let replays = ReplayController()
    let practice = PracticeController()

    // panels
    private(set) var captionPanel: CaptionPanel!
    private(set) var objectivesPanel: ObjectivesPanel!
    private(set) var hudPanel: HudReadoutPanel!
    private(set) var briefingPanel: BriefingPanel!
    private(set) var timerPanel: TimerPanel!
    private(set) var logPanel: MessageLogPanel!
    private(set) var practiceBadge: PracticeBadgePanel!
    private(set) var difficultyBadge: DifficultyBadgePanel!

    private var installed = false
    private weak var probeOwner: GameHost?
    /// Last context seen in onFrame (for event handlers).
    private(set) var lastContext: GameContext?

    var host: GameHost? { AppServices.shared.host }

    func install(_ app: AppServices) {
        guard !installed else { return }
        installed = true
        loadRecords()
        captionPanel = CaptionPanel(); app.overlay.add(captionPanel)
        objectivesPanel = ObjectivesPanel(); app.overlay.add(objectivesPanel)
        hudPanel = HudReadoutPanel(); app.overlay.add(hudPanel)
        briefingPanel = BriefingPanel(); app.overlay.add(briefingPanel)
        timerPanel = TimerPanel(); app.overlay.add(timerPanel)
        logPanel = MessageLogPanel(); app.overlay.add(logPanel)
        practiceBadge = PracticeBadgePanel(); app.overlay.add(practiceBadge)
        difficultyBadge = DifficultyBadgePanel(); app.overlay.add(difficultyBadge)

        app.onHostReady { [weak self] h in self?.attach(h) }
        app.onReset { [weak self] h in self?.didReset(h) }
        app.onFrame { [weak self] ctx in self?.frame(ctx) }
        app.onDisplay { [weak self] ctx in self?.display(ctx) }

        app.addPauseMenuItem(PauseMenuItem(id: "assist.log", title: { "Message Log" }, order: 200,
                                           action: { [weak self] in DispatchQueue.main.async { self?.showLog() }; return true }))
        app.addPauseMenuItem(PauseMenuItem(id: "assist.objectives", title: { Prefs.bool(AssistPrefs.objectives) ? "Hide Objectives" : "Show Objectives" },
                                           order: 205, action: { Prefs.set(AssistPrefs.objectives, !Prefs.bool(AssistPrefs.objectives)); return false }))
        app.addPauseMenuItem(PauseMenuItem(id: "assist.practice", title: { "Practice…" }, order: 290,
                                           action: { [weak self] in DispatchQueue.main.async { self?.practice.showChooser() }; return true }))
        app.addPauseMenuItem(PauseMenuItem(id: "assist.practice.restart", title: { [weak self] in
                                               "Restart Drill" + (self?.practice.drill.map { " (\($0.title))" } ?? "") },
                                           order: 291, isEnabled: { [weak self] in self?.practice.drill != nil },
                                           action: { [weak self] in self?.practice.restart(); return true }))
        app.addPauseMenuItem(PauseMenuItem(id: "assist.replay.stop", title: { "Stop Replay (take over)" }, order: 292,
                                           isEnabled: { [weak self] in self?.replays.isPlaying ?? false },
                                           action: { [weak self] in self?.replays.stopPlayback(); return true }))
        replays.install(app)
        practice.install(app)
        speech.install()
        AssistDebug.startIfRequested()
    }

    // MARK: host wiring

    private func attach(_ h: GameHost) {
        guard probeOwner !== h else { return }
        probeOwner = h
        let p = h.probe
        p.addObserver { [weak self] r in self?.event(r) }
        recorder.onMedal = { [weak self] m in self?.medalEarned(m) }
        recorder.onChange = { [weak self] in self?.recordDirty = true }
        timer.onFinish = { [weak self] won in self?.runFinished(won: won) }
        didReset(h)
    }

    private func didReset(_ h: GameHost) {
        messageLog.clear()
        objectives.reset()
        timer.reset()
        recorder.abandonRun()
        briefingPanel.hostDidReset()
        replays.hostDidReset(h)
        practice.hostDidReset(h)
    }

    // MARK: per frame (emulated)

    private func frame(_ ctx: FrameContext) {
        let c = ctx.game
        lastContext = c
        objectives.update(c)
        timer.frame(c)
        if recording { recorder.frame(c) }
        replays.frame(ctx)
        practice.frame(ctx)
    }

    // MARK: events (probe, host thread)

    private func event(_ r: GameEventRecord) {
        let e = r.event
        switch e {
        case .message(let m):
            // the log model also folds the continuous re-queues for speech; the panel honours logEnabled
            if let entry = messageLog.add(m, frame: r.frame) {
                logPanel.refresh()
                speech.message(entry.text, dropped: entry.dropped)
            }
        case .textScreen(let t):
            speech.screen(t)
        case .newGame:
            messageLog.clear(); logPanel.refresh()
            objectives.reset()
            comparison = records
        default: break
        }
        if case .gameOver(let score, _) = e { replays.gameEnded(score: Platoon.bcdValue(score)) }
        timer.event(e)
        if recording { recorder.event(e) }
        practice.event(r)
        briefingPanel.event(e)
    }

    /// The service record counts real games only (not practice drills or replays).
    private var recording: Bool { Prefs.bool(AssistPrefs.serviceRecord) && practice.drill == nil && !replays.isReplayGame }

    // MARK: display

    private var recordDirty = false
    private var lastSave: CFTimeInterval = 0

    private func display(_ ctx: FrameContext) {
        let c = ctx.game
        captionPanel.refresh(c, memory: ctx.memory)
        objectivesPanel.refresh(c)
        hudPanel.refresh(c)
        briefingPanel.refresh(c, memory: ctx.memory)
        timerPanel.refresh(timer, records: comparison)
        practiceBadge.refresh(practice)
        difficultyBadge.refresh(c)
        replays.display(ctx)
        let now = CACurrentMediaTime()
        if recordDirty && now - lastSave > 5 { lastSave = now; recordDirty = false; saveRecords() }
    }

    // MARK: M16 persistence

    static var supportDir: URL {
        if let d = ProcessInfo.processInfo.environment["PLATOON_SUPPORT_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return sup.appendingPathComponent("Platoon", isDirectory: true)
    }
    private var recordURL: URL { AssistCenter.supportDir.appendingPathComponent("service-record.json") }
    private var splitsURL: URL { AssistCenter.supportDir.appendingPathComponent("speedrun.json") }

    private func loadRecords() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: recordURL), let r = try? dec.decode(ServiceRecord.self, from: d) { recorder.record = r }
        if let d = try? Data(contentsOf: splitsURL), let r = try? dec.decode(SpeedrunRecords.self, from: d) { records = r; comparison = r }
    }
    func saveRecords() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: AssistCenter.supportDir, withIntermediateDirectories: true)
        if let d = try? enc.encode(recorder.record) { try? d.write(to: recordURL, options: .atomic) }
        if let d = try? enc.encode(records) { try? d.write(to: splitsURL, options: .atomic) }
    }
    func resetServiceRecord() { recorder.record = ServiceRecord(); saveRecords() }
    func resetSpeedrunRecords() { records = SpeedrunRecords(); comparison = records; saveRecords() }

    private func runFinished(won: Bool) {
        // practice drills and replays are not runs
        guard practice.drill == nil, !replays.isReplayGame else { return }
        let pb = records.record(category: timer.category, frames: timer.frames, splits: timer.splits, won: won)
        if pb && Prefs.bool(AssistPrefs.timer) { AppServices.shared.toast("New personal best: \(RunSplits.clock(timer.frames))", seconds: 4) }
        saveRecords()
    }

    private func medalEarned(_ m: Medal) {
        recordDirty = true
        if Prefs.bool(AssistPrefs.medalToasts) { AppServices.shared.toast("Medal: \(m.title)", seconds: 3) }
    }

    // MARK: UI entry points

    func showLog() { logPanel.open() }
    func showServiceRecord() { ServiceRecordWindowController.shared.show() }
}
