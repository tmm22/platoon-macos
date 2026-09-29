import Foundation

// Enhancement REGISTRY (owner: core). One mechanism for the app, platoon-headless (--enh) and the environment
// (PLATOON_ENH): typed option groups whose fields are reachable through string "key=value" pairs.
//
//   PLATOON_ENH="originalCredits=0,s0.bridgeFailsafe=1,difficulty=recruit"
//   platoon-headless --enh s1.keepItems=1 --enh game.lives=3     (repeatable; "--enh list" prints the catalogue)
//   var e = Enhancements(); try e.apply("audio.ghostVoices=1")    (app: Prefs -> EnhancementBridge)
//
// Keys are "<group prefix>.<option key>" (e.g. "s0.bridgeFailsafe"); root options have no prefix
// (originalCredits, infiniteAmmo, infiniteMorale, difficulty). An unprefixed key that is unique across all groups
// is accepted too. Values: Bool 1/0/true/false/on/off/yes/no; Int decimal, 0x.. or $.. hex; Double; optional
// values also accept "" / "nil" / "original" / "default" (= nil = the original literal); choices by raw value.
//
// Adding an option (wave-2 owners): only edit YOUR group file (Enhance/<Group>Options.swift):
//   1. a stored property with the ORIGINAL behaviour as default:     public var bridgeFailsafe = false
//   2. an entry in `options`:  .bool("bridgeFailsafe", \.bridgeFailsafe, id: "S6", gameplay: true, help: "...")
//   3. the hook in translated code, marked `// ENHANCEMENT S6` and guarded by `enhancements.section0.bridgeFailsafe`.
// `gameplay: true` = changes what the game does -> taints the run (F4/S5, separate hiscore table).
//
// Ground rule: with every option at its default the translated game must behave byte-identically
// (tools/regress_all.sh). Enhancements are copied into Platoon.enhancements when the game starts
// (PlatoonGame.main), so changes take effect after a reset.

/// One option group (a struct of typed fields) with its string-addressable catalogue.
public protocol EnhancementGroup {
    init()
    /// Key prefix ("s0", "s1", "s2", "audio", "assist", "kernel", "game").
    static var prefix: String { get }
    /// Human-readable title (Preferences section / --enh list).
    static var title: String { get }
    /// Owning agent/module.
    static var owner: String { get }
    /// The options of this group.
    static var options: [EnhancementOption<Self>] { get }
    /// M10: fill this group's difficulty knobs from a preset (knobs set explicitly win). Default: no knobs.
    mutating func applyDifficulty(_ preset: DifficultyPreset)
}

extension EnhancementGroup {
    public mutating func applyDifficulty(_ preset: DifficultyPreset) {}
}

public enum EnhancementError: Error, CustomStringConvertible {
    case unknownKey(String), ambiguousKey(String, [String]), badValue(key: String, value: String, expected: String)
    public var description: String {
        switch self {
        case .unknownKey(let k): return "unknown enhancement option '\(k)' (see --enh list)"
        case .ambiguousKey(let k, let c): return "ambiguous enhancement option '\(k)': \(c.joined(separator: ", "))"
        case .badValue(let k, let v, let e): return "bad value '\(v)' for '\(k)' (expected \(e))"
        }
    }
}

/// A typed, string-addressable option of group `G`.
public struct EnhancementOption<G> {
    public enum Kind {
        case bool
        case int(ClosedRange<Int>?)
        case optionalInt(ClosedRange<Int>?)
        case double(ClosedRange<Double>?)
        case choice([String])
        public var description: String {
            switch self {
            case .bool: return "bool"
            case .int(let r): return r.map { "int \($0.lowerBound)...\($0.upperBound)" } ?? "int"
            case .optionalInt(let r): return (r.map { "int \($0.lowerBound)...\($0.upperBound)" } ?? "int") + " or original"
            case .double(let r): return r.map { "number \($0.lowerBound)...\($0.upperBound)" } ?? "number"
            case .choice(let c): return c.joined(separator: "|")
            }
        }
    }
    public let key: String
    public let kind: Kind
    /// Roadmap item (port/ENHANCEMENT_IDEAS.md), e.g. "S6".
    public let id: String
    /// Changes game behaviour -> the run is assisted (F4/S5) when the value differs from the default.
    public let gameplay: Bool
    public let help: String
    let get: (G) -> String
    let set: (inout G, String) throws -> Void

