import Foundation
import PlatoonCore

// M18 Preferences: a DECLARATIVE registry. Feature owners describe their settings in their own stub file
// (Prefs/Prefs<Owner>.swift) as `[PrefSection]`; the Preferences window (⌘,), UserDefaults defaults, optional
// auto-generated menu toggles and the GameConfig plumbing are all derived from it. Nobody edits AppDelegate.
//
// Example (in Prefs/PrefsAssist.swift):
//
//   extension PrefsRegistry {
//       static var assistSections: [PrefSection] { [
//           PrefSection(tab: .assist, title: "Message log", items: [
//               .toggle("assist.messageLog", "Record HUD messages", default: false,
//                       help: "Keeps every HUD message in a scrollable log (pause menu)."),
//               .slider("assist.captionSize", "Caption size", default: 1.0, range: 0.5...3, step: 0.25,
//                       format: { "\(Int($0 * 100))%" }),
//           ]),
//       ] }
//   }
//
// Read values anywhere with `Prefs.bool("assist.messageLog")` / `Prefs.int` / `Prefs.double`, or observe changes
// with `Prefs.observe(key) { ... }`.
//
// Gameplay options: mark them `.gameplay()` (they then taint the run, F4/S5) and give them an `enhancement`
// key: the value is passed to the core's enhancement registry (PLATOON_ENH-style "key=value") when a game starts.
// Enhancements are copied at game start, so such options take effect after a reset; the window offers
// "Restart now". Use `applyToConfig` for anything the key=value form can't express.

enum PrefTab: String, CaseIterable, Identifiable {
    case general, input, video, audio, gameplay, assist
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"; case .input: return "Input"; case .video: return "Video"
        case .audio: return "Audio"; case .gameplay: return "Gameplay"; case .assist: return "Assist"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"; case .input: return "gamecontroller"; case .video: return "display"
        case .audio: return "speaker.wave.2"; case .gameplay: return "flag.2.crossed"; case .assist: return "lifepreserver"
        }
    }
}

/// Where an auto-generated menu toggle for a pref goes (optional).
enum PrefMenuTarget: String { case game, view, sound, assist }

struct PrefItem {
    enum Kind {
        case toggle(default: Bool)
        /// Integer choice from a fixed list (popup menu).
        case choice(default: Int, options: [(value: Int, title: String)])
        case slider(default: Double, range: ClosedRange<Double>, step: Double, format: (Double) -> String)
        /// A button (no stored value).
        case action(button: String, run: () -> Void)
        /// Static explanatory text.
        case note
    }
    /// UserDefaults key. Convention: "<owner>.<name>" (e.g. "assist.tunnelMap"). Existing keys of the original
    /// app ("filter", "aspect", ...) are kept for compatibility.
    var key: String
    var title: String
    var kind: Kind
    var help: String? = nil
    /// Gameplay-changing: taints runs that use it (F4/S5) and is shown with a badge.
    var isGameplay = false
    /// Only takes effect when a new game starts (enhancements are copied at game start).
    var requiresRestart = false
    /// Core enhancement registry key; the stored value is passed as "key=value" into GameConfig.enhancements.
    var enhancement: String? = nil
    /// Custom GameConfig plumbing, called by GameHost when it builds the config for a new run.
    var applyToConfig: ((inout GameConfig) -> Void)? = nil
    /// Called on the main thread after the user changed the value (live apply).
    var onChange: (() -> Void)? = nil
    /// Greyed out unless this returns true.
    var enabledIf: (() -> Bool)? = nil
    /// Also show as a checkmark item in this menu (toggles only).
    var menu: PrefMenuTarget? = nil
    /// Core enhancement keys this item handles itself (via applyToConfig): their automatic rows are hidden.
    var covers: [String] = []

    // convenience constructors
    static func toggle(_ key: String, _ title: String, default d: Bool, help: String? = nil) -> PrefItem {
        PrefItem(key: key, title: title, kind: .toggle(default: d), help: help)
    }
    static func choice(_ key: String, _ title: String, default d: Int, _ options: [(Int, String)], help: String? = nil) -> PrefItem {
        PrefItem(key: key, title: title, kind: .choice(default: d, options: options.map { (value: $0.0, title: $0.1) }), help: help)
    }
    static func slider(_ key: String, _ title: String, default d: Double, range: ClosedRange<Double>, step: Double,
                       format: @escaping (Double) -> String = { String(format: "%.2f", $0) }, help: String? = nil) -> PrefItem {
        PrefItem(key: key, title: title, kind: .slider(default: d, range: range, step: step, format: format), help: help)
    }
    static func action(_ key: String, _ title: String, button: String, help: String? = nil, _ run: @escaping () -> Void) -> PrefItem {
        PrefItem(key: key, title: title, kind: .action(button: button, run: run), help: help)
    }
    static func note(_ key: String, _ text: String) -> PrefItem { PrefItem(key: key, title: text, kind: .note) }

