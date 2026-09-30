import AppKit
import PlatoonCore

// OWNER: [input]. M7 bindings model: logical actions, their keyboard keys and controller buttons, presets (S3
// "Separate fire and SPACE", M13 one-handed layouts, S2 controller layouts), persistence and the generated help
// text. The Original keyboard preset + Extended controller preset reproduce the original app's tables exactly for
// every key that existed before (checked by InputSelfTest); only controller buttons that did nothing before get jobs.

/// A logical action the player can bind.
enum InputAction: String, CaseIterable, Codable {
    case up, down, left, right, fire
    case space          // Amiga SPACE: jungle grenade (no direction held), flare
    case changeSoldier  // Amiga Left-Alt: change soldier (jungle)
    case yes, no        // Amiga Y / N: trap-door prompt
    case pause          // Amiga TAB: in-game pause
    case music          // Amiga F10: music / sound FX
    case abort          // Amiga DEL: abort to the title
    case help           // Amiga HELP (cheat)
    case keypadMinus    // Amiga keypad minus (MEGA CHEAT code)
    case jump, crouch   // M14 explicit jump / crouch (host buttons; only with the section-0 option)
    case turboFire      // M13 auto-fire button (with "Auto-fire: turbo button")

    var title: String {
        switch self {
        case .up: return "Up"; case .down: return "Down"; case .left: return "Left"; case .right: return "Right"
        case .fire: return "Fire"
        case .space: return "SPACE (grenade / flare)"
        case .changeSoldier: return "Change soldier (Alt)"
        case .yes: return "Yes (Y)"; case .no: return "No (N)"
        case .pause: return "Pause (TAB)"; case .music: return "Music / FX (F10)"
        case .abort: return "Abort to title (DEL)"; case .help: return "HELP"; case .keypadMinus: return "Keypad −"
        case .jump: return "Jump (jungle, M14)"; case .crouch: return "Crouch (jungle, M14)"
        case .turboFire: return "Turbo fire"
        }
    }
    /// The Amiga raw key this action presses (nil = joystick / host action).
    var amigaKey: UInt8? {
        switch self {
        case .space: return 0x40; case .changeSoldier: return 0x64; case .yes: return 0x15; case .no: return 0x36
        case .pause: return 0x42; case .music: return 0x59; case .abort: return 0x46; case .help: return 0x5f
        case .keypadMinus: return 0x4a
        default: return nil
        }
    }
    /// Joystick bits (JoyState field) this action sets.
    var joyBit: JoyBit? {
        switch self {
        case .up: return .up; case .down: return .down; case .left: return .left; case .right: return .right
        case .fire, .turboFire: return .fire
        default: return nil
        }
    }
    /// Controller buttons bound to this action send a short tap instead of mirroring the button (Left-Alt is
    /// polled every tick: holding it re-enters the man-select screen).
    var padTap: Bool { self == .changeSoldier }
}

enum JoyBit: Int, CaseIterable { case up, down, left, right, fire }

extension InputManager.JoyState {
    subscript(_ b: JoyBit) -> Bool {
        get { switch b { case .up: return up; case .down: return down; case .left: return left; case .right: return right; case .fire: return fire } }
        set { switch b { case .up: up = newValue; case .down: down = newValue; case .left: left = newValue; case .right: right = newValue; case .fire: fire = newValue } }
    }
    var any: Bool { up || down || left || right || fire }
    var anyDirection: Bool { up || down || left || right }
}

/// A keyboard key: a physical position (Mac virtual keycode) or a character (resolved through the current layout,
/// so "Y" is the key labelled Y on every layout).
enum KeyRef: Codable, Hashable {
    case code(UInt16)
    case char(String)

    /// The Mac keycode now (nil if no key of the layout types the character).
    var keycode: UInt16? {
        switch self {
        case .code(let c): return c
        case .char(let s):
            guard let ch = s.first else { return nil }
            if !InputSettings.layoutLetters { return KeyLayout.usCharToCode[ch] }
            return KeyLayout.code(for: ch) ?? KeyLayout.usCharToCode[ch]
        }
    }
    var name: String {
        switch self {
        case .code(let c): return KeyLayout.name(c)
        case .char(let s): return s.uppercased()
        }
    }
}

