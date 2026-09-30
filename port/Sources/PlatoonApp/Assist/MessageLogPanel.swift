import AppKit
import SwiftUI
import PlatoonCore

// [assist] S8 message log: a modal overlay panel (pauses the game while open) listing every HUD message of the
// current game. Keyboard: ↑↓ / Page Up / Page Down scroll, C copies the log, Esc / Return / ⌥⌘L close.
// Controller: d-pad scrolls, B / Menu close.

final class MessageLogModel: ObservableObject {
    struct Row: Identifiable { let id: Int; let time: String; let text: String; let dropped: Bool; let count: Int }
    @Published var rows: [Row] = []
    @Published var selection = 0
    @Published var enabled = true
}

struct MessageLogView: View {
    @ObservedObject var model: MessageLogModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MESSAGE LOG").font(.system(size: 18, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                Spacer()
                Text("\(model.rows.count) messages").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.6))
            }
            if !model.enabled {
                Text("The message log is switched off (Preferences ▸ Assist).").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.7))
            } else if model.rows.isEmpty {
                Text("No messages in this game yet.").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(white: 0.7))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.rows) { r in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(r.time).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.55))
                                        .frame(width: 44, alignment: .trailing)
                                    Text(r.text).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(r.dropped ? Color(red: 1, green: 0.7, blue: 0.4) : .white)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if r.count > 1 {
                                        Text("×\(r.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.55))
                                    }
                                    if r.dropped {
                                        Text("not shown").font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 3).background(Color.orange.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                                            .help("The game's message queue was full: this message was never displayed.")
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 2).padding(.horizontal, 6)
                                .background(r.id == model.selection ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .id(r.id)
                            }
                        }
                    }
                    .frame(height: 300)
                    .onChange(of: model.selection) { _, s in withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(s, anchor: .center) } }
                    .onAppear { proxy.scrollTo(model.selection, anchor: .bottom) }
                }
            }
            Text("↑↓ scroll · C copy · Esc / Ⓑ close").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.55))
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .background(Color(white: 0.04, opacity: 0.93), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18)))
    }
}

final class MessageLogPanel: OverlayPanel {
    let model = MessageLogModel()
    private let hosting: NSHostingView<MessageLogView>
    private static let pauseReason = PauseReason.custom("assist.log")

    init() {
        hosting = NSHostingView(rootView: MessageLogView(model: model))
        super.init(id: "assist.messageLog", view: hosting, anchor: .game(.center, inset: 0), zIndex: 1010)
        isModal = true; isInteractive = true
        hosting.isHidden = true
    }

    /// Rebuilds the rows from the log (cheap: at most a few hundred entries).
    func refresh() {
        guard isVisible else { return }
        let log = AssistCenter.shared.messageLog
        let atEnd = model.selection >= model.rows.count - 1
        model.rows = log.entries.enumerated().map { i, e in
            MessageLogModel.Row(id: i, time: e.timeText, text: e.text, dropped: e.dropped, count: e.count)
        }
        if atEnd { model.selection = max(0, model.rows.count - 1) }
    }

    func open() {
        guard !isVisible else { return }
        model.enabled = Prefs.bool(AssistPrefs.logEnabled)
        isVisible = true
        model.selection = Int.max
        refresh()
        model.selection = max(0, model.rows.count - 1)
        preferredSize = hosting.fittingSize
        manager?.setNeedsLayout()
        AppServices.shared.pause(MessageLogPanel.pauseReason)
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        AppServices.shared.resume(MessageLogPanel.pauseReason)
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AssistCenter.shared.messageLog.exportText(), forType: .string)
        AppServices.shared.toast("Message log copied")
    }

    private func move(_ d: Int) {
        guard !model.rows.isEmpty else { return }
        model.selection = max(0, min(model.rows.count - 1, model.selection + d))
    }

    override func handleKey(_ code: UInt16, down: Bool, event: NSEvent?) -> Bool {
        guard down else { return true }
        switch code {
        case 0x7e: move(-1)
        case 0x7d: move(1)
        case 0x74: move(-10)                              // page up
        case 0x79: move(10)                               // page down
        case 0x73: move(-100000)                          // home
        case 0x77: move(100000)                           // end
        case 0x08: copyToPasteboard()                     // C
        case 0x35, 0x24, 0x4c, 0x33: close()              // esc, return, enter, backspace
        case 0x25 where event?.modifierFlags.contains(.command) == true: close()   // ⌥⌘L again
        default: break
        }
        return true
    }

    override func handlePad(_ b: PadButton, down: Bool) -> Bool {
        guard down else { return true }
        switch b {
        case .up: move(-1)
        case .down: move(1)
        case .left, .lb: move(-10)
        case .right, .rb: move(10)
        case .b, .a, .menu: close()
        default: break
        }
        return true
    }
}