    // modifiers
    /// Gameplay-changing option: taints the run and applies on restart.
    func gameplay(enhancement: String? = nil) -> PrefItem {
        var c = self; c.isGameplay = true; c.requiresRestart = true; c.enhancement = enhancement ?? c.enhancement; return c
    }
    func restart() -> PrefItem { var c = self; c.requiresRestart = true; return c }
    func enhancement(_ k: String) -> PrefItem { var c = self; c.enhancement = k; c.requiresRestart = true; return c }
    func onChange(_ f: @escaping () -> Void) -> PrefItem { var c = self; c.onChange = f; return c }
    func config(_ f: @escaping (inout GameConfig) -> Void) -> PrefItem { var c = self; c.applyToConfig = f; return c }
    func enabled(if f: @escaping () -> Bool) -> PrefItem { var c = self; c.enabledIf = f; return c }
    func inMenu(_ m: PrefMenuTarget) -> PrefItem { var c = self; c.menu = m; return c }
    func covers(_ keys: String...) -> PrefItem { var c = self; c.covers += keys; c.requiresRestart = true; return c }

    var defaultValue: Any? {
        switch kind {
        case .toggle(let d): return d
        case .choice(let d, _): return d
        case .slider(let d, _, _, _): return d
        case .action, .note: return nil
        }
    }
    /// Is the stored value different from the default (used for "assisted" and the Reset buttons)?
    var isNonDefault: Bool {
        switch kind {
        case .toggle(let d): return Prefs.bool(key) != d
        case .choice(let d, _): return Prefs.int(key) != d
        case .slider(let d, _, _, _): return abs(Prefs.double(key) - d) > 1e-9
        case .action, .note: return false
        }
    }
    /// The value as the core enhancement registry expects it ("1"/"0", integers, decimals).
    var enhancementValue: String {
        switch kind {
        case .toggle: return Prefs.bool(key) ? "1" : "0"
        case .choice: return String(Prefs.int(key))
        case .slider: return String(Prefs.double(key))
        case .action, .note: return ""
        }
    }
}

struct PrefSection {
    var tab: PrefTab
    var title: String
    var footer: String? = nil
    /// Lower sorts first within the tab (built-in sections use 0-99; feature sections default to 100).
    var order = 100
    var items: [PrefItem]
    init(tab: PrefTab, title: String, footer: String? = nil, order: Int = 100, items: [PrefItem]) {
        self.tab = tab; self.title = title; self.footer = footer; self.order = order; self.items = items
    }
}

/// Aggregates every owner's sections. Owners extend it in their stub files (see the stubs' headers).
enum PrefsRegistry {
    /// Sections added at runtime (e.g. from an install hook) in addition to the static ones.
    static var dynamicSections: [PrefSection] = []

    /// Sections declared explicitly by the owners (stub files) and at runtime.
    static var explicitSections: [PrefSection] {
        builtinSections + inputSections + audioSections + videoSections
            + gameplayCoreSections + gameplaySection0Sections + gameplaySection1Sections + gameplaySection2Sections
            + assistSections + saveStateSections + dynamicSections
    }
    static var all: [PrefSection] {
        let s = explicitSections + autoEnhancementSections
        return s.sorted { ($0.tab.sortIndex, $0.order) < ($1.tab.sortIndex, $1.order) }
    }
    static func sections(for tab: PrefTab) -> [PrefSection] { all.filter { $0.tab == tab } }
    static var allItems: [PrefItem] { all.flatMap(\.items) }
    static func item(_ key: String) -> PrefItem? { allItems.first { $0.key == key } }

