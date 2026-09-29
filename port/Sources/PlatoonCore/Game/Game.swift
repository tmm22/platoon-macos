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
    /// Where hiscores are persisted (nil = keep in memory only).
    public var hiscoreURL: URL?
    /// Tick dumps: when translated code passes `tickPoint(pc)`, append [u32 frame][len bytes at lo] to the file.
    public var tickDumps: [(pc: UInt32, lo: UInt32, len: Int, file: FileHandle)] = []
    /// Enhancement switches for this run (copied into Platoon.enhancements at start).
    public var enhancements = Enhancements()
}

/// Entry point of the translated game.
public enum PlatoonGame {
    /// Runs the whole game on the machine's game thread (never returns in normal play).
    public static func main(_ m: Machine, config: GameConfig = GameConfig()) {
        let p = Platoon(machine: m)
        p.config = config
        p.enhancements = config.enhancements
        p.applyEnvironmentOverrides()
        p.boot()
    }
}

extension Platoon {
    /// Verification overrides from the environment (used with platoon-headless, whose command line has no
    /// options for these):
    ///   PLATOON_ENH="originalCredits=0,infiniteAmmo=1,..."  enhancement switches
    ///   PLATOON_HISCORES=/path/file                          config.hiscoreURL (persisted hiscore track)
    ///   PLATOON_CARRY=/path/file                             config.carry (a6 block image, $76 bytes)
    func applyEnvironmentOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let e = env["PLATOON_ENH"] {
            for item in e.split(separator: ",") {
                let kv = item.split(separator: "="), on = kv.count < 2 || kv[1] != "0"
                switch kv.first.map(String.init) ?? "" {
                case "originalCredits": enhancements.originalCredits = on
                case "infiniteAmmo": enhancements.infiniteAmmo = on
                case "infiniteMorale": enhancements.infiniteMorale = on
                default: break
                }
            }
        }
        if config.hiscoreURL == nil, let h = env["PLATOON_HISCORES"] { config.hiscoreURL = URL(fileURLWithPath: h) }
        if config.carry == nil, let c = env["PLATOON_CARRY"], let d = FileManager.default.contents(atPath: c) { config.carry = [UInt8](d) }
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
    }
}