    public static func bool(_ key: String, _ kp: WritableKeyPath<G, Bool>, id: String, gameplay: Bool, help: String) -> Self {
        Self(key: key, kind: .bool, id: id, gameplay: gameplay, help: help,
             get: { $0[keyPath: kp] ? "1" : "0" },
             set: { g, v in
                 switch v.lowercased() {
                 case "1", "true", "on", "yes", "": g[keyPath: kp] = true
                 case "0", "false", "off", "no": g[keyPath: kp] = false
                 default: throw EnhancementError.badValue(key: key, value: v, expected: "1/0")
                 }
             })
    }

    public static func int(_ key: String, _ kp: WritableKeyPath<G, Int>, range: ClosedRange<Int>? = nil, id: String,
                           gameplay: Bool, help: String) -> Self {
        Self(key: key, kind: .int(range), id: id, gameplay: gameplay, help: help,
             get: { String($0[keyPath: kp]) },
             set: { g, v in
                 guard let n = parseInt(v), range?.contains(n) ?? true else {
                     throw EnhancementError.badValue(key: key, value: v, expected: Kind.int(range).description)
                 }
                 g[keyPath: kp] = n
             })
    }

    /// nil = the original literal (hooks read `knob ?? <literal>`).
    public static func optionalInt(_ key: String, _ kp: WritableKeyPath<G, Int?>, range: ClosedRange<Int>? = nil, id: String,
                                   gameplay: Bool, help: String) -> Self {
        Self(key: key, kind: .optionalInt(range), id: id, gameplay: gameplay, help: help,
             get: { $0[keyPath: kp].map(String.init) ?? "original" },
             set: { g, v in
                 if ["", "nil", "none", "original", "default"].contains(v.lowercased()) { g[keyPath: kp] = nil; return }
                 guard let n = parseInt(v), range?.contains(n) ?? true else {
                     throw EnhancementError.badValue(key: key, value: v, expected: Kind.optionalInt(range).description)
                 }
                 g[keyPath: kp] = n
             })
    }

    public static func double(_ key: String, _ kp: WritableKeyPath<G, Double>, range: ClosedRange<Double>? = nil, id: String,
                              gameplay: Bool, help: String) -> Self {
        Self(key: key, kind: .double(range), id: id, gameplay: gameplay, help: help,
             get: { String($0[keyPath: kp]) },
             set: { g, v in
                 guard let x = Double(v), range?.contains(x) ?? true else {
                     throw EnhancementError.badValue(key: key, value: v, expected: Kind.double(range).description)
                 }
                 g[keyPath: kp] = x
             })
    }

    public static func choice<E: RawRepresentable & CaseIterable>(_ key: String, _ kp: WritableKeyPath<G, E>, id: String,
                                                                  gameplay: Bool, help: String) -> Self where E.RawValue == String {
        let names = E.allCases.map { $0.rawValue }
        return Self(key: key, kind: .choice(names), id: id, gameplay: gameplay, help: help,
                    get: { $0[keyPath: kp].rawValue },
                    set: { g, v in
                        if let e = E(rawValue: v) ?? E.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) {
                            g[keyPath: kp] = e
                        } else if let i = Int(v), i >= 0, i < names.count, let e = E(rawValue: names[i]) {
                            g[keyPath: kp] = e
                        } else {
                            throw EnhancementError.badValue(key: key, value: v, expected: names.joined(separator: "|"))
                        }
                    })
    }
}

