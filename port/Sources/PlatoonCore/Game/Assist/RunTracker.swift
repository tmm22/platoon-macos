import Foundation

// M16 speedrun timer with splits + the local "Service Record" (stats and medals) (owner: assist).
// Observer only: fed from the F1 context every emulated frame and from the F2 events; nothing here writes the game.
//
// Timer: emulated frames of the run (from the new-game event to the win / game over), without the frames the TAB
// pause is active ($10eaa != 0). Host pauses don't run frames at all; fast-forward runs the same frames, so the
// time is the in-game time at 50 Hz whatever the host does.
// Splits: explosives, bridge, village, torch, map, trap door, 8 flares, tunnel exit, dawn, bunker, Barnes, the Huey.

/// One split point of a run.
public struct RunSplit: Codable, Equatable {
    public var id: String
    public var name: String
    /// Run time (frames) when it was reached.
    public var frames: Int
}

public enum RunSplits {
    /// All split points in route order (id, name).
    public static let all: [(id: String, name: String)] = [
        ("s0.explosives", "Explosives"), ("s0.bridge", "Bridge"), ("s0.village", "Village"), ("s0.torch", "Torch"),
        ("s0.map", "Map"), ("s0.trapdoor", "Trap door"),
        ("s1.flares", "8 flares"), ("s1.exit", "Tunnel exit"), ("s1.dawn", "Dawn"),
        ("s2.bunker", "Bunker"), ("s2.barnes", "Barnes"), ("s2.huey", "Huey"),
    ]
    public static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
    public static func order(_ id: String) -> Int { all.firstIndex { $0.id == id } ?? 99 }

    /// "m:ss.cc" from PAL frames.
    public static func clock(_ frames: Int, hundredths: Bool = true) -> String {
        let cs = frames * 2                        // 1 frame = 2/100 s
        let s = cs / 100, m = s / 60
        return hundredths ? String(format: "%d:%02d.%02d", m, s % 60, cs % 100) : String(format: "%d:%02d", m, s % 60)
    }
    /// "+1.24" / "-0.80" from a frame delta.
    public static func delta(_ frames: Int) -> String {
        let cs = abs(frames) * 2
        let sign = frames > 0 ? "+" : frames < 0 ? "-" : "±"
        return cs >= 6000 ? "\(sign)\(clock(abs(frames), hundredths: false))" : String(format: "%@%d.%02d", sign, cs / 100, cs % 100)
    }
}

/// The speedrun timer of the current run.
public final class RunTimer {
    public init() {}

    public enum Status: String, Codable { case idle, running, won, ended }
    public private(set) var status: Status = .idle
    /// Counted run time in frames.
    public private(set) var frames = 0
    public private(set) var splits: [RunSplit] = []
    /// Load section the run started in (0 = a full run).
    public private(set) var startSection = 0
    /// Hiscore table / category of the run as of the last frame ("original", "recruit", ..., "assisted").
    public private(set) var mode = "original"
    /// Called when a split is reached / the run finishes (won = true for the Huey ending).
    public var onSplit: ((RunSplit) -> Void)?
    public var onFinish: ((_ won: Bool) -> Void)?

    private var seen = Set<String>()
    private var barnesSeenAlive = false

    /// Category key for personal bests: mode, plus the start section for runs that didn't start in the jungle.
    public var category: String { startSection == 0 ? mode : "\(mode)@\(startSection)" }

    public func reset() {
        status = .idle; frames = 0; splits = []; seen = []; barnesSeenAlive = false; startSection = 0
    }

    /// Every emulated frame (context of this frame).
    public func frame(_ c: GameContext) {
        guard status == .running else { return }
        mode = c.hiscoreMode
        if c.inGame && !c.paused { frames += 1 }
        guard c.inGame, let s = c.section else { return }
        switch s {
        case 0:
            if let j = c.jungle {
                if c.explosives || j.bridge != 0 { split("s0.explosives") }
                if j.bridge == 2 { split("s0.bridge") }
                if j.torch { split("s0.torch") }
            }
            if c.area == .village || c.area == .hut { split("s0.village") }
            if c.map { split("s0.map") }
        case 1:
            if c.area == .tunnels && c.flares >= 8 { split("s1.flares") }
            if c.area == .flare { split("s1.exit") }
        case 2:
            if c.area == .bunker, let f = c.finalJungle {
                split("s2.bunker")
                if f.barnesHP > 0 { barnesSeenAlive = true } else if barnesSeenAlive { split("s2.barnes") }
            }
        default: break
        }
    }

    /// F2 events.
    public func event(_ e: GameEvent) {
        switch e {
        case .newGame(let s):
            reset(); status = .running; startSection = s
        case .sectionEnd(let s):
            if status == .running { split(s == 0 ? "s0.trapdoor" : s == 1 ? "s1.dawn" : "s2.huey") }
        case .textScreen(let t):
            if status == .running && RunTimer.isWinText(t) { split("s2.huey"); finish(won: true) }
        case .gameOver, .aborted:
            if status == .running { finish(won: false) }
        default: break
        }
    }

