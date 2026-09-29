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
    /// Where hiscores are persisted (nil = keep in memory only).
    public var hiscoreURL: URL?
    /// Tick dumps: when translated code passes `tickPoint(pc)`, append [u32 frame][len bytes at lo] to the file.
    public var tickDumps: [(pc: UInt32, lo: UInt32, len: Int, file: FileHandle)] = []
}

/// Entry point of the translated game.
public enum PlatoonGame {
    /// Runs the whole game on the machine's game thread (never returns in normal play).
    public static func main(_ m: Machine, config: GameConfig = GameConfig()) {
        let p = Platoon(machine: m)
        p.config = config
        p.boot()
    }
}

extension Platoon {
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
