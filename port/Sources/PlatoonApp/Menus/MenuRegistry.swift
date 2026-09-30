import AppKit

// Menu contributions: feature owners add items to the app's menus from their own Menus/Menu<Owner>.swift stub.
//
// Example (Menus/MenuAssist.swift):
//
//   extension MenuRegistry {
//       static func assistMenus(_ app: AppServices) -> [MenuContribution] { [
//           MenuContribution(menu: .assist, order: 10, items: [
//               ClosureMenuItem("Show Tunnel Map", key: "m", mods: [.command, .shift],
//                               state: { Prefs.bool("assist.tunnelMap") }) { Prefs.set("assist.tunnelMap", !Prefs.bool("assist.tunnelMap")) },
//           ]),
//       ] }
//   }

/// The top-level menus contributions can go into. `.assist` is created only if something is contributed.
enum MenuTarget: String, CaseIterable {
    case app, game, view, sound, assist, window, help
    var title: String {
        switch self {
        case .app: return "Platoon"; case .game: return "Game"; case .view: return "View"; case .sound: return "Sound"
        case .assist: return "Assist"; case .window: return "Window"; case .help: return "Help"
        }
    }
}

struct MenuContribution {
    var menu: MenuTarget
    /// Position within the menu relative to other contributions (built-in items come first; lower = earlier).
    var order = 100
    /// Adds a separator before the group.
    var separatorBefore = true
    var items: [NSMenuItem]
    init(menu: MenuTarget, order: Int = 100, separatorBefore: Bool = true, items: [NSMenuItem]) {
        self.menu = menu; self.order = order; self.separatorBefore = separatorBefore; self.items = items
    }
}

/// NSMenuItem that runs a closure, with closure-based checkmark state and enabling (validated before display).
final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let run: () -> Void
    private let stateFn: (() -> Bool)?
    private let enabledFn: (() -> Bool)?
    private let titleFn: (() -> String)?

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command,
         state: (() -> Bool)? = nil, enabled: (() -> Bool)? = nil, dynamicTitle: (() -> String)? = nil,
         _ action: @escaping () -> Void) {
        run = action; stateFn = state; enabledFn = enabled; titleFn = dynamicTitle
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
    }
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire(_ s: Any?) { run() }
    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        if let s = stateFn { state = s() ? .on : .off }
        if let t = titleFn { title = t() }
        return enabledFn?() ?? true
    }

    /// Submenu helper.
    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title); items.forEach(m.addItem); i.submenu = m
        return i
    }
}

enum MenuRegistry {
    static func all(_ app: AppServices) -> [MenuContribution] {
        (builtinMenus(app) + inputMenus(app) + audioMenus(app) + videoMenus(app) + gameplayCoreMenus(app)
            + gameplaySection0Menus(app) + gameplaySection1Menus(app) + gameplaySection2Menus(app)
            + assistMenus(app) + saveStateMenus(app) + prefMenus())
            .sorted { $0.order < $1.order }
    }

    /// Auto-generated checkmark items for prefs declared with `.inMenu(_:)`.
    static func prefMenus() -> [MenuContribution] {
        var byMenu: [PrefMenuTarget: [NSMenuItem]] = [:]
        for i in PrefsRegistry.allItems {
            guard let target = i.menu, case .toggle = i.kind else { continue }
            let key = i.key
            let item = ClosureMenuItem(titleCase(i.title), state: { Prefs.bool(key) },
                                       enabled: i.enabledIf) { Prefs.set(key, !Prefs.bool(key)) }
            item.toolTip = i.help
            byMenu[target, default: []].append(item)
        }
        // next to the related built-in groups: Game after the save-state items (20), Sound after the audio group
        // (50), the Assist overlay toggles right after the message log (10)
        return byMenu.map { t, items in
            switch t {
            case .game: return MenuContribution(menu: .game, order: 21, items: items)
            case .view: return MenuContribution(menu: .view, order: 500, items: items)
            case .sound: return MenuContribution(menu: .sound, order: 51, separatorBefore: false, items: items)
            case .assist: return MenuContribution(menu: .assist, order: 15, items: items)
            }
        }
    }

    /// macOS menu titles are in title case: "Show the tunnel map" -> "Show the Tunnel Map".
    static func titleCase(_ s: String) -> String {
        let small: Set<String> = ["a", "an", "the", "and", "or", "of", "in", "on", "to", "at", "for", "with", "by"]
        var out: [String] = []
        for (n, w) in s.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let word = String(w)
            if n > 0 && small.contains(word.lowercased()) && !(out.last?.hasSuffix(":") ?? false) { out.append(word.lowercased()); continue }
            out.append(word.prefix(1).uppercased() + word.dropFirst())
        }
        return out.joined(separator: " ")
    }

    /// Adds contributions to the app's menus (creating the Assist menu if needed, before Window).
    static func merge(_ contributions: [MenuContribution], into main: NSMenu, menus: [MenuTarget: NSMenu]) {
        var menus = menus
        for c in contributions where !c.items.isEmpty {
            let m: NSMenu
            if let e = menus[c.menu] { m = e } else {
                m = NSMenu(title: c.menu.title)
                let top = NSMenuItem(title: c.menu.title, action: nil, keyEquivalent: ""); top.submenu = m
                let windowIndex = menus[.window].flatMap { w in main.items.firstIndex { $0.submenu === w } } ?? main.items.count
                main.insertItem(top, at: c.menu == .help ? main.items.count : windowIndex)   // Help stays last
                menus[c.menu] = m
                if c.menu == .help { NSApp.helpMenu = m }
            }
            if c.separatorBefore && m.items.count > 0 && !(m.items.last?.isSeparatorItem ?? true) { m.addItem(.separator()) }
            c.items.forEach(m.addItem)
        }
    }
}

/// Launch hooks of the feature owners (see the Menus/Menu<Owner>.swift stubs).
enum FeatureHooks {
    static func installAll(_ app: AppServices) {
        builtinInstall(app)
        inputInstall(app); audioInstall(app); videoInstall(app); gameplayCoreInstall(app)
        gameplaySection0Install(app); gameplaySection1Install(app); gameplaySection2Install(app)
        assistInstall(app); saveStateInstall(app); cheatsInstall(app)
    }
}