    static func isWinText(_ t: String) -> Bool { t.uppercased().contains("YOU MADE IT") }

    private func split(_ id: String) {
        guard status == .running, !seen.contains(id) else { return }
        seen.insert(id)
        let sp = RunSplit(id: id, name: RunSplits.name(id), frames: frames)
        splits.append(sp)
        onSplit?(sp)
    }

    private func finish(won: Bool) {
        status = won ? .won : .ended
        onFinish?(won)
    }
}

/// Personal bests per category (persisted by the app as JSON).
public struct SpeedrunRecords: Codable, Equatable {
    public init() {}
    public struct Run: Codable, Equatable {
        public var frames: Int
        public var splits: [RunSplit]
        public var date: Date
    }
    /// Best completed run per category.
    public var best: [String: Run] = [:]
    /// Best segment (frames from the previous split) per category and split id ("gold splits").
    public var golds: [String: [String: Int]] = [:]

    /// Split time of the PB at `id` (for the live delta).
    public func pbSplit(_ category: String, _ id: String) -> Int? { best[category]?.splits.first { $0.id == id }?.frames }

    /// Records a finished run; returns true if it is a new PB. Gold segments are updated for any run.
    @discardableResult
    public mutating func record(category: String, frames: Int, splits: [RunSplit], won: Bool, date: Date = Date()) -> Bool {
        var prev = 0
        for s in splits.sorted(by: { $0.frames < $1.frames }) {
            let seg = s.frames - prev; prev = s.frames
            if let g = golds[category]?[s.id], g <= seg { continue }
            golds[category, default: [:]][s.id] = seg
        }
        guard won else { return false }
        if let b = best[category], b.frames <= frames { return false }
        best[category] = Run(frames: frames, splits: splits, date: date)
        return true
    }

    /// Plain-text splits table of a category (export / clipboard).
    public func text(_ category: String) -> String {
        guard let b = best[category] else { return "No completed run in category \(category)." }
        var s = "Platoon (Amiga 1988) - personal best, category \(category)\n"
        for sp in b.splits { s += "\(sp.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(RunSplits.clock(sp.frames))\n" }
        s += "Total        \(RunSplits.clock(b.frames))\n"
        return s
    }
}

// MARK: - Service Record

public struct Medal: Equatable {
    public var id: String, title: String, detail: String
}

public enum Medals {
    public static let all: [Medal] = [
        Medal(id: "complete", title: "Mission Complete", detail: "Finish the game: the Huey takes you back to the firebase."),
        Medal(id: "veteran", title: "Veteran", detail: "Finish the game on the Veteran difficulty."),
        Medal(id: "bandOfBrothers", title: "Band of Brothers", detail: "Go down the trap door with all five soldiers alive."),
        Medal(id: "tunnelRat", title: "Tunnel Rat", detail: "Find the tunnel exit without a map."),
        Medal(id: "nightOwl", title: "Night Owl", detail: "Survive the flare night without being hit."),
        Medal(id: "fiveForFive", title: "Five for Five", detail: "Kill Sgt Barnes without wasting a grenade."),
        Medal(id: "beatTheClock", title: "Beat the Clock", detail: "Finish the game with at least 1:00 left on the airstrike timer."),
        Medal(id: "nobodyLeftBehind", title: "Nobody Left Behind", detail: "Finish a full game without losing a soldier."),
        Medal(id: "scholar", title: "Scholar", detail: "Find a history book in the tunnels."),
        Medal(id: "dontDoIt", title: "Don't Do It", detail: "Be told not to attempt suicide."),
    ]
    public static func medal(_ id: String) -> Medal? { all.first { $0.id == id } }
}

/// Career statistics (persisted by the app as JSON).
public struct ServiceRecord: Codable, Equatable {
    public init() {}
    public var gamesStarted = 0
    public var gamesWon = 0
    public var gamesLost = 0
    /// In-game frames played (all runs).
    public var framesPlayed = 0
    public var soldiersLost = 0
    public var woundsTaken = 0
    public var enemiesKilled = 0
    /// Sections completed (index 0..2).
    public var sectionsCompleted = [0, 0, 0]
    /// Best score per hiscore mode.
    public var bestScore: [String: Int] = [:]
    /// Fastest win per mode (frames).
    public var fastestWin: [String: Int] = [:]
    /// Medal id -> date first earned.
    public var medals: [String: Date] = [:]
    /// Furthest section reached (-1 none).
    public var furthestSection = -1
}

/// Updates a ServiceRecord from the context and events of the running game.
public final class ServiceRecorder {
    public init(record: ServiceRecord = ServiceRecord()) { self.record = record }