    /// Registers every item's default with UserDefaults (call once at launch). Duplicate keys are reported.
    static func registerDefaults() {
        var defaults: [String: Any] = [:], seen = Set<String>()
        for i in allItems {
            if case .note = i.kind { continue }
            if case .action = i.kind { continue }
            if !seen.insert(i.key).inserted { NSLog("Prefs: duplicate key \(i.key)") }
            if let d = i.defaultValue { defaults[i.key] = d }
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Applies every gameplay/enhancement pref to a new run's config. Returns the reasons why the run is
    /// assisted (non-default gameplay options), empty = original game.
    static func apply(to c: inout GameConfig) -> [String] {
        var assisted: [String] = [], kv: [String] = []
        for i in allItems {
            if let e = i.enhancement { kv.append("\(e)=\(i.enhancementValue)") }
            i.applyToConfig?(&c)
            if i.isGameplay && i.isNonDefault && i.enhancement == nil && !i.key.hasPrefix(autoKeyPrefix) { assisted.append(i.title) }
        }
        EnhancementBridge.apply(kv, to: &c)
        // (the core decides itself which enhancement values make a run assisted: Enhancements.assistReasons)
        return assisted
    }

    /// Reasons (titles) of the host-only gameplay prefs that apply LIVE (no restart: the trainer, game speed) and are
    /// not at their default now. They are marked per game (GameHost), not as reasons of the whole Machine run: a
    /// game started from the title after switching them off must be an ordinary game again.
    static func liveGameplayReasons() -> [String] {
        allItems.filter { $0.isGameplay && !$0.requiresRestart && $0.isNonDefault && $0.enhancement == nil && !$0.key.hasPrefix(autoKeyPrefix) }
            .map(\.title)
    }
    static func isLiveGameplayReason(_ title: String) -> Bool {
        allItems.contains { $0.isGameplay && !$0.requiresRestart && $0.enhancement == nil && !$0.key.hasPrefix(autoKeyPrefix) && $0.title == title }
    }

    /// Items whose value changed since the current run started and that only apply on restart.
    static func pendingRestartItems(since snapshot: [String: String]) -> [PrefItem] {
        allItems.filter { $0.requiresRestart && snapshot[$0.key] != nil && snapshot[$0.key] != $0.enhancementValue }
    }
    static func restartSnapshot() -> [String: String] {
        var d: [String: String] = [:]
        for i in allItems where i.requiresRestart { d[i.key] = i.enhancementValue }
        return d
    }

    /// Human-readable dump (Platoon --list-prefs).
    static func dump() -> String {
        var out = ""
        for t in PrefTab.allCases {
            let secs = sections(for: t)
            guard !secs.isEmpty else { continue }
            out += "[\(t.title)]\n"
            for s in secs {
                out += "  \(s.title)\n"
                for i in s.items {
                    var flags: [String] = []
                    if i.isGameplay { flags.append("gameplay") }
                    if i.requiresRestart { flags.append("restart") }
                    if let e = i.enhancement { flags.append("enh:\(e)") }
                    if let m = i.menu { flags.append("menu:\(m.rawValue)") }
                    let d = i.defaultValue.map { " default=\($0)" } ?? ""
                    out += "    \(i.key): \(i.title)\(d)\(flags.isEmpty ? "" : " [" + flags.joined(separator: ",") + "]")\n"
                }
            }
        }
        return out
    }
}

extension PrefTab { var sortIndex: Int { PrefTab.allCases.firstIndex(of: self) ?? 0 } }

/// Typed access to preference values (UserDefaults; defaults come from the registry).
enum Prefs {
    static var d: UserDefaults { .standard }
    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func int(_ k: String) -> Int { d.integer(forKey: k) }
    static func double(_ k: String) -> Double { d.double(forKey: k) }
    static func set(_ k: String, _ v: Any) {
        d.set(v, forKey: k)
        notifyChanged(k)
    }
    /// Runs the observers and the item's live-apply hook for `k` (after the value was stored some other way,
    /// e.g. by the debug script's `pref` command).
    static func notifyChanged(_ k: String) {
        observers[k]?.forEach { $0() }
        anyObservers.forEach { $0(k) }
        PrefsRegistry.item(k)?.onChange?()
    }
    private static var observers: [String: [() -> Void]] = [:]
    private static var anyObservers: [(String) -> Void] = []
    /// Called on the main thread after `key` was changed through the Preferences window, a menu or `Prefs.set`.
    static func observe(_ key: String, _ f: @escaping () -> Void) { observers[key, default: []].append(f) }
    static func observeAll(_ f: @escaping (String) -> Void) { anyObservers.append(f) }
    /// Resets every item of a tab to its default.
    static func resetToDefaults(tab: PrefTab) {
        for i in PrefsRegistry.allItems where PrefsRegistry.sections(for: tab).contains(where: { s in s.items.contains { $0.key == i.key } }) {
            if i.defaultValue != nil { d.removeObject(forKey: i.key); PrefsRegistry.item(i.key)?.onChange?(); observers[i.key]?.forEach { $0() } }
        }
    }
    /// Applies "key=value,key=value" overrides (PLATOON_PREFS env, used by debug captures and tests).
    static func applyOverrides(_ s: String) {
        for part in s.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let (k, v) = (kv[0], kv[1])
            switch PrefsRegistry.item(k)?.kind {
            case .toggle?: d.set(v != "0" && v != "false", forKey: k)
            case .choice?: d.set(Int(v) ?? 0, forKey: k)
            case .slider?: d.set(Double(v) ?? 0, forKey: k)
            default:
                if let i = Int(v) { d.set(i, forKey: k) } else if let x = Double(v) { d.set(x, forKey: k) } else { d.set(v, forKey: k) }
            }
        }
    }
}

/// Passes "key=value" enhancement settings to the core's enhancement registry (Enhance/Registry.swift, the same
/// parser as PLATOON_ENH / platoon-headless --enh).
enum EnhancementBridge {
    static func apply(_ kv: [String], to c: inout GameConfig) {
        guard !kv.isEmpty else { return }
        for e in c.enhancements.apply(kv) { NSLog("Prefs: \(e)"); errors.insert(e.description) }
    }
    /// Values the core registry rejected (shown by --list-prefs so broken plumbing is visible).
    static var errors = Set<String>()
}

// MARK: - automatic rows for core enhancement options

/// Every option in the core's enhancement catalogue gets a Preferences row automatically (keys "enh.<key>"),
/// unless some PrefItem already declares it with `.enhancement("<key>")` / `.gameplay(enhancement:)` — owners
/// can hand-craft a nicer row that way. Groups map to tabs: audio -> Audio, assist -> Assist, everything else ->
/// Gameplay. Bool -> toggle, choice -> popup, int (small range) -> popup, int/double -> slider,
/// optional int -> "change from original" toggle + slider.
extension PrefsRegistry {
    static let autoKeyPrefix = "enh."
    /// Keys without an automatic row: aliases of group options (originalCredits), the core's section-0 trainer
    /// flags (the Game ▸ Trainer covers every section), and headless-only test keys (M14 Amiga keycodes; the app
    /// binds jump / crouch in Controls & Bindings).
    static let aliasKeys: Set<String> = ["originalCredits", "infiniteAmmo", "infiniteMorale", "s0.jumpKey", "s0.crouchKey"]

