import AppKit
import PlatoonCore

// Savestates in the app (roadmap L1 quick save/load, M8 checkpoints, M9 rewind). Owner: snapshot agent.
//
// The core (PlatoonCore/Game/Snapshot) takes snapshots on the game thread at the section main-loop heads; this file
// is the host side: save slots on disk (Application Support/Platoon/saves/*.pltsnap: thumbnail, section, score,
// build and disk tags), the SnapshotService the pause menu uses, "Retry from checkpoint", and the rewind scrubber.
// Everything runs on the main thread (menus, AppServices observers); the game thread is parked whenever this code
// touches the machine.
//
// Loading, retrying and rewinding change what happened in the game, so they mark the run assisted (F4/S5). Taking
// snapshots (slots, the checkpoint ring, the rewind ring) only reads the game state.

final class SaveStates: SnapshotService {
    static let shared = SaveStates()
    let controller = SnapshotController()
    private init() {}

    // MARK: preferences (declared in Prefs/PrefsSaveStates.swift)
    static let kCheckpoints = "snapshot.checkpoints"
    static let kRewind = "snapshot.rewind"
    static let kRewindSeconds = "snapshot.rewindSeconds"
    static let kDeathPrompt = "snapshot.deathPrompt"

    // MARK: slots
    static let slots = 5
    var slotCount: Int { SaveStates.slots }
    /// Slot -1 is the quick-save slot.
    static let quickSlot = -1

    static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["PLATOON_SAVES_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }   // tests
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return sup.appendingPathComponent("Platoon/saves", isDirectory: true)
    }
    func url(_ slot: Int) -> URL {
        SaveStates.directory.appendingPathComponent(slot == SaveStates.quickSlot ? "quick.pltsnap" : "slot\(slot + 1).pltsnap")
    }
    private var infoCache: [Int: SnapshotInfo?] = [:]
    func info(_ slot: Int) -> SnapshotInfo? {
        if let c = infoCache[slot] { return c }
        let i = (try? Data(contentsOf: url(slot), options: .alwaysMapped)).flatMap { try? GameSnapshot.readInfo($0) }
        infoCache[slot] = i
        return i
    }
    func slotName(_ slot: Int) -> String { slot == SaveStates.quickSlot ? "Quick save" : "Slot \(slot + 1)" }

    // MARK: SnapshotService (pause menu)
    func slotSummary(_ slot: Int) -> String? {
        guard let i = info(slot) else { return nil }
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        return "\(i.loop.title) — \(f.string(from: i.created)) — \(i.score) pts"
    }
    func slotThumbnail(_ slot: Int) -> NSImage? { info(slot).flatMap { NSImage(data: $0.thumbnailPNG) } }
    var saveUnavailableReason: String? {
        guard let h = host else { return "No game is running." }
        return inPlay(h) ? nil : "Saving works during play (jungle, tunnels, flare, final jungle) - it will be taken when play continues."
    }

    // MARK: install (Menus/MenuSaveStates.swift calls this once at launch)
    private var installed = false
    private var host: GameHost? { AppServices.shared.host }
    /// A GameHost reset caused by our own restore (don't forget the checkpoint/rewind rings then).
    private var restoring = false

    func install(_ app: AppServices) {
        guard !installed else { return }
        installed = true
        app.snapshots = self
        app.onHostReady { [weak self] h in self?.attach(h) }
        app.onReset { [weak self] h in
            guard let self else { return }
            self.attach(h)
            if !self.restoring { self.controller.resetRun() }
        }
        app.onDisplay { [weak self] ctx in self?.display(ctx) }
        app.addPauseMenuItem(PauseMenuItem(id: "snapshot.retry", title: { [unowned self] in self.retryTitle }, order: 150,
                                           isEnabled: { [unowned self] in self.canRetry }, action: { [unowned self] in self.retryCheckpoint(); return true }))
        app.addPauseMenuItem(PauseMenuItem(id: "snapshot.rewind", title: { "Rewind…" }, order: 160,
                                           isEnabled: { [unowned self] in self.canRewind },
                                           action: { [unowned self] in DispatchQueue.main.async { self.beginRewind() }; return true }))
        for k in [SaveStates.kCheckpoints, SaveStates.kRewind, SaveStates.kRewindSeconds] { Prefs.observe(k) { [weak self] in self?.applyOptions() } }
        controller.onEvent = { [weak self] e in self?.event(e) }
        // hold-to-rewind: Backspace (Amiga $41, never polled by the game) and the right stick click (R3)
        app.keyHooks.append { [weak self] code, down, isRepeat in
            guard let self, code == 0x33, !isRepeat else { return code == 0x33 && (self?.isRewinding ?? false) }
            return self.rewindKey(down: down, key: 0x33)
        }
        app.padHooks.append { [weak self] b, down in
            guard let self, b == .r3 else { return false }
            return self.rewindKey(down: down, key: 0xffff)
        }
        applyOptions()
        debug = SaveStatesDebug(path: ProcessInfo.processInfo.environment["PLATOON_DEBUG_SAVESTATES"])
    }

