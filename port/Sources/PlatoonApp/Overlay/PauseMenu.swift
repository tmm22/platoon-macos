import AppKit
import SwiftUI
import PlatoonCore

// M1 pause menu: a modal overlay panel (F3). Opening it pauses the emulation (reason .menu); every entry works
// with keyboard (↑↓ Return Esc), controller (d-pad, A, B, Menu) and mouse. Host-only: nothing is written to the
// game except the Abort-to-title DEL tap, which is the original key.

enum SectionNames {
    static func title(_ s: Int) -> String {
        ["The Jungle & Village", "The Tunnels & Flare", "The Jungle & Foxhole"][max(0, min(2, s))]
    }
}

final class PauseMenuModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        var title: String
        var detail: String? = nil
        var enabled = true
        var destructive = false
        var action: () -> Void
    }
    enum Page: Equatable { case main, save, load, confirm(String) }

    @Published var page: Page = .main
    @Published var selection = 0
    @Published var rows: [Row] = []
    @Published var header = "PAUSED"
    @Published var subheader = ""
    @Published var message: String? = nil
    var confirmAction: (() -> Void)?
    var confirmTitle = ""
}

struct PauseMenuView: View {
    @ObservedObject var model: PauseMenuModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.header).font(.system(size: 22, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                if !model.subheader.isEmpty {
                    Text(model.subheader).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color(white: 0.7))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 8) {
                        Text(i == model.selection ? "▶" : " ").font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.45))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.title).font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(!r.enabled ? Color(white: 0.4) : r.destructive ? Color(red: 1, green: 0.55, blue: 0.5) : .white)
                            if let d = r.detail {
                                Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(i == model.selection ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = i; if r.enabled { r.action() } }
                }
            }
            if let m = model.message {
                Text(m).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("↑↓ select · Return / Ⓐ choose · Esc / Ⓑ back")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.55))
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(Color(white: 0.04, opacity: 0.9), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18)))
    }
}

