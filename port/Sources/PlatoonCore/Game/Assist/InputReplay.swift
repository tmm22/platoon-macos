import Foundation

// M17 input replays (owner: assist). The port is deterministic (the vblank RNG's "interrupted d1" term is never
// set), so the joystick state of every frame plus the keyboard events reproduce a run exactly from power-on (or from
// a start section with its carry).
//
// Recording is read-only and happens at the start of every emulated frame (Machine.frameHook, game thread parked):
//  - the joystick / fire bits the frame will run with (Input.up/down/left/right/fire/fire0), as edges;
//  - the key events DELIVERED to the keyboard CIA during the previous frame (Machine.deliverKey writes CIA-A SDR =
//    ~raw at line 100; the recorder sees SDR change). Recording deliveries instead of Input.key() calls captures
//    every source (keyboard, controller taps, host menus) and makes the replay independent of how the host paced its
//    key queue. Two consecutive deliveries of the very same raw code (e.g. a key pressed twice without a release in
//    between) are indistinguishable; the input layers never send those.
//  - M14 host buttons (Section0HostButtons jump/crouch) as "#J" lines (app playback only; the headless runner skips
//    comment lines).
// The file is a valid `platoon-headless --script` (FRAME up|down|left|right|fire|fire0 0|1, FRAME key HEX 0|1) with a
// commented header: build and disk tags, enhancements, start section / carry, trainer, key gap. Playback feeds the
// same edges at the same frames; key events are queued at their delivery frame, so with Input.keyGapFrames 0 (the app
// player) or with the recording's own gap (>= 2, the headless default) they are delivered at the same line.

public struct ReplayHeader: Equatable {
    public static let magic = "# PLATOON INPUT REPLAY 1"
    public var buildTag = GameSnapshot.buildTag
    public var adfTag: UInt64 = 0
    public var startSection: Int?
    public var carry: [UInt8]?
    /// Enhancement options that differed from the defaults ("key=value"), as passed at game start.
    public var enhancements: [String] = []
    /// LEGACY host trainer switches ("ammo,morale,invulnerable" subset; empty = none): only replays recorded before the
    /// cheats existed have them (played back with the legacy Trainer). The cheats are enhancement options (`enh`).
    public var trainer: [String] = []
    /// Input.keyGapFrames while recording (2 = original pacing).
    public var keyGap = 2
    /// GameConfig.deterministicRNG of the recorded game (headless --deterministic; the app plays with false).
    public var deterministic = false
    /// Frames recorded (the run's length) and the score / section at the end.
    public var frames: UInt64 = 0
    public var score = 0
    public var created = Date()
    public var note = ""
    /// Host features whose effect is not in the input stream (e.g. "s1.directAim"): playback may diverge.
    public var warnings: [String] = []
    public init() {}
}

public struct InputReplay: Equatable {
    public struct Event: Equatable {
        public var frame: UInt64
        public enum Kind: Equatable { case up, down, left, right, fire, fire0, key(UInt8), jump, crouch }
        public var kind: Kind
        public var on: Bool
    }
    public var header = ReplayHeader()
    public var events: [Event] = []
    public init() {}

    // MARK: text format

    /// The replay as a headless script with a commented header.
    public func encoded() -> String {
        let h = header
        var s = ReplayHeader.magic + "\n"
        let iso = ISO8601DateFormatter()
        s += "# created \(iso.string(from: h.created))\n"
        s += "# build \(h.buildTag)\n"
        s += String(format: "# adf %016llx\n", h.adfTag)
        s += "# frames \(h.frames)\n"
        s += "# score \(h.score)\n"
        if let ss = h.startSection { s += "# startSection \(ss)\n" }
        if let c = h.carry { s += "# carry \(c.map { String(format: "%02x", $0) }.joined())\n" }
        if !h.enhancements.isEmpty { s += "# enh \(h.enhancements.joined(separator: ","))\n" }
        if !h.trainer.isEmpty { s += "# trainer \(h.trainer.joined(separator: ","))\n" }
        s += "# keyGap \(h.keyGap)\n"
        if h.deterministic { s += "# deterministic 1\n" }
        for w in h.warnings { s += "# warning \(w)\n" }
        if !h.note.isEmpty { s += "# note \(h.note.replacingOccurrences(of: "\n", with: " "))\n" }
        s += "# headless: \(headlessCommand(adf: "ADF", script: "THIS_FILE"))\n"
        for e in events {
            switch e.kind {
            case .up: s += "\(e.frame) up \(e.on ? 1 : 0)\n"
            case .down: s += "\(e.frame) down \(e.on ? 1 : 0)\n"
            case .left: s += "\(e.frame) left \(e.on ? 1 : 0)\n"
            case .right: s += "\(e.frame) right \(e.on ? 1 : 0)\n"
            case .fire: s += "\(e.frame) fire \(e.on ? 1 : 0)\n"
            case .fire0: s += "\(e.frame) fire0 \(e.on ? 1 : 0)\n"
            case .key(let k): s += String(format: "%llu key 0x%02x %d\n", e.frame, k, e.on ? 1 : 0)
            case .jump: s += "#J \(e.frame) jump \(e.on ? 1 : 0)\n"
            case .crouch: s += "#J \(e.frame) crouch \(e.on ? 1 : 0)\n"
            }
        }
        return s
    }