    private func attach(_ h: GameHost) {
        controller.attach(h.machine)
        controller.assisted = h.isAssisted
    }

    func applyOptions() {
        controller.checkpointsEnabled = Prefs.bool(SaveStates.kCheckpoints)
        controller.rewindEnabled = Prefs.bool(SaveStates.kRewind)
        controller.rewindIntervalFrames = 50
        controller.rewindCapacity = max(5, min(120, Prefs.int(SaveStates.kRewindSeconds)))
    }

    private func display(_ ctx: FrameContext) {
        if controller.assisted != ctx.host.isAssisted { controller.assisted = ctx.host.isAssisted }
        controller.drain()
        rewindPanel?.tick()
        debug?.step(self, ctx.host)
    }

    private func event(_ e: SnapshotController.Event) {
        switch e {
        case .checkpoint(let label): if Prefs.bool(SaveStates.kCheckpoints) { AppServices.shared.toast("Checkpoint: \(label)", seconds: 1.5) }
        case .death:
            if Prefs.bool(SaveStates.kDeathPrompt) && controller.latestCheckpoint != nil {
                AppServices.shared.toast("Retry from checkpoint: ⇧⌘R", seconds: 3)
            }
        case .sectionStart: break
        }
    }

    /// The game is in one of the main loops (a snapshot can be taken within a frame or two).
    func inPlay(_ h: GameHost) -> Bool {
        controller.lastLoop != nil && h.machine.frameCount &- controller.lastLoopFrame < 8
    }

    // MARK: save / load

    func save(slot: Int, done: @escaping (String?) -> Void) {
        guard let h = host else { done("No game is running."); return }
        let url = url(slot), name = slotName(slot)
        controller.requestSnapshot(label: name) { [weak self] snap in
            do {
                try snap.write(to: url)
                self?.infoCache[slot] = snap.info
                AppServices.shared.toast("Saved: \(name) (\(snap.info.loop.title))")
                done(nil)
            } catch {
                done("Could not save: \(error.localizedDescription)")
            }
        }
        if h.paused { captureWhilePaused(h) }
        if controller.hasPendingRequest && !inPlay(h) {
            AppServices.shared.toast("Saving at the next opportunity…", seconds: 2.5)
        }
    }

    /// While paused (pause menu), steps the emulation silently up to the next loop head (at most a few frames,
    /// only when the game is in a main loop) so the save completes now.
    private func captureWhilePaused(_ h: GameHost) {
        guard inPlay(h) else { return }
        let out = h.machine.chip.paula.output
        h.machine.chip.paula.output = nil
        var n = 0
        while controller.hasPendingRequest && n < 6 { h.stepFrame(); n += 1 }
        h.machine.chip.paula.output = out
        controller.drain()
    }

    func load(slot: Int, done: @escaping (String?) -> Void) {
        guard let h = host else { done("No game is running."); return }
        let snap: GameSnapshot
        do { snap = try GameSnapshot.read(from: url(slot)) } catch {
            done((error as? GameSnapshot.Failure)?.description ?? "Could not read \(slotName(slot)): \(error.localizedDescription)")
            return
        }
        do {
            if let warn = try snap.compatibility(with: h.disk) { AppServices.shared.toast(warn, seconds: 3) }
        } catch { done((error as? GameSnapshot.Failure)?.description ?? "\(error)"); return }
        restore(snap, in: h, reason: "Loaded a saved game")
        controller.adoptLoaded(snap)
        AppServices.shared.toast("Loaded: \(slotName(slot)) (\(snap.info.loop.title))")
        done(nil)
    }