func parseInt(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16) }
    if t.hasPrefix("$") { return Int(t.dropFirst(), radix: 16) }
    if t.hasPrefix("-0x") { return Int(t.dropFirst(3), radix: 16).map { -$0 } }
    return Int(t)
}

/// Catalogue entry of one option (for UIs, --enh list, tests).
public struct EnhancementInfo {
    /// Full key ("s0.bridgeFailsafe"; root options without prefix).
    public let key: String
    public let group: String, groupTitle: String, owner: String
    public let kind: String
    public let defaultValue: String
    public let id: String
    public let gameplay: Bool
    public let help: String
}

/// All enhancement switches of a run (default = the original 1988 game).
public struct Enhancements {
    public init() {}

    // MARK: root options (no prefix)

    /// Section-0 trainer-style hooks (Section0.swift / Section0Player.swift, `// ENHANCEMENT` sites).
    public var infiniteMorale = false
    public var infiniteAmmo = false
    /// M10 difficulty preset: Original = bit-exact; Recruit/Veteran fill each section's knobs; Custom = only the
    /// knobs set explicitly. Resolved into the groups at game start (`resolved()`).
    public var difficulty: DifficultyPreset = .original
    /// Credits page: restore the original Ocean lines (kernel; default on). Alias of kernel.originalCredits.
    public var originalCredits: Bool {
        get { kernel.originalCredits }
        set { kernel.originalCredits = newValue }
    }

    // MARK: groups

    public var kernel = KernelOptions()
    public var game = GameplayOptions()
    public var section0 = Section0Options()
    public var section1 = Section1Options()
    public var section2 = Section2Options()
    public var audio = AudioOptions()
    public var assist = AssistOptions()

    static let rootOptions: [EnhancementOption<Enhancements>] = [
        .bool("originalCredits", \.originalCredits, id: "kernel", gameplay: false,
              help: "Credits page shows the original Ocean lines instead of the Darc crack's (default on)."),
        .bool("infiniteAmmo", \.infiniteAmmo, id: "trainer", gameplay: true,
              help: "Jungle: firing does not use ammunition (section 0 hook)."),
        .bool("infiniteMorale", \.infiniteMorale, id: "trainer", gameplay: true,
              help: "Jungle: morale never drops (section 0 hook)."),
        .choice("difficulty", \.difficulty, id: "M10", gameplay: true,
                help: "Difficulty preset: original (bit-exact), recruit, veteran, custom (only explicitly set knobs)."),
    ]

    // MARK: type-erased catalogue

    struct ErasedOption {
        let info: EnhancementInfo
        let get: (Enhancements) -> String
        let set: (inout Enhancements, String) throws -> Void
    }

    static func erase<G: EnhancementGroup>(_ kp: WritableKeyPath<Enhancements, G>) -> [ErasedOption] {
        let def = G()
        return G.options.map { o in
            ErasedOption(info: EnhancementInfo(key: "\(G.prefix).\(o.key)", group: G.prefix, groupTitle: G.title, owner: G.owner,
                                               kind: o.kind.description, defaultValue: o.get(def), id: o.id,
                                               gameplay: o.gameplay, help: o.help),
                         get: { o.get($0[keyPath: kp]) },
                         set: { e, v in try o.set(&e[keyPath: kp], v) })
        }
    }

    static let allOptions: [ErasedOption] = {
        let def = Enhancements()
        var list = rootOptions.map { o in
            ErasedOption(info: EnhancementInfo(key: o.key, group: "", groupTitle: "General", owner: "core",
                                               kind: o.kind.description, defaultValue: o.get(def), id: o.id,
                                               gameplay: o.gameplay, help: o.help),
                         get: o.get, set: o.set)
        }
        list += erase(\.kernel) + erase(\.game) + erase(\.section0) + erase(\.section1) + erase(\.section2)
            + erase(\.audio) + erase(\.assist)
        return list
    }()

