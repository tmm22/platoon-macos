import AppKit
import PlatoonCore

// snapshot: [snapshot] agent — quick save / checkpoints / rewind (L1, M8, M9).
// Only the owner edits this file.
//  - `saveStateMenus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `saveStateInstall`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func saveStateMenus(_ app: AppServices) -> [MenuContribution] {
        let s = SaveStates.shared
        let hasHost = { AppServices.shared.host != nil }
        let saveMenu = (0..<SaveStates.slots).map { i in
            SlotMenuItem(slot: i, loading: false) { s.save(slot: i) { e in if let e { AppServices.shared.toast(e, seconds: 3) } } }
        }
        let loadMenu = (0..<SaveStates.slots).map { i in
            SlotMenuItem(slot: i, loading: true) { s.load(slot: i) { e in if let e { AppServices.shared.toast(e, seconds: 3) } } }
        }
        let finder = ClosureMenuItem("Show Saved Games in Finder") {
            try? FileManager.default.createDirectory(at: SaveStates.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(SaveStates.directory)
        }
        return [
            MenuContribution(menu: .game, order: 20, items: [
                ClosureMenuItem("Quick Save", key: "s", mods: [.command, .shift], enabled: hasHost) { s.quickSave() },
                ClosureMenuItem("Quick Load", key: "l", mods: [.command, .shift], enabled: { hasHost() && s.info(SaveStates.quickSlot) != nil },
                                dynamicTitle: { s.info(SaveStates.quickSlot).map { "Quick Load (\($0.loop.title), \($0.score) pts)" } ?? "Quick Load" }) { s.quickLoad() },
                ClosureMenuItem.submenu("Save to Slot", saveMenu),
                ClosureMenuItem.submenu("Load from Slot", loadMenu + [.separator(), finder]),
                ClosureMenuItem("Retry from Checkpoint", key: "r", mods: [.command, .shift], enabled: { s.canRetry },
                                dynamicTitle: { s.retryTitle }) { s.retryCheckpoint() },
                ClosureMenuItem("Rewind (hold ⌘Z)", key: "z", mods: .command, enabled: { s.canRewind || s.isRewinding }) {
                    s.beginRewind(holdKey: 0x06)
                },
            ]),
        ]
    }
}

/// A save/load slot entry with the slot's thumbnail and summary (refreshed whenever the menu opens).
final class SlotMenuItem: NSMenuItem, NSMenuItemValidation {
    private let slot: Int, loading: Bool, run: () -> Void
    init(slot: Int, loading: Bool, _ run: @escaping () -> Void) {
        self.slot = slot; self.loading = loading; self.run = run
        super.init(title: "Slot \(slot + 1)", action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not supported") }
    @objc private func fire(_ s: Any?) { run() }
    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        let s = SaveStates.shared
        let summary = s.slotSummary(slot)
        title = "Slot \(slot + 1): " + (summary ?? "empty")
        if let img = s.slotThumbnail(slot) { img.size = NSSize(width: 84, height: 72); image = img } else { image = nil }
        guard AppServices.shared.host != nil else { return false }
        return loading ? summary != nil : true
    }
}

extension FeatureHooks {
    static func saveStateInstall(_ app: AppServices) {
        SaveStates.shared.install(app)
    }
}