    func quickSave() { save(slot: SaveStates.quickSlot) { e in if let e { AppServices.shared.toast(e, seconds: 3) } } }
    func quickLoad() { load(slot: SaveStates.quickSlot) { e in if let e { AppServices.shared.toast(e, seconds: 3) } } }
    func deleteSlot(_ slot: Int) { try? FileManager.default.removeItem(at: url(slot)); infoCache[slot] = nil }

    // MARK: checkpoints (M8)

    var canRetry: Bool { host != nil && controller.latestCheckpoint != nil }
    var retryTitle: String { controller.latestCheckpoint.map { "Retry from Checkpoint (\($0.info.label))" } ?? "Retry from Checkpoint" }

    func retryCheckpoint() {
        guard let h = host, let snap = controller.latestCheckpoint else { AppServices.shared.toast("No checkpoint yet"); return }
        restore(snap, in: h, reason: "Retry from checkpoint")
        controller.truncate(after: snap)
        AppServices.shared.toast("Checkpoint: \(snap.info.label)")
    }

    // MARK: restore

    /// Replaces the running game with `snap` (the machine continues exactly at the snapshot's loop head).
    func restore(_ snap: GameSnapshot, in h: GameHost, reason: String) {
        restoring = true; defer { restoring = false }
        let earlier = h.assistedReasons                  // the new run's config starts a new reason list
        // A fresh Machine (GameHost.restoreGame: wired, new config, marked assisted, onReset observers told).
        let carried = earlier + (snap.info.assisted ? ["Saved from an assisted game"] : [])
        h.restoreGame(section: snap.info.section, reason: reason) { m, cfg in
            PlatoonGame.resume(m, from: snap, config: cfg, assisted: reason, alsoAssisted: carried)
        }
        for r in earlier { h.markAssisted(r) }
        if snap.info.assisted { h.markAssisted("Saved from an assisted game") }
        controller.attach(h.machine)
        controller.assisted = true
        let m = h.machine
        // Keys held when the snapshot was taken would stay "down" in the game's key matrix ($2498): release them
        // through the normal keyboard path (the player's current keys are sent again by the input manager).
        m.input.clearQueuedKeys()
        for byte in 0..<16 {
            let v = m.memory.r8(0x2498 + UInt32(byte))
            for bit in 0..<8 where v & (1 << bit) != 0 { m.input.key(UInt8(byte * 8 + bit), down: false) }
        }
    }

    // MARK: rewind (M9)

    var canRewind: Bool { host != nil && controller.rewindEnabled && !controller.rewindRing.isEmpty }
    private var rewindPanel: RewindPanel?
    var isRewinding: Bool { rewindPanel?.isVisible == true }

    /// Opens the rewind scrubber (pauses the game) at the most recent rewind snapshot.
    func beginRewind(holdKey: UInt16? = nil) {
        guard let h = host else { return }
        guard controller.rewindEnabled else { AppServices.shared.toast("Rewind is off (Preferences › General › Save states)", seconds: 3); return }
        let ring = controller.rewindRing
        guard !ring.isEmpty else { AppServices.shared.toast("Nothing to rewind yet"); return }
        if isRewinding { rewindPanel?.step(-1); return }
        let p = rewindPanel ?? RewindPanel(owner: self)
        if rewindPanel == nil { rewindPanel = p; AppServices.shared.overlay.add(p) }
        controller.suspended = true
        h.pause(.custom("rewind"))
        p.open(ring: ring, now: h.machine.frameCount, holdKey: holdKey)
    }

    /// Scrubber finished: restore the chosen snapshot (nil = cancelled, continue where we were).
    func endRewind(_ snap: GameSnapshot?) {
        controller.suspended = false
        guard let h = host else { return }
        if let s = snap {
            restore(s, in: h, reason: "Rewind")
            controller.truncate(after: s)
        }
        h.resume(.custom("rewind"))
    }

    /// Hotkey hook (hold-to-rewind key/button): true = consumed.
    /// `key`: Mac keycode of the held key, 0xffff = controller R3. Passes the key through (false) when no rewind is
    /// possible (off, empty ring, not in play - e.g. Backspace during keyboard name entry).
    func rewindKey(down: Bool, key: UInt16) -> Bool {
        if down {
            guard canRewind, let h = host, inPlay(h) else { return false }
            beginRewind(holdKey: key)
            return true
        }
        return isRewinding
    }

    fileprivate var debug: SaveStatesDebug?
}

// MARK: - rewind scrubber (overlay, never drawn into the game picture)