struct ActionBinding: Codable, Equatable {
    var keys: [KeyRef] = []
    var pad: [PadButton] = []
}

/// The complete binding table.
struct BindingSet: Codable, Equatable {
    var actions: [String: ActionBinding] = [:]

    subscript(_ a: InputAction) -> ActionBinding {
        get { actions[a.rawValue] ?? ActionBinding() }
        set { actions[a.rawValue] = newValue }
    }

    // MARK: presets

    enum KeyboardPreset: Int, CaseIterable {
        case original = 0, separate = 1, leftHand = 2, rightHand = 3
        var title: String {
            switch self {
            case .original: return "Original (Space = fire and SPACE)"
            case .separate: return "Separate fire and SPACE (Z/X fire, Space = SPACE)"
            case .leftHand: return "One-handed, left hand (WASD)"
            case .rightHand: return "One-handed, right hand (arrows)"
            }
        }
    }
    enum PadPreset: Int, CaseIterable {
        case extended = 0, original = 1, leftHalf = 2, rightHalf = 3
        var title: String {
            switch self {
            case .extended: return "Extended (X = SPACE, Y = change soldier, LB/LT = Yes/No)"
            case .original: return "Original mapping only"
            case .leftHalf: return "One-handed, left half (d-pad / left stick, LB fire)"
            case .rightHalf: return "One-handed, right half (right stick, RB fire)"
            }
        }
    }
    static let customPreset = 99

    /// Keys of every action that the original app had (and the preset keeps): pause/music/abort/help/minus.
    private static func common(_ s: inout BindingSet) {
        s[.pause].keys = [.code(0x30)]                    // Tab
        s[.music].keys = [.code(0x6d)]                    // F10
        s[.abort].keys = [.code(0x75)]                    // forward delete (Mac "Del")
        s[.help].keys = [.code(0x72), .code(0x67)]        // Help, F11
        s[.keypadMinus].keys = [.code(0x4e), .code(0x6f)] // keypad minus, F12
        s[.jump].keys = [.char("x")]
        s[.crouch].keys = [.char("c")]
    }

    mutating func applyKeyboard(_ p: KeyboardPreset) {
        for a in InputAction.allCases { self[a].keys = [] }
        BindingSet.common(&self)
        switch p {
        case .original, .separate:
            self[.up].keys = [.code(0x7e)]; self[.down].keys = [.code(0x7d)]
            self[.left].keys = [.code(0x7b)]; self[.right].keys = [.code(0x7c)]
            self[.changeSoldier].keys = [.code(0x3a)]      // Left Option
            self[.yes].keys = [.char("y")]; self[.no].keys = [.char("n")]
            if p == .original {
                self[.fire].keys = [.code(0x31), .char("z")]
                self[.space].keys = [.code(0x31)]
            } else {
                self[.fire].keys = [.char("z"), .char("x")]
                self[.space].keys = [.code(0x31)]
                self[.jump].keys = [.char("c")]; self[.crouch].keys = [.char("v")]
            }
        case .leftHand:
            self[.up].keys = [.code(0x0d)]; self[.left].keys = [.code(0x00)]     // W A S D by position
            self[.down].keys = [.code(0x01)]; self[.right].keys = [.code(0x02)]
            self[.fire].keys = [.code(0x31)]                                     // Space
            self[.space].keys = [.code(0x0c)]                                    // Q
            self[.changeSoldier].keys = [.code(0x0e), .code(0x3a)]               // E, Left Option
            self[.yes].keys = [.code(0x0f), .char("y")]                          // R, Y
            self[.no].keys = [.code(0x03), .char("n")]                           // F, N
            self[.jump].keys = [.code(0x06)]; self[.crouch].keys = [.code(0x07)] // Z X positions
            self[.music].keys = [.code(0x6d), .code(0x05)]                       // F10, G
        case .rightHand:
            self[.up].keys = [.code(0x7e)]; self[.down].keys = [.code(0x7d)]
            self[.left].keys = [.code(0x7b)]; self[.right].keys = [.code(0x7c)]
            self[.fire].keys = [.code(0x3c), .code(0x2c)]                        // Right Shift, /
            self[.space].keys = [.code(0x24)]                                    // Return
            self[.changeSoldier].keys = [.code(0x2f), .code(0x3d)]               // ., Right Option
            self[.yes].keys = [.code(0x29), .char("y")]                          // ;, Y
            self[.no].keys = [.code(0x27), .char("n")]                           // ', N
            self[.jump].keys = [.code(0x2b)]; self[.crouch].keys = [.code(0x2e)] // , and M positions
            self[.pause].keys = [.code(0x30), .code(0x1e)]                       // Tab, ]
            self[.music].keys = [.code(0x6d), .code(0x21)]                       // F10, [
        }
    }