    /// The catalogue of every option (stable order: root, kernel, game, s0, s1, s2, audio, assist).
    public static var catalog: [EnhancementInfo] { allOptions.map { $0.info } }

    static func lookup(_ key: String) throws -> ErasedOption {
        if let o = allOptions.first(where: { $0.info.key == key }) { return o }
        let lk = key.lowercased()
        if let o = allOptions.first(where: { $0.info.key.lowercased() == lk }) { return o }
        if !key.contains(".") {
            let c = allOptions.filter { $0.info.key.split(separator: ".").last.map(String.init)?.lowercased() == lk }
            if c.count == 1 { return c[0] }
            if c.count > 1 { throw EnhancementError.ambiguousKey(key, c.map { $0.info.key }) }
        }
        throw EnhancementError.unknownKey(key)
    }

    /// Sets one option from its string value.
    public mutating func set(_ key: String, _ value: String) throws {
        try Enhancements.lookup(key.trimmingCharacters(in: .whitespaces)).set(&self, value.trimmingCharacters(in: .whitespaces))
    }

    /// Current value of one option as a string.
    public func value(_ key: String) throws -> String { try Enhancements.lookup(key).get(self) }

    /// Applies "k=v,k2=v2" (also ';' or whitespace separated; a bare "k" means k=1).
    public mutating func apply(_ spec: String) throws {
        for item in spec.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == " " }) {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard let k = kv.first, !k.isEmpty else { continue }
            try set(k, kv.count > 1 ? kv[1] : "1")
        }
    }

    /// Applies several "k=v" strings; returns the errors instead of throwing (UI use).
    @discardableResult public mutating func apply(_ items: [String]) -> [EnhancementError] {
        var errs: [EnhancementError] = []
        for i in items {
            do { try apply(i) } catch let e as EnhancementError { errs.append(e) } catch {}
        }
        return errs
    }

    /// Options that differ from their defaults ("key=value").
    public var changed: [String] {
        let def = Enhancements()
        return Enhancements.allOptions.compactMap { o in
            let v = o.get(self)
            return v == o.get(def) ? nil : "\(o.info.key)=\(v)"
        }
    }

    /// Why a run with these options is assisted (F4/S5): gameplay options that differ from their defaults.
    /// "difficulty:<preset>" for a preset; empty = original game.
    public var assistReasons: Set<String> {
        let def = Enhancements()
        var r = Set<String>()
        for o in Enhancements.allOptions where o.info.gameplay && o.info.key != "difficulty" {
            if o.get(self) != o.get(def) { r.insert(o.info.key) }
        }
        if difficulty != .original { r.insert("difficulty:\(difficulty.rawValue)") }
        return r
    }

    /// The options with the difficulty preset resolved into every group's knobs (called at game start).
    public func resolved() -> Enhancements {
        var e = self
        guard difficulty != .original, difficulty != .custom else { return e }
        e.kernel.applyDifficulty(difficulty)
        e.game.applyDifficulty(difficulty)
        e.section0.applyDifficulty(difficulty)
        e.section1.applyDifficulty(difficulty)
        e.section2.applyDifficulty(difficulty)
        e.audio.applyDifficulty(difficulty)
        e.assist.applyDifficulty(difficulty)
        return e
    }

    /// Text listing of the catalogue (platoon-headless --enh list).
    public static func catalogText() -> String {
        var s = "Enhancement options (key=value; default in brackets; * = gameplay, taints the run):\n"
        var last = "-"
        for i in catalog {
            if i.group != last { s += "\n[\(i.groupTitle)]  owner: \(i.owner)\n"; last = i.group }
            s += "  \(i.gameplay ? "*" : " ") \(i.key) (\(i.kind)) [\(i.defaultValue)]  \(i.id): \(i.help)\n"
        }
        return s
    }
}