/// Full-size preview of a rewind snapshot over the game image, with the time offset and a position bar.
/// While the rewind key is held it keeps stepping back; release (or Return) resumes from the shown snapshot,
/// Esc cancels, ←/→ step by one second.
final class RewindPanel: OverlayPanel {
    private unowned let owner: SaveStates
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var ring: [GameSnapshot] = []
    private var index = 0
    private var now: UInt64 = 0
    private var holdKey: UInt16?
    private var held = false
    private var heldFrames = 0

    init(owner: SaveStates) {
        self.owner = owner
        let root = NSView()
        root.wantsLayer = true
        super.init(id: "snapshot.rewind", view: root, anchor: .fillGame, zIndex: 900)
        isModal = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let box = OverlayStyle.box()
        label.font = OverlayStyle.font(15, .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(imageView); root.addSubview(box); box.addSubview(label); box.addSubview(bar)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: root.topAnchor), imageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            box.centerXAnchor.constraint(equalTo: root.centerXAnchor), box.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), bar.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6), bar.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        isVisible = false
    }

    func open(ring r: [GameSnapshot], now n: UInt64, holdKey k: UInt16?) {
        ring = r; now = n; index = r.count - 1
        holdKey = k; held = k != nil; heldFrames = 0
        isVisible = true
        show()
    }

    func step(_ d: Int) {
        index = max(0, min(ring.count - 1, index + d))
        show()
    }

    /// Once per displayed frame: while the key is held, rewind at an accelerating pace (1 s steps every 12 display
    /// frames, then every 6, then every 3).
    func tick() {
        guard isVisible, held else { return }
        heldFrames += 1
        let every = heldFrames < 60 ? 12 : heldFrames < 180 ? 6 : 3
        if heldFrames % every == 0 { step(-1) }
    }

    private func show() {
        guard index >= 0 && index < ring.count else { return }
        let s = ring[index]
        imageView.image = RewindPanel.image(s.machine.chip.canvas, crop: manager?.layoutInfo.crop ?? (x: 34, y: 20, w: 640, h: 256))
        let secs = Double(now &- s.info.frame) / 50
        label.stringValue = String(format: "◀◀  REWIND  −%.0f s   (%@)", secs, s.info.loop.title)
        bar.doubleValue = ring.count > 1 ? Double(index) / Double(ring.count - 1) : 1
    }

    private func commit() { isVisible = false; owner.endRewind(index < ring.count ? ring[index] : nil); ring = [] }
    private func cancel() { isVisible = false; owner.endRewind(nil); ring = [] }

    override func handleKey(_ code: UInt16, down: Bool, event: NSEvent?) -> Bool {
        if let k = holdKey, code == k || (k == 0x06 && code == 0x06) {
            if !down { held = false; commit() }
            return true
        }
        switch (code, down) {
        case (0x7b, true): step(-1)                      // ←
        case (0x7c, true): step(1)                       // →
        case (0x24, true), (0x4c, true): commit()        // Return / Enter
        case (0x35, true): cancel()                      // Esc
        case (0x06, false): if holdKey == nil || holdKey == 0x06 { held = false; commit() }   // ⌘Z released
        default: break
        }
        return true
    }

    override func handlePad(_ b: PadButton, down: Bool) -> Bool {
        if b == .r3 && holdKey == 0xffff { if !down { held = false; commit() }; return true }
        switch (b, down) {
        case (.left, true), (.lb, true): step(-1)
        case (.right, true), (.rb, true): step(1)
        case (.a, true): commit()
        case (.b, true), (.menu, true): cancel()
        default: break
        }
        return true
    }

    /// The snapshot's display canvas (0xFFRRGGBB) cropped like the renderer, one lowres pixel per canvas pixel pair.
    static func image(_ canvas: [UInt32], crop: (x: Int, y: Int, w: Int, h: Int)) -> NSImage? {
        let w = crop.w / 2, h = crop.h
        guard w > 0, h > 0, crop.y + h <= Chipset.canvasHeight, crop.x + crop.w <= Chipset.canvasWidth else { return nil }
        var px = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = canvas[(crop.y + y) * Chipset.canvasWidth + crop.x + x * 2] } }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let prov = CGDataProvider(data: data),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

// MARK: - app-level test driver

