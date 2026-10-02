import Foundation

// M11 practice mode (owner: assist): drills for the hard parts without replaying 10+ minutes.
//
// Improvement over the roadmap's phase 1 (RAM patches after a section load + a game-over redirect in translated
// code): every drill starting point is a loop-head SNAPSHOT (F5/L1) made at runtime by running the verified,
// deterministic input scripts of port/verify in an off-screen Machine (a few seconds; the result is cached). No game
// code is patched and no RAM images are shipped; the app restores the snapshot through the save-state path (marked
// assisted, never in the original hiscore table) and restores it again for every retry. Death / game-over retries
// and the goal check are host observers.
//
// Drill starts: the three section starts (config.startSection), before the bridge with the explosives, the village
// street, the flare night (the tunnel cheat route of the verification scripts, with the cheat flags cleared and 8
// flares), and Barnes' bunker.

public struct PracticeDrill: Equatable {
    public enum Goal: String, Equatable {
        /// Bridge blown ($60c9c == 2).
        case bridge
        /// Down the trap door (section 0 ends).
        case trapDoor
        /// Tunnel exit found (flare night reached).
        case tunnelExit
        /// The flare night survived (section 1 ends).
        case dawn
        /// The bunker room reached.
        case bunker
        /// The game won ("YOU MADE IT!").
        case huey
    }
    enum Start: Equatable {
        /// config.startSection = N; snapshot at the first loop head.
        case section(Int)
        /// Run `script` (headless format) from power-on (optionally with a start section) and take the snapshot at the
        /// first loop head at or after `frame` in `loop` (nil = any).
        case script(name: String, startSection: Int?, frame: Int, loop: SnapshotLoop?)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let section: Int
    let start: Start
    public let goal: Goal
    /// RAM written into the snapshot: undoes what the verification scripts used to get there quickly (the jungle
    /// route's invincibility poke $60ca0, the tunnel cheat's flags $70(a6)) and sets the flare count.
    let fixups: [(addr: UInt32, bytes: [UInt8])]
    /// Heal the living men (the scripted routes arrive with a badly wounded soldier: one more hit would end the
    /// drill at once) and blank the HUD wound splats to match.
    var heal = false

    public static func == (a: PracticeDrill, b: PracticeDrill) -> Bool { a.id == b.id }

    public var goalText: String {
        switch goal {
        case .bridge: return "Blow up the bridge"
        case .trapDoor: return "Go down the trap door"
        case .tunnelExit: return "Find the tunnel exit"
        case .dawn: return "Survive until dawn"
        case .bunker: return "Reach the bunker"
        case .huey: return "Kill Barnes and reach the bunker door"
        }
    }
}

public enum PracticeDrills {
    public static let all: [PracticeDrill] = [
        PracticeDrill(id: "jungle", title: "The Jungle", detail: "From the start of the game.", section: 0,
                      start: .section(0), goal: .bridge, fixups: []),
        PracticeDrill(id: "bridge", title: "The Bridge", detail: "Deep in the jungle with the explosives: get them to the bridge.",
                      section: 0, start: .script(name: "s0", startSection: 0, frame: PracticeScripts.s0BridgeFrame, loop: .jungle),
                      goal: .bridge, fixups: noInvincibility, heal: true),
        PracticeDrill(id: "village", title: "The Village", detail: "On the village street: torch, map, trap door.",
                      section: 0, start: .script(name: "s0", startSection: 0, frame: PracticeScripts.s0VillageFrame, loop: .jungle),
                      goal: .trapDoor, fixups: noInvincibility, heal: true),
        PracticeDrill(id: "tunnels", title: "The Tunnels", detail: "From the tunnel entrance.", section: 1,
                      start: .section(1), goal: .tunnelExit, fixups: []),
        PracticeDrill(id: "flare", title: "The Flare Night", detail: "In the foxhole with 8 flares.", section: 1,
                      start: .script(name: "s1flare", startSection: nil, frame: PracticeScripts.s1FlareFrame, loop: .flare),
                      goal: .dawn, fixups: [(Platoon.a6 + 0x70, [0, 0]), (Platoon.a6 + 0x2c, [0, 8])]),
        PracticeDrill(id: "final", title: "The Final Jungle", detail: "From the start of the final jungle.", section: 2,
                      start: .section(2), goal: .bunker, fixups: []),
        PracticeDrill(id: "barnes", title: "Sgt Barnes", detail: "At the bunker.", section: 2,
                      start: .script(name: "s2", startSection: nil, frame: PracticeScripts.s2BunkerFrame, loop: .finalJungle),
                      goal: .huey, fixups: [], heal: true),
    ]
    /// Section 0 scripts walk with the invincibility poke (cheat F5 without the cheat flag): clear it.
    static let noInvincibility: [(addr: UInt32, bytes: [UInt8])] = [(0x60ca0, [0, 0])]

    public static func drill(_ id: String) -> PracticeDrill? { all.first { $0.id == id } }

    public enum Failure: Error, CustomStringConvertible {
        case noSnapshot(String)
        public var description: String {
            switch self { case .noSnapshot(let d): return "The drill start could not be prepared (\(d))." }
        }
    }