    mutating func applyPad(_ p: PadPreset) {
        for a in InputAction.allCases { self[a].pad = [] }
        switch p {
        case .extended, .original:
            self[.up].pad = [.up]; self[.down].pad = [.down]; self[.left].pad = [.left]; self[.right].pad = [.right]
            self[.fire].pad = [.a, .b, .rt, .rb]
            self[.pause].pad = [.menu]; self[.music].pad = [.options]
            if p == .extended {
                self[.space].pad = [.x]; self[.changeSoldier].pad = [.y]
                self[.yes].pad = [.lb]; self[.no].pad = [.lt]
                self[.jump].pad = [.lb]; self[.crouch].pad = [.lt]
            }
        case .leftHalf:
            self[.up].pad = [.up]; self[.down].pad = [.down]; self[.left].pad = [.left]; self[.right].pad = [.right]
            self[.fire].pad = [.lb]; self[.space].pad = [.lt]; self[.changeSoldier].pad = [.options]
            self[.pause].pad = [.menu]
        case .rightHalf:
            self[.up].pad = [.rsUp]; self[.down].pad = [.rsDown]; self[.left].pad = [.rsLeft]; self[.right].pad = [.rsRight]
            self[.fire].pad = [.rb, .rt, .a]; self[.space].pad = [.x]; self[.changeSoldier].pad = [.y]
            self[.pause].pad = [.menu]
        }
    }

    static func preset(keyboard k: KeyboardPreset, pad p: PadPreset) -> BindingSet {
        var s = BindingSet(); s.applyKeyboard(k); s.applyPad(p); return s
    }
    /// Today's (original app's) tables + the S2 controller extras.
    static let standard = preset(keyboard: .original, pad: .extended)

    // MARK: queries

    /// Actions bound to controller button `b`.
    func actions(forPad b: PadButton) -> [InputAction] { InputAction.allCases.filter { self[$0].pad.contains(b) } }

    /// Keys bound to more than one action, and pad buttons likewise (for the Controls window).
    func conflicts() -> [String] {
        var byKey: [UInt16: [InputAction]] = [:], byPad: [PadButton: [InputAction]] = [:]
        for a in InputAction.allCases {
            for k in self[a].keys { if let c = k.keycode { byKey[c, default: []].append(a) } }
            for b in self[a].pad { byPad[b, default: []].append(a) }
        }
        // intended pairs: fire+SPACE on Space (original), jump/crouch sharing with yes/no/letters
        func benign(_ l: [InputAction]) -> Bool {
            let s = Set(l)
            if s == [.fire, .space] { return true }
            if s.isSubset(of: [.yes, .jump]) || s.isSubset(of: [.no, .crouch]) { return true }
            return false
        }
        var out: [String] = []
        for (c, l) in byKey.sorted(by: { $0.key < $1.key }) where l.count > 1 && !benign(l) {
            out.append("\(KeyLayout.name(c)): " + l.map(\.title).joined(separator: " + "))
        }
        for (b, l) in byPad.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where l.count > 1 && !benign(l) {
            out.append("\(b.title): " + l.map(\.title).joined(separator: " + "))
        }
        return out
    }