    public enum ParseError: Error, CustomStringConvertible {
        case notAReplay, badLine(Int, String)
        public var description: String {
            switch self {
            case .notAReplay: return "This is not a Platoon input replay."
            case .badLine(let n, let l): return "Line \(n) of the replay can't be read: \(l)"
            }
        }
    }

    /// Parses a replay file. Plain headless scripts (no header) are accepted too (no poke/shot commands).
    public static func decode(_ text: String) throws -> InputReplay {
        var r = InputReplay()
        var sawAny = false
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#J ") {
                let p = line.dropFirst(3).split(separator: " ").map(String.init)
                guard p.count == 3, let f = UInt64(p[0]) else { throw ParseError.badLine(n + 1, line) }
                r.events.append(Event(frame: f, kind: p[1] == "jump" ? .jump : .crouch, on: p[2] != "0"))
                continue
            }
            if line.hasPrefix("#") {
                let p = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard let sp = p.firstIndex(of: " ") else { continue }
                let k = String(p[..<sp]), v = String(p[p.index(after: sp)...])
                switch k {
                case "created": r.header.created = ISO8601DateFormatter().date(from: v) ?? Date()
                case "build": r.header.buildTag = v
                case "adf": r.header.adfTag = UInt64(v, radix: 16) ?? 0
                case "frames": r.header.frames = UInt64(v) ?? 0
                case "score": r.header.score = Int(v) ?? 0
                case "startSection": r.header.startSection = Int(v)
                case "carry":
                    var b: [UInt8] = []; var i = v.startIndex
                    while let j = v.index(i, offsetBy: 2, limitedBy: v.endIndex), i < v.endIndex {
                        if let x = UInt8(v[i..<j], radix: 16) { b.append(x) }; i = j
                    }
                    r.header.carry = b
                case "enh": r.header.enhancements = v.split(separator: ",").map(String.init)
                case "trainer": r.header.trainer = v.split(separator: ",").map(String.init)
                case "keyGap": r.header.keyGap = Int(v) ?? 2
                case "deterministic": r.header.deterministic = v != "0"
                case "warning": r.header.warnings.append(v)
                case "note": r.header.note = v
                default: break
                }
                continue
            }
            let p = line.split(separator: " ").map(String.init)
            guard p.count >= 2, let f = UInt64(p[0]) else { throw ParseError.badLine(n + 1, line) }
            let on = (p.count > 2 ? p[2] : "1") != "0"
            let kind: Event.Kind
            switch p[1] {
            case "up": kind = .up
            case "down": kind = .down
            case "left": kind = .left
            case "right": kind = .right
            case "fire": kind = .fire
            case "fire0": kind = .fire0
            case "key":
                guard p.count >= 3, let c = UInt8(p[2].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
                    throw ParseError.badLine(n + 1, line)
                }
                r.events.append(Event(frame: f, kind: .key(c), on: (p.count > 3 ? p[3] : "1") != "0"))
                sawAny = true
                continue
            case "quit", "shot", "dump", "dumpr": continue
            default: throw ParseError.badLine(n + 1, line)   // pokes etc. are not replays
            }
            r.events.append(Event(frame: f, kind: kind, on: on))
            sawAny = true
        }
        guard sawAny || text.hasPrefix(ReplayHeader.magic) else { throw ParseError.notAReplay }
        r.events.sort { $0.frame < $1.frame }         // stable: keeps the recorded order within a frame
        if r.header.frames == 0 { r.header.frames = (r.events.last?.frame ?? 0) + 1 }
        return r
    }

    /// The platoon-headless command line that plays the replay (carry via PLATOON_CARRY, see the header).
    public func headlessCommand(adf: String, script: String) -> String {
        var c = "platoon-headless --adf \(adf) --script \(script) --frames \(header.frames)"
        if let s = header.startSection { c += " --start-section \(s)" }
        if header.deterministic { c += " --deterministic" }
        if !header.enhancements.isEmpty { c += " --enh \(header.enhancements.joined(separator: ","))" }
        if !header.trainer.isEmpty { c += " --trainer \(header.trainer.joined(separator: ","))" }
        if header.carry != nil { c = "PLATOON_CARRY=<carry file> " + c }
        if header.keyGap != 2 { c += "   (recorded with key gap \(header.keyGap); keys closer than 3 frames need the same gap)" }
        return c
    }

    /// Smallest distance in frames between two key deliveries (nil = fewer than two keys). Playback with the original
    /// key pacing (Input.keyGapFrames 2, the headless default) reproduces the deliveries when it is >= 3.
    public var minKeySpacing: UInt64? {
        var last: UInt64?, best: UInt64?
        for e in events { if case .key = e.kind { if let l = last { best = min(best ?? .max, e.frame - l) }; last = e.frame } }
        return best
    }

    /// The carry block as a file (for PLATOON_CARRY in headless playback).
    public var carryData: Data? { header.carry.map { Data($0) } }
}

