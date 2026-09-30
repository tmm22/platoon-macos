import Foundation

/// Host-side configuration of a game run.
public struct GameConfig {
    public init() {}
    /// Skip the title: start a new game directly in load section 0/1/2 (as if fire was pressed on the
    /// title with $6e(a6) = N). Used by the headless verifier and by "continue from section".
    public var startSection: Int?
    /// Carry-over state for startSection (score, morale, men) — nil = new-game values.
    public var carry: [UInt8]?
    /// Drop the unreproducible "interrupted d1" term from the vblank RNG update (pair with emu --deterministic).
    public var deterministicRNG = false
    /// Called (on the game thread) when a load section starts: (section index 0/1/2, a6 globals block $76 bytes).
    /// The app uses it to offer "continue from this section" with `carry`.
    public var onSectionStart: ((Int, [UInt8]) -> Void)?
    /// Where hiscores are persisted (nil = keep in memory only). Assisted runs use hiscores-<mode>.bin next to it
    /// (Enhance/Hiscores.swift).
    public var hiscoreURL: URL?
    /// Tick dumps: when translated code passes `tickPoint(pc)`, append [u32 frame][len bytes at lo] to the file.
    public var tickDumps: [(pc: UInt32, lo: UInt32, len: Int, file: FileHandle)] = []
    /// Enhancement switches for this run (copied into Platoon.enhancements at start, difficulty preset resolved).
    public var enhancements = Enhancements()
    /// F1/F2 probe (context + event observers + markAssisted); nil = none (zero cost).
    public var probe: GameProbe?
    /// F4/S5: host-declared reasons that make every game of this session assisted (e.g. "rewind enabled").
    public var assistedReasons: Set<String> = []
}

/// Entry point of the translated game.
public enum PlatoonGame {
    /// Runs the whole game on the machine's game thread (never returns in normal play).
    public static func main(_ m: Machine, config: GameConfig = GameConfig()) {
        let p = prepare(m, config: config)
        p.boot()
    }

    /// Creates and sets up the Platoon for a run on `m` (game thread): config, enhancements (+ PLATOON_* environment
    /// overrides, difficulty preset resolved), session assist reasons (F4), machine lookup, probe (F1/F2).
    /// Shared by `main` and snapshot resume; after a resume call `p.probeResumed()`.
    static func prepare(_ m: Machine, config: GameConfig) -> Platoon {
        let p = Platoon(machine: m)
        p.config = config
        p.enhancements = config.enhancements
        p.applyEnvironmentOverrides()
        // cheats taint per game (they can be switched live): marked for the current game here and at every
        // new game (beginRun) while they are on, not for the whole session
        p.sessionAssist = p.enhancements.assistReasons.subtracting(p.enhancements.cheatAssistReasons)
            .union(p.config.assistedReasons)
        p.runAssist = p.enhancements.cheatAssistReasons
        p.enhancements = p.enhancements.resolved()
        attach(p, to: m)
        p.probeAttach()
        return p
    }

    // MARK: machine -> running game lookup (host features that only hold the Machine, e.g. Trainer)

    private static let attachLock = NSLock()
    private final class WeakPlatoon { weak var p: Platoon?; init(_ p: Platoon) { self.p = p } }
    private static var attached: [ObjectIdentifier: WeakPlatoon] = [:]

    static func attach(_ p: Platoon, to m: Machine) {
        attachLock.lock(); defer { attachLock.unlock() }
        attached = attached.filter { $0.value.p != nil }
        attached[ObjectIdentifier(m)] = WeakPlatoon(p)
    }

    static func platoon(for m: Machine) -> Platoon? {
        attachLock.lock(); defer { attachLock.unlock() }
        return attached[ObjectIdentifier(m)]?.p
    }