    /// Builds the drill's starting snapshot by running its script in an off-screen Machine (deterministic RNG, as
    /// the verification runs). Any thread; `progress` 0...1. Typically 1-10 s.
    public static func prepare(_ d: PracticeDrill, disk: Disk, progress: ((Double) -> Void)? = nil) throws -> GameSnapshot {
        let m = Machine(disk: disk)
        var cfg = GameConfig()
        cfg.deterministicRNG = true
        cfg.enhancements.kernel.originalCredits = false          // exactly the verification runs' configuration
        cfg.enhancements.kernel.referenceEmulator = true         // (the routes are timed for tools/amiga/emu; the drill
                                                                 // then resumes with the player's timing)
        var events: [(Int, [String])] = []
        let target: Int
        var loop: SnapshotLoop?
        switch d.start {
        case .section(let s):
            cfg.startSection = s; target = 0
            // the section's intro text screen waits for fire: tap it (1 frame in 100) until play starts
            events = stride(from: 150, to: 3000, by: 100).flatMap { [($0, ["fire", "1"]), ($0 + 2, ["fire", "0"])] }
        case .script(let name, let ss, let frame, let l):
            cfg.startSection = ss; target = frame; loop = l
            events = PracticeScripts.events(PracticeScripts.script(name))
        }
        let sc = SnapshotController()
        sc.attach(m)
        m.start { PlatoonGame.main($0, config: cfg) }
        var snap: GameSnapshot?
        var requested = false
        var ei = 0
        let limit = target + 3000
        var f = 0
        while f < limit && snap == nil {
            while ei < events.count && events[ei].0 <= f { apply(events[ei].1, to: m); ei += 1 }
            if !requested && f >= target {
                requested = true
                sc.requestSnapshot(label: d.title) { s in snap = s }
            }
            m.runFrame()
            sc.drain()
            if let s = snap, let l = loop, s.info.loop != l {        // not the loop we want yet: ask again
                snap = nil; requested = false
            }
            f += 1
            if f % 500 == 0 { progress?(Double(f) / Double(max(1, target))) }
            if m.gameFinished { break }
        }
        m.stop()
        guard var s = snap else { throw Failure.noSnapshot("no loop head reached by frame \(f)") }
        for (a, b) in d.fixups { for (i, v) in b.enumerated() { s.machine.memory[Int(a) + i] = v } }
        if d.heal { heal(&s.machine.memory) }
        s.info.label = d.title
        s.info.assisted = true
        progress?(1)
        return s
    }

    /// Sets every living man's wounds (a6 + 6*i + 4, 4 = dead) to 0 and clears the 4 HUD wound slots that
    /// k_hud_wounds ($10656) draws at $797c0 + 4k (3x3 cells of 8 lines, 4 planes $2000 apart, rows $28 bytes).
    static func heal(_ mem: inout [UInt8]) {
        for i in 0..<5 {
            let w = Int(Platoon.a6) + 6 * i + 4
            if mem[w] == 0 && mem[w + 1] < 4 { mem[w + 1] = 0 }
        }
        for k in 0..<4 {
            let base = 0x797c0 + 4 * k
            for br in 0..<3 { for c in 0..<3 { for y in 0..<8 { for p in 0..<4 {
                mem[base + br * 0x140 + c + y * 0x28 + p * 0x2000] = 0
            } } } }
        }
    }

    static func apply(_ p: [String], to m: Machine) {
        guard let cmd = p.first else { return }
        let on = (p.count > 1 ? p[1] : "1") != "0"
        switch cmd {
        case "up": m.input.up = on
        case "down": m.input.down = on
        case "left": m.input.left = on
        case "right": m.input.right = on
        case "fire": m.input.fire = on
        case "fire0": m.input.fire0 = on
        case "key":
            if p.count > 1, let c = UInt8(p[1].replacingOccurrences(of: "0x", with: ""), radix: 16) {
                m.input.key(c, down: (p.count > 2 ? p[2] : "1") != "0")
            }
        case "poke":
            if p.count >= 3, let a = UInt32(p[1], radix: 16), let v = UInt32(p[2], radix: 16) {
                switch Int(p.count > 3 ? p[3] : "1") ?? 1 {
                case 1: m.memory.w8(a, UInt8(truncatingIfNeeded: v))
                case 2: m.memory.w16(a, UInt16(truncatingIfNeeded: v))
                default: m.memory.w32(a, v)
                }
            }
        default: break
        }
    }

    /// Is the drill's goal reached (context of this frame, or an event)?
    public static func goalReached(_ g: PracticeDrill.Goal, context c: GameContext, event: GameEvent?) -> Bool {
        switch g {
        case .bridge: return c.section == 0 && c.jungle?.bridge == 2
        case .trapDoor: if case .sectionEnd(0)? = event { return true }; return false
        case .tunnelExit: return c.section == 1 && c.area == .flare
        case .dawn: if case .sectionEnd(1)? = event { return true }; return false
        case .bunker: return c.section == 2 && c.area == .bunker
        case .huey: if case .textScreen(let t)? = event { return RunTimer.isWinText(t) }; return false
        }
    }
}
