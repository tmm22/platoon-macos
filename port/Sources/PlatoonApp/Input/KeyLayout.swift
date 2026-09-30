import AppKit
import Carbon

// OWNER: [input]. S3(b): international keyboard layouts.
//
// The Amiga game reads raw keycodes of a US Amiga keyboard (Y/N at the trap door, letters of the cheat codes and of
// the keyboard name entry). The original app mapped Mac keys by US-ANSI *position*, so on QWERTZ the key labelled Y
// sent Amiga Z and on AZERTY the key labelled A sent Amiga Q. With "letters follow the keyboard layout" (default on)
// every key of the main block that types a letter (or a character that exists unshifted on the US layout) is
// mapped by that CHARACTER to the Amiga key that types it; everything else (digits row, arrows, F-keys, keypad,
// modifiers) stays positional. On the US layout the result is exactly the original table (checked by the input
// self-test).

enum KeyLayout {
    /// US-ANSI Mac keycodes of the unshifted characters of the main block (the positions the Amiga table uses).
    static let usCharToCode: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0b, "q": 0x0c, "w": 0x0d, "e": 0x0e, "r": 0x0f, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1a, "-": 0x1b, "8": 0x1c, "0": 0x1d, "]": 0x1e,
        "o": 0x1f, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2a, ",": 0x2b, "/": 0x2c, "n": 0x2d, "m": 0x2e, ".": 0x2f, "`": 0x32,
    ]
    static let usCodeToChar: [UInt16: Character] = Dictionary(uniqueKeysWithValues: usCharToCode.map { ($1, $0) })
    /// Main-block keycodes that can be remapped by character (letters and punctuation; not the digits row, whose
    /// unshifted characters are symbols on some layouts, e.g. AZERTY).
    static let mainBlock: Set<UInt16> = Set(usCodeToChar.keys.filter { !(usCodeToChar[$0]!.isNumber) })

    /// Test / simulation override: PLATOON_KEYLAYOUT=us|qwertz|azerty (partial tables of the letter keys).
    static var simulated: String? = ProcessInfo.processInfo.environment["PLATOON_KEYLAYOUT"]

    /// keycode -> unshifted character of the current layout (lower case), main block only.
    private(set) static var chars: [UInt16: Character] = [:]
    private(set) static var layoutName = "U.S."
    private static var observer: NSObjectProtocol?
    /// Bumped whenever the layout table changes (resolvers cache against it).
    private(set) static var generation = 0

    static func start() {
        refresh()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in
            refresh()
        }
    }

    static func refresh() {
        if let s = simulated { chars = simulatedTable(s); layoutName = s; generation += 1; return }
        var t: [UInt16: Character] = [:]
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            if let n = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
                layoutName = Unmanaged<CFString>.fromOpaque(n).takeUnretainedValue() as String
            }
            data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                guard let layout = p.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                for code in usCodeToChar.keys {
                    var dead: UInt32 = 0, len = 0
                    var buf = [UniChar](repeating: 0, count: 4)
                    let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &len, &buf)
                    if st == noErr, len == 1, let s = Unicode.Scalar(buf[0]) { t[code] = Character(s).lowercased().first }
                }
            }
        }
        if t.isEmpty { t = usCodeToChar }           // no layout data: behave as US
        chars = t
        generation += 1
    }

    /// Character typed by `code` on the current layout (main block only).
    static func character(_ code: UInt16) -> Character? { chars[code] }

    /// The keycode that types `c` on the current layout (nil if no main-block key types it unshifted).
    static func code(for c: Character) -> UInt16? {
        let lc = c.lowercased().first ?? c
        // deterministic if several keys type it: the US position first, then the lowest keycode
        if let us = usCharToCode[lc], chars[us] == lc { return us }
        return chars.filter { $0.value == lc }.keys.min()
    }

    /// The US-position keycode whose Amiga key types the same character as Mac key `code` on the current layout,
    /// or nil to use `code` positionally.
    static func usEquivalent(_ code: UInt16) -> UInt16? {
        guard mainBlock.contains(code), let c = chars[code], !c.isNumber, let us = usCharToCode[c] else { return nil }
        return us
    }

    /// Human-readable key name (current layout for the main block).
    static func name(_ code: UInt16) -> String {
        if let n = specialNames[code] { return n }
        if let c = chars[code] ?? usCodeToChar[code] { return String(c).uppercased() }
        return String(format: "key %02X", code)
    }

    static let specialNames: [UInt16: String] = [
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x33: "Backspace", 0x35: "Esc", 0x75: "Del", 0x72: "Help",
        0x7e: "↑", 0x7d: "↓", 0x7b: "←", 0x7c: "→",
        0x7a: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9",
        0x6d: "F10", 0x67: "F11", 0x6f: "F12", 0x69: "F13", 0x6b: "F14", 0x71: "F15",
        0x3a: "Left ⌥", 0x3d: "Right ⌥", 0x38: "Left ⇧", 0x3c: "Right ⇧", 0x3b: "Left ⌃", 0x3e: "Right ⌃", 0x39: "Caps Lock",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4", 0x57: "Keypad 5",
        0x58: "Keypad 6", 0x59: "Keypad 7", 0x5b: "Keypad 8", 0x5c: "Keypad 9", 0x41: "Keypad .", 0x4e: "Keypad −",
        0x45: "Keypad +", 0x43: "Keypad *", 0x4b: "Keypad /", 0x4c: "Enter", 0x51: "Keypad =", 0x47: "Clear",
    ]

    /// Partial tables for tests: which character each US-position key types.
    static func simulatedTable(_ name: String) -> [UInt16: Character] {
        var t = usCodeToChar
        switch name.lowercased() {
        case "qwertz", "de":
            t[0x06] = "y"; t[0x10] = "z"; t[0x1b] = "ß"; t[0x18] = "´"; t[0x21] = "ü"; t[0x1e] = "+"; t[0x29] = "ö"
            t[0x27] = "ä"; t[0x2a] = "#"; t[0x2c] = "-"; t[0x32] = "^"
        case "azerty", "fr":
            t[0x00] = "q"; t[0x0c] = "a"; t[0x0d] = "z"; t[0x06] = "w"; t[0x29] = "m"; t[0x2e] = ","; t[0x2b] = ";"
            t[0x2f] = ":"; t[0x2c] = "="; t[0x1b] = ")"; t[0x18] = "-"; t[0x21] = "^"; t[0x1e] = "$"; t[0x27] = "ù"
            t[0x2a] = "`"; t[0x32] = "<"
            for (c, k) in [("&", 0x12), ("é", 0x13), ("\"", 0x14), ("'", 0x15), ("§", 0x16), ("(", 0x17), ("ç", 0x19),
                           ("è", 0x1a), ("!", 0x1c), ("à", 0x1d)] as [(String, UInt16)] { t[k] = Character(c) }
        default: break
        }
        return t
    }
}