final class PauseMenuPanel: OverlayPanel {
    let model = PauseMenuModel()
    private let hosting: NSHostingView<PauseMenuView>
    weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        hosting = NSHostingView(rootView: PauseMenuView(model: model))
        super.init(id: "app.pauseMenu", view: hosting, anchor: .game(.center, inset: 0), zIndex: 1000)
        isModal = true; isInteractive = true
        hosting.isHidden = true
    }

    private var services: AppServices { AppServices.shared }
    private var host: GameHost? { services.host }

    // MARK: open / close
    func open() {
        guard let h = host, !isVisible else { return }
        model.page = .main; model.message = nil
        rebuild()
        model.selection = 0
        isVisible = true
        h.pause(.menu)
    }
    /// Closes the menu and resumes (unless another pause reason is still set).
    func close() {
        guard isVisible else { return }
        isVisible = false
        host?.resume(.menu)
        // opening a menu counts as coming back to the game: clear the auto-pause reasons as well
        for r in [PauseReason.focus, .sleep, .controller] { host?.resume(r) }
    }

    // MARK: pages
    func rebuild() {
        guard let h = host else { return }
        var sub: [String] = []
        if let s = h.currentSection { sub.append(SectionNames.title(s)) } else { sub.append("Title / intermission") }
        if h.isAssisted { sub.append("ASSISTED") }
        model.subheader = sub.joined(separator: " · ")
        switch model.page {
        case .main: model.header = "PAUSED"; model.rows = mainRows(h)
        case .save: model.header = "SAVE"; model.rows = slotRows(save: true)
        case .load: model.header = "LOAD"; model.rows = slotRows(save: false)
        case .confirm(let q):
            model.header = q
            model.rows = [
                .init(id: "no", title: "No, go back") { [weak self] in self?.go(.main) },
                .init(id: "yes", title: model.confirmTitle, destructive: true) { [weak self] in
                    let a = self?.model.confirmAction; self?.model.confirmAction = nil; a?()
                },
            ]
        }
        model.selection = min(model.selection, max(0, model.rows.count - 1))
        manager?.setNeedsLayout()
    }

    private func go(_ p: PauseMenuModel.Page) { model.page = p; model.selection = 0; model.message = nil; rebuild() }
    private func confirm(_ q: String, _ yes: String, _ a: @escaping () -> Void) {
        model.confirmTitle = yes; model.confirmAction = a; go(.confirm(q))
    }

    private func mainRows(_ h: GameHost) -> [PauseMenuModel.Row] {
        typealias Row = PauseMenuModel.Row
        var rows: [(Int, Row)] = []
        rows.append((0, Row(id: "resume", title: "Resume") { [weak self] in self?.close() }))
        if let snap = services.snapshots {
            let why = snap.saveUnavailableReason
            rows.append((100, Row(id: "save", title: "Save Game…", detail: why, enabled: true) { [weak self] in self?.go(.save) }))
            rows.append((110, Row(id: "load", title: "Load Game…") { [weak self] in self?.go(.load) }))
        }
        for item in services.pauseMenuItems where item.isShown() {
            rows.append((item.order, Row(id: "x." + item.id, title: item.title(), enabled: item.isEnabled()) { [weak self] in
                if item.action() { self?.close() } else { self?.rebuild() }
            }))
        }
        if let s = h.currentSection {
            let arrived = h.sectionStartCarry != nil ? "with the platoon you arrived with" : "with a fresh platoon (loaded game)"
            let (title, detail): (String, String) = s == 0
                ? ("New Game", "Starts again from the jungle")
                : ("Restart \(SectionNames.title(s))", s == 1 ? "From the tunnels, \(arrived)" : arrived.prefix(1).uppercased() + arrived.dropFirst())
            rows.append((300, Row(id: "restart", title: title + "…", detail: detail) { [weak self] in
                self?.confirm(title + "?", "Yes, restart") { [weak self] in self?.restart(section: s) }
            }))
        }
        rows.append((400, Row(id: "options", title: "Options…") { [weak self] in self?.services.openPreferences() }))
        rows.append((410, Row(id: "controls", title: "Controls & Bindings…") { [weak self] in
            self?.close(); DispatchQueue.main.async { ControlsWindowController.shared.show() }
        }))
        if h.currentSection != nil {
            rows.append((900, Row(id: "abort", title: "Abort to Title…", destructive: true) { [weak self] in
                self?.confirm("ABORT GAME?", "Yes, abort to the title") { [weak self] in
                    self?.close(); self?.host?.tapKey(0x46)       // the original DEL warm restart
                }
            }))
        }
        rows.append((1000, Row(id: "quit", title: "Quit Platoon…", destructive: true) { [weak self] in
            self?.confirm("QUIT PLATOON?", "Yes, quit") { NSApp.terminate(nil) }
        }))
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func slotRows(save: Bool) -> [PauseMenuModel.Row] {
        guard let snap = services.snapshots else { return [] }
        var rows: [PauseMenuModel.Row] = []
        for i in 0..<snap.slotCount {
            let summary = snap.slotSummary(i)
            rows.append(.init(id: "slot\(i)", title: "Slot \(i + 1)", detail: summary ?? "— empty —", enabled: save || summary != nil) { [weak self] in
                guard let self else { return }
                var finished = false
                let done: (String?) -> Void = { [weak self] err in
                    finished = true
                    guard let self, self.isVisible || err == nil else { return }
                    if let e = err { self.model.message = e; self.rebuild() } else {
                        self.services.toast(save ? "Saved to slot \(i + 1)" : "Loaded slot \(i + 1)")
                        if save { if self.isVisible { self.go(.main) } } else { self.close() }
                    }
                }
                // Outside play (man select, text screens, loading) the save is only taken when play continues:
                // go back to the main page and say so, instead of leaving the player on the SAVE page.
                let saveNow = { [weak self] in
                    snap.save(slot: i, done: done)
                    guard let self, !finished else { return }
                    self.go(.main)
                    self.model.message = "Slot \(i + 1) will be saved as soon as play continues."
                }
                if save {
                    if summary != nil { self.confirm("OVERWRITE SLOT \(i + 1)?", "Yes, overwrite") { saveNow() } }
                    else { saveNow() }
                } else { snap.load(slot: i, done: done) }
            })
        }
        rows.append(.init(id: "back", title: "Back") { [weak self] in self?.go(.main) })
        return rows
    }

    private func restart(section s: Int) {
        guard let h = host else { return }
        let carry = s == 0 ? nil : h.sectionStartCarry
        isVisible = false
        h.resumeAll()
        h.reset(startSection: s, carry: carry)
    }

    /// Tests: select the row with this id ("restart", "abort", "yes", "slot0", "x.<feature id>") and choose it.
    @discardableResult func debugChoose(_ id: String) -> Bool {
        guard let i = model.rows.firstIndex(where: { $0.id == id }) else { return false }
        model.selection = i; choose(); return true
    }
    var debugRowIDs: [String] { model.rows.map { $0.id + ($0.enabled ? "" : "(off)") } }

    // MARK: input
    private func move(_ d: Int) {
        guard !model.rows.isEmpty else { return }
        var i = model.selection
        for _ in 0..<model.rows.count {
            i = (i + d + model.rows.count) % model.rows.count
            if model.rows[i].enabled { break }
        }
        model.selection = i
    }
    private func choose() {
        guard model.rows.indices.contains(model.selection) else { return }
        let r = model.rows[model.selection]
        if r.enabled { r.action() }
    }
    private func back() { if model.page == .main { close() } else { go(.main) } }

    override func handleKey(_ code: UInt16, down: Bool, event: NSEvent?) -> Bool {
        guard down else { return true }
        switch code {
        case 0x7e: move(-1)                       // up
        case 0x7d: move(1)                        // down
        case 0x24, 0x4c, 0x31: choose()           // return, enter, space
        case 0x35, 0x33: back()                   // esc, backspace
        default: break
        }
        return true
    }
    override func handlePad(_ b: PadButton, down: Bool) -> Bool {
        guard down else { return true }
        switch b {
        case .up: move(-1)
        case .down: move(1)
        case .a: choose()
        case .b: back()
        case .menu: close()
        default: break
        }
        return true
    }
}

