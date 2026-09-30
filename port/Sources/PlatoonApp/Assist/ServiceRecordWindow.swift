import AppKit
import SwiftUI
import PlatoonCore

// [assist] M16 "Service Record" sheet: career statistics, medals and speedrun personal bests.

struct ServiceRecordView: View {
    @ObservedObject var model = ServiceRecordModel.shared

    var body: some View {
        let r = model.record
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("SERVICE RECORD").font(.system(size: 20, weight: .heavy, design: .monospaced))
                GroupBox("Career") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        row("Games started", "\(r.gamesStarted)")
                        row("Games won", "\(r.gamesWon)")
                        row("Games lost", "\(r.gamesLost)")
                        row("Time in action", RunSplits.clock(r.framesPlayed, hundredths: false))
                        row("Enemies killed", "\(r.enemiesKilled)")
                        row("Wounds taken", "\(r.woundsTaken)")
                        row("Soldiers lost", "\(r.soldiersLost)")
                        row("Sections completed", r.sectionsCompleted.enumerated().map { "\(["Jungle", "Tunnels", "Final"][$0.offset]) \($0.element)" }.joined(separator: " · "))
                        row("Furthest section", r.furthestSection < 0 ? "—" : ["The Jungle & Village", "The Tunnels & Flare", "The Final Jungle"][min(2, r.furthestSection)])
                        ForEach(r.bestScore.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in row("Best score (\(k))", "\(v)") }
                        ForEach(r.fastestWin.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in row("Fastest win (\(k))", RunSplits.clock(v)) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Medals (\(r.medals.count)/\(Medals.all.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Medals.all, id: \.id) { m in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: r.medals[m.id] != nil ? "rosette" : "circle.dashed")
                                    .foregroundStyle(r.medals[m.id] != nil ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.title).fontWeight(.semibold).foregroundStyle(r.medals[m.id] != nil ? .primary : .secondary)
                                    Text(m.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let d = r.medals[m.id] { Text(d, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Speedrun personal bests") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.records.best.isEmpty { Text("No completed timed run yet.").foregroundStyle(.secondary) }
                        ForEach(model.records.best.sorted(by: { $0.key < $1.key }), id: \.key) { cat, run in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(cat): \(RunSplits.clock(run.frames))").fontWeight(.semibold)
                                Text(run.splits.map { "\($0.name) \(RunSplits.clock($0.frames, hundredths: false))" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("Copy Splits") {
                                let t = model.records.best.keys.sorted().map { model.records.text($0) }.joined(separator: "\n")
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
                            }.disabled(model.records.best.isEmpty)
                            Button("Reset Personal Bests…") { model.confirmReset(pbs: true) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack {
                    Spacer()
                    Button("Reset Service Record…") { model.confirmReset(pbs: false) }
                }
            }
            .padding(18)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 600)
    }

    @ViewBuilder private func row(_ a: String, _ b: String) -> some View {
        GridRow { Text(a).foregroundStyle(.secondary); Text(b).monospacedDigit() }
    }
}

final class ServiceRecordModel: ObservableObject {
    static let shared = ServiceRecordModel()
    @Published var record = ServiceRecord()
    @Published var records = SpeedrunRecords()
    func reload() {
        record = AssistCenter.shared.recorder.record
        records = AssistCenter.shared.records
    }
    func confirmReset(pbs: Bool) {
        let a = NSAlert()
        a.messageText = pbs ? "Reset all speedrun personal bests?" : "Reset the service record (statistics and medals)?"
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if pbs { AssistCenter.shared.resetSpeedrunRecords() } else { AssistCenter.shared.resetServiceRecord() }
        reload()
    }
}

final class ServiceRecordWindowController: NSWindowController {
    static let shared = ServiceRecordWindowController()
    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Service Record"
        w.contentView = NSHostingView(rootView: ServiceRecordView())
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() {
        AssistCenter.shared.saveRecords()
        ServiceRecordModel.shared.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    /// Tests: the window content as PNG.
    func snapshotPNG(to url: URL) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