    /// F4/S5: marks the game running on `m` as assisted (its score goes to the assisted hiscore table).
    /// Safe from the host thread; cleared when the next new game starts.
    public static func markAssisted(_ m: Machine, _ reason: String) {
        platoon(for: m)?.markAssisted(reason)
    }

    /// F4/S5: the assist reasons of the game running on `m` (empty = original run).
    public static func assistReasons(_ m: Machine) -> Set<String> {
        platoon(for: m)?.currentAssistReasons() ?? []
    }

    /// The enhancements in effect for the game running on `m` (preset resolved), nil before it started.
    public static func enhancements(_ m: Machine) -> Enhancements? { platoon(for: m)?.enhancements }

    /// Cheats: the cheat switches in effect for the game running on `m`, nil before it started.
    public static func cheats(_ m: Machine) -> CheatOptions? { platoon(for: m)?.enhancements.cheats }

    /// Cheats: switches the cheats of the game running on `m` (live; call it from Machine.frameHook, where the game
    /// thread is parked). Cheats switched on mark the current game assisted; the original-cheats switch writes the
    /// same RAM as typing the codes on the title (and undoes it when switched off). Returns false before the game
    /// started.
    @discardableResult public static func setCheats(_ m: Machine, _ c: CheatOptions) -> Bool {
        guard let p = platoon(for: m) else { return false }
        p.cheatsSetLive(c)
        return true
    }
}

extension Platoon {
    /// Verification overrides from the environment (used with platoon-headless):
    ///   PLATOON_ENH="originalCredits=0,s0.bridgeFailsafe=1,..."  enhancement registry key=value list
    ///   PLATOON_HISCORES=/path/file                           config.hiscoreURL (persisted hiscore track)
    ///   PLATOON_CARRY=/path/file                              config.carry (a6 block image, $76 bytes)
    ///   PLATOON_EVENTS=/path/file                             attach a GameProbe that logs every F2 event (and
    ///                                                         F1 screen changes) to the file ("-" = stdout)
    func applyEnvironmentOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let e = env["PLATOON_ENH"] {
            do { try enhancements.apply(e) } catch { FileHandle.standardError.write("PLATOON_ENH: \(error)\n".data(using: .utf8)!) }
        }
        if config.hiscoreURL == nil, let h = env["PLATOON_HISCORES"] { config.hiscoreURL = URL(fileURLWithPath: h) }
        if config.carry == nil, let c = env["PLATOON_CARRY"], let d = FileManager.default.contents(atPath: c) { config.carry = [UInt8](d) }
        if config.probe == nil, let path = env["PLATOON_EVENTS"] {
            let probe = GameProbe()
            let out: FileHandle?
            if path == "-" { out = FileHandle.standardOutput } else {
                FileManager.default.createFile(atPath: path, contents: nil); out = FileHandle(forWritingAtPath: path)
            }
            probe.log = { line in out?.write((line + "\n").data(using: .utf8)!) }
            config.probe = probe
        }
    }

    /// Debug: PLATOON_TRACE=1 prints every tickPoint with frame/line (same format as the emulator's --bp log).
    static let traceTicks = ProcessInfo.processInfo.environment["PLATOON_TRACE"] != nil

    /// Marks the point in a translated routine that corresponds to original code address `pc`
    /// (typically the head of a main loop). Used for tick-by-tick lockstep comparison with the emulator.
    func tickPoint(_ pc: UInt32) {
        if Platoon.traceTicks {
            print(String(format: "[f%d v%03d] BP %06x", m.frameCount, m.beamLine + cpuCycles / Platoon.cyclesPerLine, pc))
        }
        for t in config.tickDumps where t.pc == pc {
            var d = Data(capacity: 4 + t.len)
            var fr = UInt32(truncatingIfNeeded: m.frameCount).littleEndian
            d.append(Data(bytes: &fr, count: 4))
            d.append(contentsOf: mem.slice(t.lo, t.len))
            t.file.write(d)
        }
        if config.probe != nil { probeTick(pc) }
    }
}