/// Small "PAUSED" badge shown while the host pause is active without the pause menu (⌘P, auto-pause).
final class PauseBadgePanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")
    init() {
        let box = OverlayStyle.box()
        super.init(id: "app.pauseBadge", view: box, anchor: .game(.topRight, inset: 10), zIndex: 400)
        label.font = OverlayStyle.font(13, .bold); label.textColor = OverlayStyle.text
        box.addSubview(label)
        box.isHidden = true
    }
    override func frame(in l: OverlayLayout) -> CGRect {
        let s = label.fittingSize
        preferredSize = CGSize(width: s.width + 20, height: s.height + 10)
        label.frame = CGRect(x: 10, y: 5, width: s.width, height: s.height)
        return super.frame(in: l)
    }
    override func update(_ ctx: FrameContext?) {}
    func refresh(host: GameHost?, menuOpen: Bool) {
        guard let h = host, Prefs.bool(BuiltinPrefs.showPauseBadge) else { isVisible = false; return }
        let text: String?
        if h.paused && !menuOpen {
            let r = h.pauseReasons
            text = r.contains(.controller) ? "PAUSED — controller disconnected"
                : r.contains(.sleep) ? "PAUSED — sleep"
                : r.contains(.focus) ? "PAUSED — window inactive"
                : r.contains(.dialog) ? "PAUSED" : "PAUSED  (⌘P)"
        } else if h.isFastForwarding {
            text = "▶▶ \(h.fastForwardSpeed)×"
        } else { text = nil }
        if let t = text {
            if label.stringValue != t { label.stringValue = t; manager?.setNeedsLayout() }
            isVisible = true
        } else { isVisible = false }
    }
}