    public var record: ServiceRecord
    /// A medal was earned for the first time.
    public var onMedal: ((Medal) -> Void)?
    /// The record changed (save it).
    public var onChange: (() -> Void)?

    private var inRun = false
    private var runStart = 0
    private var runFrames = 0
    private var runDeaths = 0
    private var runWon = false
    private var last = GameContext()
    private var flareClean: Bool?
    private var bunkerGrenades: (man: Int, count: Int, hits: Int)?
    private var lastTimer = 0
    private var dirty = false

    /// Medals count in unassisted runs and runs with a difficulty preset (not with assists, rewinds, practice ...).
    private var medalsAllowed: Bool { last.hiscoreMode != "assisted" }

    /// The game was replaced (reset, loaded save state): the current run ends without a result.
    public func abandonRun() { inRun = false }

    /// Every emulated frame.
    public func frame(_ c: GameContext) {
        defer { last = c }
        guard inRun, c.inGame else { return }
        if !c.paused { runFrames += 1; record.framesPlayed += 1; dirty = runFrames % 250 == 0 || dirty }
        guard let s = c.section else { return }
        if s > record.furthestSection { record.furthestSection = s; dirty = true }
        if s == 1 && c.area == .flare && flareClean == nil {
            flareClean = true
            if !c.map { earn("tunnelRat") }
        }
        if s == 2 {
            lastTimer = c.timerMinutes * 60 + c.timerSeconds
            if c.area == .bunker, let f = c.finalJungle, let man = c.man {
                if bunkerGrenades == nil, f.barnesHP > 0 {
                    bunkerGrenades = (c.currentMan, man.grenades, (f.barnesHP + 9) / 10)
                } else if let b = bunkerGrenades, b.man != c.currentMan {
                    bunkerGrenades = (c.currentMan, man.grenades, (f.barnesHP + 9) / 10)
                    if f.barnesHP == 0 { bunkerGrenades = nil }
                } else if let b = bunkerGrenades, f.barnesHP == 0, b.hits > 0 {
                    if b.count - man.grenades == b.hits { earn("fiveForFive") }
                    bunkerGrenades = (b.man, b.count, 0)       // decided
                }
            }
        }
        if dirty { dirty = false; onChange?() }
    }

    public func event(_ e: GameEvent) {
        switch e {
        case .newGame(let s):
            inRun = true; runStart = s; runFrames = 0; runDeaths = 0; runWon = false; flareClean = nil; bunkerGrenades = nil
            record.gamesStarted += 1; changed()
        case .death:
            guard inRun else { return }
            runDeaths += 1; record.soldiersLost += 1
            if last.area == .flare { flareClean = false }
            changed()
        case .wounded:
            guard inRun else { return }
            record.woundsTaken += 1
            if last.area == .flare { flareClean = false }
        case .score(let added, _):
            if inRun && added == 0x300 { record.enemiesKilled += 1 }
        case .message(let m):
            guard inRun else { return }
            let t = m.text.uppercased()
            if t.contains("ROMAN EMPIRE") { earn("scholar") }
            if t.contains("ATTEMPT SUICIDE") { earn("dontDoIt") }
        case .sectionEnd(let s):
            guard inRun, (0...2).contains(s) else { return }
            record.sectionsCompleted[s] += 1
            if s == 0 && last.men.count == 5 && last.men.allSatisfy({ $0.alive }) { earn("bandOfBrothers") }
            if s == 1 && flareClean == true { earn("nightOwl") }
            changed()
        case .textScreen(let t):
            guard inRun, !runWon, RunTimer.isWinText(t) else { return }
            won()
        case .gameOver(let score, _):
            guard inRun else { return }
            let mode = last.hiscoreMode, v = Platoon.bcdValue(score)
            if v > record.bestScore[mode] ?? -1 { record.bestScore[mode] = v }
            if !runWon { record.gamesLost += 1 }
            inRun = false; changed()
        case .aborted:
            if inRun { inRun = false; changed() }
        default: break
        }
    }

    private func won() {
        runWon = true
        record.gamesWon += 1
        let mode = last.hiscoreMode
        if runStart == 0, runFrames < record.fastestWin[mode] ?? Int.max { record.fastestWin[mode] = runFrames }
        earn("complete")
        if last.difficulty == .veteran { earn("veteran") }
        if lastTimer >= 60 { earn("beatTheClock") }
        if runStart == 0 && runDeaths == 0 { earn("nobodyLeftBehind") }
        changed()
    }

    private func earn(_ id: String) {
        guard medalsAllowed, record.medals[id] == nil, let m = Medals.medal(id) else { return }
        record.medals[id] = Date()
        onMedal?(m)
        changed()
    }

    private func changed() { onChange?() }
}