/// Records the input of a running Machine. Call `observe` at the start of every emulated frame (frameHook).
public final class InputRecorder {
    /// Start recording on `machine`; `valid` is false when the machine already ran frames (not from power-on or a
    /// start section): such a recording can't be played back from its beginning.
    public init(machine: Machine) {
        startFrame = machine.frameCount
        lastSDR = machine.chip.ciaA.sdr
        valid = machine.frameCount == 0
    }

    public let startFrame: UInt64
    public private(set) var valid: Bool
    public private(set) var events: [InputReplay.Event] = []
    public private(set) var lastFrame: UInt64 = 0
    /// Why the recording stopped being a faithful replay (e.g. a savestate was loaded).
    public private(set) var brokenReason: String?

    private var joy = (up: false, down: false, left: false, right: false, fire: false, fire0: false)
    private var host = (jump: false, crouch: false)
    private var lastSDR: UInt8

    public func invalidate(_ reason: String) { if brokenReason == nil { brokenReason = reason } }

    public func observe(_ m: Machine) {
        let f = m.frameCount
        lastFrame = f
        // keys delivered during the previous frame
        let sdr = m.chip.ciaA.sdr
        if sdr != lastSDR {
            lastSDR = sdr
            let raw = ~sdr
            events.append(.init(frame: f &- 1, kind: .key(raw >> 1), on: raw & 1 == 0))
        }
        let i = m.input
        func edge(_ now: Bool, _ was: inout Bool, _ k: InputReplay.Event.Kind) {
            if now != was { was = now; events.append(.init(frame: f, kind: k, on: now)) }
        }
        edge(i.up, &joy.up, .up); edge(i.down, &joy.down, .down)
        edge(i.left, &joy.left, .left); edge(i.right, &joy.right, .right)
        edge(i.fire, &joy.fire, .fire); edge(i.fire0, &joy.fire0, .fire0)
        if let b = Section0HostButtons.existing(m) {
            edge(b.jump, &host.jump, .jump); edge(b.crouch, &host.crouch, .crouch)
        }
    }

    /// The replay recorded so far.
    public func replay(header h: ReplayHeader) -> InputReplay {
        var r = InputReplay()
        r.header = h
        r.header.frames = lastFrame &+ 1
        r.events = events.sorted { $0.frame < $1.frame }
        return r
    }
}

/// Plays a replay into a Machine. Call `apply` at the start of every emulated frame (frameHook), AFTER anything else
/// that writes Input (the host's own input layer must be muted meanwhile).
public final class InputPlayer {
    public init(_ replay: InputReplay) {
        self.replay = replay
        events = replay.events
    }
    public let replay: InputReplay
    private let events: [InputReplay.Event]
    private var next = 0
    private var joy = (up: false, down: false, left: false, right: false, fire: false, fire0: false)
    private var host = (jump: false, crouch: false)

    /// All events played and the recorded length reached.
    public private(set) var finished = false
    public var progress: Double { replay.header.frames == 0 ? 1 : min(1, Double(lastFrame) / Double(replay.header.frames)) }
    private var lastFrame: UInt64 = 0

    public func apply(_ m: Machine) {
        let f = m.frameCount
        lastFrame = f
        while next < events.count && events[next].frame <= f {
            let e = events[next]; next += 1
            switch e.kind {
            case .up: joy.up = e.on
            case .down: joy.down = e.on
            case .left: joy.left = e.on
            case .right: joy.right = e.on
            case .fire: joy.fire = e.on
            case .fire0: joy.fire0 = e.on
            case .key(let k): m.input.key(k, down: e.on)
            case .jump: host.jump = e.on
            case .crouch: host.crouch = e.on
            }
        }
        let i = m.input
        i.up = joy.up; i.down = joy.down; i.left = joy.left; i.right = joy.right; i.fire = joy.fire; i.fire0 = joy.fire0
        if host.jump || host.crouch || Section0HostButtons.existing(m) != nil {
            let b = Section0HostButtons.of(m)
            if b.jump != host.jump { b.jump = host.jump }
            if b.crouch != host.crouch { b.crouch = host.crouch }
        }
        if next >= events.count && f + 1 >= replay.header.frames { finished = true }
    }
}


extension PlatoonGame {
    /// Start configuration of the game running on `m` (start section, carry, enhancements as passed by the host),
    /// nil before the game thread has set it up (the first frame). Host thread.
    public static func runConfiguration(_ m: Machine) -> (startSection: Int?, carry: [UInt8]?, enhancements: Enhancements,
                                                          deterministic: Bool)? {
        guard let p = platoon(for: m) else { return nil }
        return (p.config.startSection, p.config.carry, p.config.enhancements, p.config.deterministicRNG)
    }
}
