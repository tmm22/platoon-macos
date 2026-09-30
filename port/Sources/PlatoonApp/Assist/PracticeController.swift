import AppKit
import SwiftUI
import PlatoonCore

// [assist] M11 practice mode, app side. A drill starts from a snapshot prepared by PracticeDrills.prepare (an
// off-screen Machine replays a verified input script; cached for the session) and is restored through the save-state
// path (SaveStates.restore: fresh Machine, marked assisted "Practice: <drill>"). When the soldier dies (optional) or
// the game is over, the drill restarts; reaching the goal shows the time and keeps a best time per drill.

final class PracticeController {
    private(set) var drill: PracticeDrill?
    private var snapshot: GameSnapshot?
    private var cache: [String: GameSnapshot] = [:]
    private(set) var attempts = 0
    private var attemptStart: UInt64 = 0
    private var lastFrame: UInt64 = 0
    private var completedFrames: Int?
    private var restoring = false
    private var restartPending = false
    private(set) var preparing: String?
    private var preparingProgress = 0.0
    private var chooser: PracticeChooserPanel?

    static let bestKey = "assist.practice.best"
    var bestTimes: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: PracticeController.bestKey) as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: PracticeController.bestKey) }
    }

    func install(_ app: AppServices) {}

    // MARK: disk cache (Application Support/Platoon/practice/<drill>-<disk tag>.pltsnap, rebuilt for a new build)

    static var cacheDir: URL { AssistCenter.supportDir.appendingPathComponent("practice", isDirectory: true) }
    private static func cacheURL(_ d: PracticeDrill, disk: Disk) -> URL {
        cacheDir.appendingPathComponent(String(format: "%@-%016llx.pltsnap", d.id, GameSnapshot.adfTag(disk)))
    }
    static func loadCached(_ d: PracticeDrill, disk: Disk) -> GameSnapshot? {
        guard let s = try? GameSnapshot.read(from: cacheURL(d, disk: disk)), s.info.buildTag == GameSnapshot.buildTag else { return nil }
        return s
    }
    static func storeCached(_ s: GameSnapshot, _ d: PracticeDrill, disk: Disk) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? s.write(to: cacheURL(d, disk: disk))
    }

    // MARK: start / restart / stop

    func start(_ d: PracticeDrill) {
        guard let h = AppServices.shared.host, preparing == nil else { return }
        if let s = cache[d.id] ?? PracticeController.loadCached(d, disk: h.disk) { cache[d.id] = s; begin(d, s, h); return }
        preparing = d.title; preparingProgress = 0
        AppServices.shared.toast("Preparing drill: \(d.title)…", seconds: 2)
        let disk = h.disk
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Result { try PracticeDrills.prepare(d, disk: disk) { p in DispatchQueue.main.async { self?.preparingProgress = p } } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = nil
                switch r {
                case .success(let s):
                    self.cache[d.id] = s
                    PracticeController.storeCached(s, d, disk: disk)
                    if let h = AppServices.shared.host { self.begin(d, s, h) }
                case .failure(let e): AppServices.shared.toast("\(e)", seconds: 4)
                }
            }
        }
    }

    private func begin(_ d: PracticeDrill, _ s: GameSnapshot, _ h: GameHost) {
        if drill != d { attempts = 0 }
        drill = d; snapshot = s
        restore(h)
        AppServices.shared.toast("Practice: \(d.title) — \(d.goalText)", seconds: 3)
    }

    private func restore(_ h: GameHost) {
        guard let s = snapshot, let d = drill else { return }
        restoring = true; defer { restoring = false }
        h.resumeAll()
        SaveStates.shared.restore(s, in: h, reason: "Practice: \(d.title)")
        attempts += 1
        attemptStart = s.info.frame
        lastFrame = attemptStart
        completedFrames = nil
        restartPending = false
    }

    /// Restart the current drill (pause menu, ⌥⌘R).
    func restart() {
        guard drill != nil, let h = AppServices.shared.host else { return }
        DispatchQueue.main.async { [weak self] in self?.restore(h) }
    }

    func stop() {
        guard drill != nil else { return }
        drill = nil; snapshot = nil; completedFrames = nil
        AppServices.shared.toast("Practice ended")
    }

    func hostDidReset(_ h: GameHost) {
        if !restoring && drill != nil { drill = nil; snapshot = nil; completedFrames = nil }   // New Game / Load / Replay
    }

    // MARK: observing

    func frame(_ ctx: FrameContext) {
        guard let d = drill, completedFrames == nil else { return }
        lastFrame = ctx.frame
        if PracticeDrills.goalReached(d.goal, context: ctx.game, event: nil) { complete(d) }
    }

    func event(_ r: GameEventRecord) {
        guard let d = drill else { return }
        if completedFrames == nil, let lc = AssistCenter.shared.lastContext, PracticeDrills.goalReached(d.goal, context: lc, event: r.event) {
            complete(d); return
        }
        guard completedFrames == nil, !restartPending else { return }
        switch r.event {
        case .death where Prefs.bool(AssistPrefs.practiceRetry), .gameOver, .aborted:
            restartPending = true
            let h = AppServices.shared.host
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.drill == d, self.restartPending, let h else { return }
                self.restore(h)
            }
        default: break
        }
    }

    private func complete(_ d: PracticeDrill) {
        let t = Int(lastFrame &- attemptStart)
        completedFrames = t
        var b = bestTimes
        let best = b[d.id]
        if best == nil || t < best! { b[d.id] = t; bestTimes = b }
        AppServices.shared.toast("DRILL COMPLETE: \(d.title) in \(RunSplits.clock(t))"
                                 + (best.map { t < $0 ? " — new best (was \(RunSplits.clock($0)))" : " (best \(RunSplits.clock($0)))" } ?? ""),
                                 seconds: 5)
    }

    /// Badge text ("PRACTICE · The Bridge · attempt 3 · 0:12.40 · best 0:10.02"), nil when not practising.
    var badgeText: String? {
        if let p = preparing { return "PRACTICE · preparing \(p)… \(Int(min(1, preparingProgress) * 100))%" }
        guard let d = drill else { return nil }
        let t = completedFrames ?? Int(lastFrame &- attemptStart)
        var s = "PRACTICE · \(d.title) · attempt \(attempts) · \(RunSplits.clock(t))"
        if completedFrames != nil { s += " ✓" }
        if let b = bestTimes[d.id] { s += " · best \(RunSplits.clock(b))" }
        return s
    }

    // MARK: chooser

    func showChooser() {
        let p = chooser ?? PracticeChooserPanel(owner: self)
        chooser = p
        if p.manager == nil { AppServices.shared.overlay.add(p) }
        p.open()
    }
}