/// PLATOON_DEBUG_SAVESTATES=file: "WHEN action [arg]" lines, run in order. WHEN = an emulated frame number (run when
/// the frame counter reaches it) or "+N" (N displayed frames after the previous command; works while paused).
/// Use with the app's PLATOON_DEBUG_SCRIPT for resets / quitting. Output: PLATOON_DEBUG_CAPTURE dir.
///   save SLOT | load SLOT | quicksave | quickload | retry | rewind (open scrubber) | rewindstep N | rewindcommit |
///   rewindcancel | shot NAME (canvas PNG, name gets _f<frame>) | overlay NAME (overlay layer PNG) | log TEXT
final class SaveStatesDebug {
    private enum When { case frame(UInt64), after(Int) }
    private var lines: [(When, [String])]
    private let dir: String
    private var log: FileHandle?
    private var sinceLast = 0

    init?(path: String?) {
        guard let p = path, let text = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        lines = text.split(separator: "\n").compactMap { l in
            let a = l.split(separator: " ").map(String.init)
            guard a.count >= 2, !a[0].hasPrefix("#") else { return nil }
            if a[0].hasPrefix("+"), let n = Int(a[0].dropFirst()) { return (.after(n), Array(a.dropFirst())) }
            guard let f = UInt64(a[0]) else { return nil }
            return (.frame(f), Array(a.dropFirst()))
        }
        dir = ProcessInfo.processInfo.environment["PLATOON_DEBUG_CAPTURE"] ?? "/tmp/platoon-debug"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/savestates.log", contents: nil)
        log = FileHandle(forWritingAtPath: dir + "/savestates.log")
    }

    private func write(_ s: String) { log?.write((s + "\n").data(using: .utf8)!); print("[savestates] " + s) }

    func step(_ s: SaveStates, _ h: GameHost) {
        sinceLast += 1
        while let (when, cmd) = lines.first {
            switch when {
            case .frame(let at): if h.machine.frameCount < at { return }
            case .after(let n): if sinceLast < n { return }
            }
            lines.removeFirst()
            sinceLast = 0
            run(cmd, s, h)
        }
    }

    private func run(_ cmd: [String], _ s: SaveStates, _ h: GameHost) {
        let arg = cmd.count > 1 ? cmd[1] : ""
        let c = s.controller
        let state = "f\(h.machine.frameCount) assisted=\(h.isAssisted) [\(h.assistedReasons.joined(separator: ","))] paused=\(h.paused) "
            + "rewinding=\(s.isRewinding) ring=\(c.rewindRing.count) checkpoints=\(c.checkpoints.map(\.info.label)) "
            + "sectionStart=\(c.sectionStart?.info.label ?? "-") lastLoop=\(c.lastLoop?.title ?? "-")@\(c.lastLoopFrame)"
        switch cmd[0] {
        case "save": s.save(slot: Int(arg) ?? 0) { [weak self] e in self?.write("save \(arg): \(e ?? "ok") f\(h.machine.frameCount)") }
        case "load": s.load(slot: Int(arg) ?? 0) { [weak self] e in self?.write("load \(arg): \(e ?? "ok") -> f\(h.machine.frameCount)") }
        case "quicksave": s.quickSave()
        case "quickload": s.quickLoad(); write("quickload -> f\(h.machine.frameCount)")
        case "retry": s.retryCheckpoint(); write("retry -> f\(h.machine.frameCount)")
        case "rewind": s.beginRewind(); write("rewind open: \(state)")
        case "rewindstep":
            let n = Int(arg) ?? -1
            for _ in 0..<abs(n) { _ = AppServices.shared.overlay.handleKey(n < 0 ? 0x7b : 0x7c, down: true, event: nil) }
        case "rewindcommit": _ = AppServices.shared.overlay.handleKey(0x24, down: true, event: nil); write("rewind commit -> f\(h.machine.frameCount)")
        case "rewindcancel": _ = AppServices.shared.overlay.handleKey(0x35, down: true, event: nil); write("rewind cancel -> f\(h.machine.frameCount)")
        case "shot": try? ImageIO.canvasPNG(h.machine.chip).write(to: URL(fileURLWithPath: "\(dir)/\(arg)_f\(h.machine.frameCount).png"))
        case "overlay":
            if let rep = AppServices.shared.overlay.snapshot() { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(arg).png")) }
        case "log": write("\(cmd.dropFirst().joined(separator: " ")): \(state)")
        default: write("unknown command \(cmd)")
        }
    }
}