    /// Help text generated from the live bindings.
    func helpText(padConnected: Bool = true) -> String {
        var lines: [String] = []
        func keys(_ a: InputAction) -> String { self[a].keys.map(\.name).joined(separator: " / ") }
        func pad(_ a: InputAction) -> String { self[a].pad.map(\.title).joined(separator: " / ") }
        let dirs = [InputAction.up, .down, .left, .right].map { keys($0) }.joined(separator: " ")
        lines.append("Joystick: \(dirs)" + (pad(.up).isEmpty ? "" : " — controller: \(padDirsTitle)"))
        for a in InputAction.allCases where a.joyBit == nil || a == .fire || a == .turboFire {
            let k = keys(a), p = pad(a)
            if k.isEmpty && p.isEmpty { continue }
            if (a == .jump || a == .crouch) && !InputSettings.m14Available { continue }
            if a == .turboFire && InputSettings.autoFire != 2 { continue }
            var s = "\(a.title): " + (k.isEmpty ? "—" : k)
            if !p.isEmpty { s += "   (controller \(p))" }
            lines.append(s)
        }
        if self[.fire].keys.contains(.code(0x31)) && self[.space].keys.contains(.code(0x31)) {
            lines.append("Note: Space is both fire and the Amiga SPACE key (jungle grenade, flare), as on the original port.")
        }
        return lines.joined(separator: "\n")
    }

    private var padDirsTitle: String {
        self[.up].pad.contains(.rsUp) ? "right stick" : "d-pad / left stick"
    }
}

extension PadButton {
    var title: String {
        switch self {
        case .up: return "D-pad ↑"; case .down: return "D-pad ↓"; case .left: return "D-pad ←"; case .right: return "D-pad →"
        case .a: return "A"; case .b: return "B"; case .x: return "X"; case .y: return "Y"
        case .lb: return "LB"; case .rb: return "RB"; case .lt: return "LT"; case .rt: return "RT"
        case .l3: return "L3"; case .r3: return "R3"; case .menu: return "Menu"; case .options: return "Options"
        case .rsUp: return "Right stick ↑"; case .rsDown: return "Right stick ↓"; case .rsLeft: return "Right stick ←"; case .rsRight: return "Right stick →"
        }
    }
}

// MARK: - settings (prefs keys + persistence)

enum InputSettings {
    static let bindingsKey = "input.bindings.v1"
    static let keyboardPresetKey = "input.keyboardPreset"
    static let padPresetKey = "input.padPreset"
    static let layoutLettersKey = "input.layoutLetters"
    static let deadZoneKey = "input.deadZone"
    static let padContextKey = "input.padContext"
    static let padHintsKey = "input.padHints"
    static let tapStretchKey = "input.tapStretch"
    static let tapStretchFramesKey = "input.tapStretchFrames"
    static let toggleFireKey = "input.toggleFire"
    static let toggleDirsKey = "input.toggleDirections"
    static let autoFireKey = "input.autoFire"
    static let autoFireRateKey = "input.autoFireRate"
    static let aimAssistKey = "input.aimAssist"
    static let aimSpeedKey = "input.aimStickSpeed"
    static let rumbleKey = "input.rumble"
    static let rumbleStrengthKey = "input.rumbleStrength"

    static var layoutLetters: Bool { UserDefaults.standard.object(forKey: layoutLettersKey) == nil ? true : Prefs.bool(layoutLettersKey) }
    static var deadZone: Double { UserDefaults.standard.object(forKey: deadZoneKey) == nil ? 0.4 : Prefs.double(deadZoneKey) }
    static var autoFire: Int { Prefs.int(autoFireKey) }
    /// M14 host buttons exist in the core (Section0HostButtons).
    static let m14Available = true

    /// The persisted binding table (defaults: BindingSet.standard).
    static func load() -> BindingSet {
        if let d = UserDefaults.standard.data(forKey: bindingsKey), var s = try? JSONDecoder().decode(BindingSet.self, from: d) {
            // actions added in later versions get their default bindings
            for a in InputAction.allCases where s.actions[a.rawValue] == nil { s[a] = BindingSet.standard[a] }
            return s
        }
        return .standard
    }
    static func save(_ s: BindingSet) {
        if s == .standard { UserDefaults.standard.removeObject(forKey: bindingsKey) }
        else if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: bindingsKey) }
    }
}