/// Modal overlay list of drills (keyboard, controller and mouse).
final class PracticeChooserModel: ObservableObject {
    struct Row: Identifiable { let id: String; let title: String; let detail: String }
    @Published var rows: [Row] = []
    @Published var selection = 0
}

struct PracticeChooserView: View {
    @ObservedObject var model: PracticeChooserModel
    var choose: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRACTICE").font(.system(size: 22, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
            Text("Practice games are marked as assisted (no high scores).")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.65))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 8) {
                        Text(i == model.selection ? "▶" : " ").font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(AssistLayout.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.title).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                            Text(r.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.6))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(i == model.selection ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = i; choose(i) }
                }
            }
            Text("↑↓ select · Return / Ⓐ start · Esc / Ⓑ back").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.55))
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
        .background(Color(white: 0.04, opacity: 0.92), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18)))
    }
}

final class PracticeChooserPanel: OverlayPanel {
    let model = PracticeChooserModel()
    private let hosting: NSHostingView<PracticeChooserView>
    private unowned let owner: PracticeController
    private static let pauseReason = PauseReason.custom("assist.practice")

    init(owner: PracticeController) {
        self.owner = owner
        let m = model
        var chooseRef: ((Int) -> Void)?
        hosting = NSHostingView(rootView: PracticeChooserView(model: m, choose: { chooseRef?($0) }))
        super.init(id: "assist.practiceChooser", view: hosting, anchor: .game(.center, inset: 0), zIndex: 1020)
        isModal = true; isInteractive = true
        hosting.isHidden = true
        chooseRef = { [weak self] i in self?.choose(i) }
    }

    func open() {
        let best = owner.bestTimes
        var rows = PracticeDrills.all.map { d in
            PracticeChooserModel.Row(id: d.id, title: d.title,
                                     detail: d.detail + " Goal: " + d.goalText + (best[d.id].map { " · best \(RunSplits.clock($0))" } ?? ""))
        }
        if owner.drill != nil { rows.append(.init(id: "stop", title: "Stop Practice", detail: "Keep playing from here (still assisted)")) }
        rows.append(.init(id: "back", title: "Back", detail: ""))
        model.rows = rows
        model.selection = min(model.selection, rows.count - 1)
        isVisible = true
        preferredSize = hosting.fittingSize
        manager?.setNeedsLayout()
        AppServices.shared.pause(PracticeChooserPanel.pauseReason)
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        AppServices.shared.resume(PracticeChooserPanel.pauseReason)
    }

    func choose(_ i: Int) {
        guard model.rows.indices.contains(i) else { return }
        let id = model.rows[i].id
        close()
        switch id {
        case "back": break
        case "stop": owner.stop()
        default: if let d = PracticeDrills.drill(id) { DispatchQueue.main.async { self.owner.start(d) } }
        }
    }

    /// Tests: choose the row with this id.
    func debugChoose(_ id: String) { if let i = model.rows.firstIndex(where: { $0.id == id }) { choose(i) } }

    private func move(_ d: Int) {
        guard !model.rows.isEmpty else { return }
        model.selection = (model.selection + d + model.rows.count) % model.rows.count
    }

    override func handleKey(_ code: UInt16, down: Bool, event: NSEvent?) -> Bool {
        guard down else { return true }
        switch code {
        case 0x7e: move(-1)
        case 0x7d: move(1)
        case 0x24, 0x4c, 0x31: choose(model.selection)
        case 0x35, 0x33: close()
        default: break
        }
        return true
    }
    override func handlePad(_ b: PadButton, down: Bool) -> Bool {
        guard down else { return true }
        switch b {
        case .up: move(-1)
        case .down: move(1)
        case .a: choose(model.selection)
        case .b, .menu: close()
        default: break
        }
        return true
    }
}
