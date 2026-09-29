import AppKit
import SwiftUI

// M18 Preferences window (⌘,), generated entirely from PrefsRegistry.

final class PrefsModel: ObservableObject {
    static let shared = PrefsModel()
    @Published var tab: PrefTab = .general
    @Published private(set) var revision = 0
    private init() { Prefs.observeAll { [weak self] _ in self?.revision += 1 } }
    func bump() { revision += 1 }

    func bool(_ k: String) -> Binding<Bool> { Binding(get: { Prefs.bool(k) }, set: { Prefs.set(k, $0) }) }
    func int(_ k: String) -> Binding<Int> { Binding(get: { Prefs.int(k) }, set: { Prefs.set(k, $0) }) }
    func double(_ k: String, step: Double) -> Binding<Double> {
        Binding(get: { Prefs.double(k) }, set: { v in Prefs.set(k, step > 0 ? (v / step).rounded() * step : v) })
    }
}

struct PreferencesView: View {
    @ObservedObject var model = PrefsModel.shared

    var body: some View {
        TabView(selection: $model.tab) {
            ForEach(PrefTab.allCases) { tab in
                PrefsTabView(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 520)
    }
}

struct PrefsTabView: View {
    let tab: PrefTab
    @ObservedObject var model = PrefsModel.shared

    var body: some View {
        let _ = model.revision
        let sections = PrefsRegistry.sections(for: tab)
        VStack(spacing: 0) {
            if sections.isEmpty {
                Spacer()
                Text("No \(tab.title.lowercased()) options yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                Form {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                        Section {
                            ForEach(s.items, id: \.key) { PrefRow(item: $0) }
                        } header: { Text(s.title) } footer: {
                            if let f = s.footer { Text(f).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            PrefsFooter(tab: tab)
        }
    }
}

struct PrefRow: View {
    let item: PrefItem
    @ObservedObject var model = PrefsModel.shared

    var body: some View {
        let enabled = item.enabledIf?() ?? true
        VStack(alignment: .leading, spacing: 2) {
            control
            if let h = item.help, !isNote { Text(h).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .disabled(!enabled)
        .help(item.help ?? "")
    }

    private var isNote: Bool { if case .note = item.kind { return true }; return false }

    @ViewBuilder private var label: some View {
        HStack(spacing: 6) {
            Text(item.title)
            if item.isGameplay {
                Text("GAMEPLAY").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                    .help("Changes the game. Runs that use it are marked as assisted and kept out of the original high-score table.")
            }
            if item.requiresRestart && !item.isGameplay {
                Text("ON RESET").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch item.kind {
        case .toggle:
            Toggle(isOn: model.bool(item.key)) { label }
        case .choice(_, let options):
            Picker(selection: model.int(item.key)) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            } label: { label }
        case .slider(_, let range, let step, let format):
            LabeledContent {
                HStack {
                    Slider(value: model.double(item.key, step: step), in: range)
                    Text(format(Prefs.double(item.key))).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                }
            } label: { label }
        case .action(let button, let run):
            LabeledContent { Button(button, action: run) } label: { label }
        case .note:
            Text(item.title).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PrefsFooter: View {
    let tab: PrefTab
    @ObservedObject var model = PrefsModel.shared

    var body: some View {
        let _ = model.revision
        let pending = AppServices.shared.host.map { PrefsRegistry.pendingRestartItems(since: $0.runPrefsSnapshot) } ?? []
        HStack {
            if !pending.isEmpty {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
                Text("\(pending.count == 1 ? "1 change applies" : "\(pending.count) changes apply") when a new game starts.")
                    .font(.callout)
                Button("Reset Game Now") { AppServices.shared.reset(); model.bump() }
            }
            Spacer()
            Button("Restore Defaults") { Prefs.resetToDefaults(tab: tab); model.bump() }
                .disabled(!PrefsRegistry.sections(for: tab).flatMap(\.items).contains { $0.isNonDefault })
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()
    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        w.title = "Platoon Preferences"
        w.contentViewController = NSHostingController(rootView: PreferencesView())
        w.setFrameAutosaveName("PlatoonPrefs")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: PrefTab?) {
        if let t = tab { PrefsModel.shared.tab = t }
        PrefsModel.shared.bump()
        if !(window?.isVisible ?? false) { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