    static var autoEnhancementSections: [PrefSection] {
        let items = explicitSections.flatMap(\.items)
        let declared = Set(items.compactMap(\.enhancement) + items.flatMap(\.covers)).union(aliasKeys)
        var groups: [(title: String, group: String, items: [PrefItem])] = []
        for info in Enhancements.catalog where !declared.contains(info.key) {
            let items = autoItems(info)
            guard !items.isEmpty else { continue }
            if let i = groups.firstIndex(where: { $0.group == info.group }) { groups[i].items += items }
            else { groups.append((info.groupTitle, info.group, items)) }
        }
        return groups.enumerated().map { n, g in
            let tab: PrefTab = g.group == "audio" ? .audio : g.group == "assist" ? .assist : .gameplay
            return PrefSection(tab: tab, title: g.title, footer: "Core options (applied when a new game starts).", order: 200 + n, items: g.items)
        }
    }

    private static func title(_ info: EnhancementInfo) -> String {
        // "s0.bridgeFailsafe" -> "Bridge failsafe"
        let last = String(info.key.split(separator: ".").last ?? Substring(info.key))
        var out = ""
        for ch in last {
            if ch.isUppercase && !out.isEmpty { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return (out.first.map { String($0).uppercased() } ?? "") + out.dropFirst() + " (\(info.id))"
    }

    /// The number after "original" in a catalogue help text ("original $c00", "original 120 = 2:00"), nil if none.
    static func originalValue(_ help: String) -> Double? {
        guard let r = help.range(of: "original") else { return nil }
        let tail = help[r.upperBound...].drop { $0 == " " || $0 == ":" }
        if tail.hasPrefix("$") || tail.hasPrefix("0x") {
            let digits = tail.dropFirst(tail.hasPrefix("$") ? 1 : 2).prefix { $0.isHexDigit }
            return Int(digits, radix: 16).map(Double.init)
        }
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty, !tail.dropFirst(digits.count).hasPrefix("..") else { return nil }   // "0..5" is a range
        return Double(String(digits))
    }
    /// 1, 2, 4, 8 ... (hex values) or 1, 2, 5, 10, 20 ... (decimal) closest below `raw`.
    static func niceStep(_ raw: Double, hex: Bool) -> Double {
        guard raw > 1 else { return 1 }
        if hex { return pow(2, floor(log2(raw))) }
        let p = pow(10, floor(log10(raw)))
        return [5, 2, 1].map { $0 * p }.first { $0 <= raw } ?? p
    }

    static func autoItems(_ info: EnhancementInfo) -> [PrefItem] {
        let key = autoKeyPrefix + info.key, ekey = info.key
        let t = title(info)
        func item(_ kind: PrefItem.Kind, apply: @escaping (inout GameConfig) -> Void) -> PrefItem {
            var i = PrefItem(key: key, title: t, kind: kind, help: info.help)
            i.isGameplay = info.gameplay; i.requiresRestart = true
            i.applyToConfig = apply
            return i
        }
        let kind = info.kind
        if kind == "bool" {
            let d = info.defaultValue == "1"
            return [item(.toggle(default: d)) { c in _ = c.enhancements.apply(["\(ekey)=\(Prefs.bool(key) ? 1 : 0)"]) }]
        }
        if kind.contains("|") {
            let names = kind.split(separator: "|").map(String.init)
            let d = names.firstIndex(of: info.defaultValue) ?? 0
            return [item(.choice(default: d, options: names.enumerated().map { (value: $0.offset, title: $0.element.capitalized) })) { c in
                let i = Prefs.int(key); if names.indices.contains(i) { _ = c.enhancements.apply(["\(ekey)=\(names[i])"]) }
            }]
        }
        // numeric kinds: "int a...b", "int a...b or original", "number a...b", "int"
        let optional = kind.hasSuffix("or original")
        let nums = kind.split(separator: " ").compactMap { w -> (Double, Double)? in
            let p = w.components(separatedBy: "..."); guard p.count == 2, let a = Double(p[0]), let b = Double(p[1]) else { return nil }
            return (a, b)
        }.first
        guard let (lo, fullHi) = nums else { return [] }   // unbounded numbers: owner must declare a row
        let isInt = kind.hasPrefix("int")
        // The game's own value, from the help text ("original $800" / "original 120"): the default position of
        // the slider, its notation (hex where the original literal is hex) and a useful slider range around it.
        let orig = originalValue(info.help).map { min(fullHi, max(lo, $0)) }
        let hexNotation = orig != nil ? info.help.range(of: "original $") != nil : fullHi > 255
        var hi = fullHi
        if optional, isInt, let o = orig, fullHi - lo > 64 { hi = min(fullHi, max(o * 4, lo + 16)) }
        let fmt: (Double) -> String = { v in isInt ? (hexNotation ? String(format: "$%X", Int(v)) : String(Int(v))) : String(format: "%.2f", v) }
        if !optional, isInt, hi - lo <= 10 {
            let d = Int(info.defaultValue) ?? Int(lo)
            return [item(.choice(default: d, options: (Int(lo)...Int(hi)).map { (value: $0, title: String($0)) })) { c in
                _ = c.enhancements.apply(["\(ekey)=\(Prefs.int(key))"])
            }]
        }
        let step = isInt ? niceStep((hi - lo) / 64, hex: hexNotation) : (hi - lo) / 100
        if !optional {
            let d = Double(info.defaultValue) ?? lo
            return [item(.slider(default: d, range: lo...hi, step: step, format: fmt)) { c in
                let v = Prefs.double(key); _ = c.enhancements.apply(["\(ekey)=\(isInt ? String(Int(v)) : String(v))"])
            }]
        }
        // optional with a small range: popup "Original" + the values (stored -1 = original)
        if isInt, hi - lo <= 10 {
            let opts = [(value: -1, title: "Original")] + (Int(lo)...Int(hi)).map { (value: $0, title: String($0)) }
            return [item(.choice(default: -1, options: opts)) { c in
                let v = Prefs.int(key); _ = c.enhancements.apply(["\(ekey)=" + (v < 0 ? "original" : String(v))])
            }]
        }
        // optional: toggle "change from original" + slider
        let setKey = key + ".override"
        var toggle = PrefItem(key: setKey, title: t, kind: .toggle(default: false), help: info.help)
        toggle.isGameplay = info.gameplay; toggle.requiresRestart = true
        toggle.applyToConfig = { c in
            _ = c.enhancements.apply(["\(ekey)=" + (Prefs.bool(setKey) ? String(Int(Prefs.double(key))) : "original")])
        }
        var slider = PrefItem(key: key, title: "   value", kind: .slider(default: orig ?? lo, range: lo...hi, step: step, format: fmt))
        slider.requiresRestart = true
        slider.enabledIf = { Prefs.bool(setKey) }
        return [toggle, slider]
    }
}
