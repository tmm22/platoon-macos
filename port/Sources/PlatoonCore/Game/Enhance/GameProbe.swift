import Foundation

// F1 context probe + F2 game-event observers + F4 assisted-run marking (owner: core).
//
// Usage (host):
//   let probe = GameProbe()
//   probe.onMessage { m in log.append(m.text) }              // observers run on the HOST thread, inside
//   probe.onFx { id, on in rumble(id) }                      // Machine.frameHook (game thread parked)
//   var cfg = GameConfig(); cfg.probe = probe
//   machine.start { PlatoonGame.main($0, config: cfg) }      // the game chains probe.poll into machine.frameHook
//   ... probe.context.screen == .nameEntry ...               // F1 snapshot, refreshed every frame
//   probe.markAssisted("rewind")                             // F4: this run must not enter the original table
//
// The translated game records events on the game thread at the original choke points (k_queue_text $1070c before
// the 4-message drop, k_fx $10c50 before the FX-off return, k_add_score $10638, k_section_start, k_next_section,
// k_game_over, name entry, F10) into a locked buffer; `poll` (frameHook) refreshes the context, derives the RAM-polled
// events (wounds, deaths, man changes) and delivers everything to the observers. With `config.probe == nil` none of
// this runs. Nothing here writes game RAM or charges CPU time, so observers never change the game.

/// One game event (see GameProbe's observer helpers).
public enum GameEvent: Equatable {
    public struct Message: Equatable {
        /// Load section whose table was used (nil = the kernel's own texts, $1141e).
        public var section: Int?
        /// Message index (d0 & $ff) and table address ($4a(a6)).
        public var index: Int, table: UInt32
        /// The queue already held 4 messages: the original silently drops this one.
        public var dropped: Bool
        /// Decoded text (res_print string of the table entry).
        public var text: String
    }
    case message(Message)
    /// k_fx(id) called; `enabled` = FX on ($66 bit1), else the original returns without a sound.
    case fx(id: Int, enabled: Bool)
    /// k_add_score: `added` BCD value, new total (BCD).
    case score(added: UInt32, total: UInt32)
    /// A man took a wound (hits 1..3) / was killed (hits 4) - polled from the man records.
    case wounded(man: Int, hits: Int)
    case death(man: Int)
    /// Section 0 "CHOOSE YOUR MAN" opened.
    case manSelect
    /// The current man changed ($22(a6)).
    case manChanged(from: Int, to: Int)
    /// A new game started (from the title, or config.startSection = the given section).
    case newGame(section: Int)
    /// A load section starts (after LOADING / ENTERING), with the a6 globals ($76 bytes) at that moment.
    case sectionStart(section: Int, globals: [UInt8])
    /// A load section was completed (the next one is loaded).
    case sectionEnd(section: Int)
    /// A section's full-screen text is shown (decoded).
    case textScreen(String)
    /// GAME OVER (score BCD, section it ended in).
    case gameOver(score: UInt32, section: Int)
    /// A hiscore was entered: rank 0..9, score, name, table mode ("original", "assisted", ...).
    case hiscore(rank: Int, score: UInt32, name: String, mode: String)
    /// DEL warm restart during a game.
    case aborted
    /// F10 changed the music/FX mode ($66(a6)).
    case soundFlags(UInt8)
    /// The screen kind changed.
    case screen(GameContext.Screen)
}

public struct GameEventRecord {
    /// Machine.frameCount when the event happened.
    public let frame: UInt64
    public let event: GameEvent
}

public final class GameProbe {
    public init() {}

    /// Chain `poll` into Machine.frameHook when the game starts (default). Set false to call `poll` yourself.
    public var autoPoll = true
    /// Optional debug sink: every event as a text line (PLATOON_EVENTS=file uses it).
    public var log: ((String) -> Void)?

    /// The context as of the last poll (host thread).
    public private(set) var context = GameContext()

    // MARK: observers (host thread)

    private var observers: [(Int, (GameEventRecord) -> Void)] = []
    private var nextToken = 1

    /// Adds an observer of every event; returns a token for `removeObserver`.
    @discardableResult public func addObserver(_ f: @escaping (GameEventRecord) -> Void) -> Int {
        let t = nextToken; nextToken += 1; observers.append((t, f)); return t
    }
    public func removeObserver(_ token: Int) { observers.removeAll { $0.0 == token } }

    @discardableResult public func onMessage(_ f: @escaping (GameEvent.Message) -> Void) -> Int {
        addObserver { if case .message(let m) = $0.event { f(m) } }
    }
    @discardableResult public func onFx(_ f: @escaping (_ id: Int, _ enabled: Bool) -> Void) -> Int {
        addObserver { if case .fx(let id, let on) = $0.event { f(id, on) } }
    }
    @discardableResult public func onScore(_ f: @escaping (_ added: UInt32, _ total: UInt32) -> Void) -> Int {
        addObserver { if case .score(let a, let t) = $0.event { f(a, t) } }
    }
    @discardableResult public func onDeath(_ f: @escaping (_ man: Int) -> Void) -> Int {
        addObserver { if case .death(let m) = $0.event { f(m) } }
    }
    @discardableResult public func onManSelect(_ f: @escaping () -> Void) -> Int {
        addObserver { if case .manSelect = $0.event { f() } }
    }
    @discardableResult public func onSectionStart(_ f: @escaping (_ section: Int) -> Void) -> Int {
        addObserver { if case .sectionStart(let s, _) = $0.event { f(s) } }
    }
    @discardableResult public func onSectionEnd(_ f: @escaping (_ section: Int) -> Void) -> Int {
        addObserver { if case .sectionEnd(let s) = $0.event { f(s) } }
    }
    @discardableResult public func onGameOver(_ f: @escaping (_ score: UInt32, _ section: Int) -> Void) -> Int {
        addObserver { if case .gameOver(let s, let sec) = $0.event { f(s, sec) } }
    }
    @discardableResult public func onHiscore(_ f: @escaping (_ rank: Int, _ score: UInt32, _ name: String, _ mode: String) -> Void) -> Int {
        addObserver { if case .hiscore(let r, let s, let n, let m) = $0.event { f(r, s, n, m) } }
    }

    // MARK: F4 assisted runs (any thread)

    /// Marks the current run as assisted/tainted (trainer, rewind, snapshot load, practice ...): its score goes to
    /// the assisted hiscore table, never to the original one. Cleared when the next new game starts; mark again
    /// (e.g. every frame while a trainer option is on) if the reason persists.
    public func markAssisted(_ reason: String) {
        lock.lock(); let p = platoon; lock.unlock()
        if let p = p { p.markAssisted(reason) } else { lock.lock(); earlyReasons.insert(reason); lock.unlock() }
    }

    // MARK: polling (host thread, in frameHook)

    /// Refreshes `context`, derives the RAM-polled events and delivers all pending events to the observers.
    public func poll(_ m: Machine) {
        let recs = takePending()
        context = snapshot(m)
        var derived: [GameEventRecord] = []
        let c = context
        if c.inGame, c.section != nil, c.men.count == 5 {
            if let prev = prevMen, prev.count == 5 {
                for i in 0..<5 where c.men[i].hits != prev[i].hits {
                    let h = c.men[i].hits
                    if h == 4 && prev[i].hits < 4 { derived.append(.init(frame: m.frameCount, event: .death(man: i))) }
                    else if h > prev[i].hits && h < 4 { derived.append(.init(frame: m.frameCount, event: .wounded(man: i, hits: h))) }
                }
            }
            if let pm = prevManIndex, pm != c.currentMan {
                derived.append(.init(frame: m.frameCount, event: .manChanged(from: pm, to: c.currentMan)))
            }
            prevMen = c.men; prevManIndex = c.currentMan
        } else {
            prevMen = nil; prevManIndex = nil
        }
        if c.screen != lastScreen {
            lastScreen = c.screen
            derived.append(.init(frame: m.frameCount, event: .screen(c.screen)))
        }
        if let l = log, c.area != lastLoggedArea || c.screen != lastLoggedScreen {
            lastLoggedArea = c.area; lastLoggedScreen = c.screen
            l("f\(m.frameCount) context " + GameProbe.describe(c))
        }
        for r in recs + derived {
            if let l = log { l(GameProbe.describe(r)) }
            for (_, f) in observers { f(r) }
        }
    }

    /// A fresh context read from RAM now (host thread with the game parked, e.g. in frameHook).
    public func snapshot(_ m: Machine) -> GameContext {
        let mem = m.memory, a6 = Platoon.a6
        lock.lock()
        var c = GameContext()
        c.frame = m.frameCount
        c.screen = screen
        c.loadedSection = loadedSection
        c.section = inSection ? loadedSection : nil
        c.inGame = inGame
        c.text = (screen == .textScreen || screen == .loading) && !screenText.isEmpty
            ? screenText.joined(separator: "\n") : nil
        let pc = modePC, ticks = modeTicks
        c.difficulty = difficulty
        let reasons = platoon?.currentAssistReasons() ?? earlyReasons
        lock.unlock()
        c.assistReasons = reasons.sorted()
        c.assisted = !reasons.isEmpty
        c.hiscoreMode = Platoon.hiscoreMode(for: reasons)
        c.paused = mem.r16(0x10eaa) != 0
        c.soundFlags = mem.r8(a6 + 0x66)
        c.scoreBCD = mem.r32(a6 + 0x4e)
        c.morale = Int(mem.r16(a6 + 0x2e))
        c.men = (0..<5).map { i in
            let r = a6 + UInt32(6 * i)
            return GameContext.Man(grenades: Int(mem.r16(r)), ammo: Int(mem.r16(r + 2)), hits: Int(mem.r16(r + 4)))
        }
        c.currentMan = Int(mem.r16(a6 + 0x22))
        c.timerMinutes = Platoon.bcdValue(UInt32(mem.r8(a6 + 0x6c)))
        c.timerSeconds = Platoon.bcdValue(UInt32(mem.r8(a6 + 0x6d)))
        c.timerRunning = mem.r8(a6 + 0x68) != 0
        c.map = mem.r16(a6 + 0x24) != 0
        c.compass = mem.r16(a6 + 0x26) != 0
        c.explosives = mem.r16(a6 + 0x28) != 0
        c.flares = Int(mem.r16(a6 + 0x2c))
        c.messageCount = Int(mem.r16(a6 + 0x48))
        c.messageQueue = (0..<min(5, c.messageCount)).map { Int(mem.r16(a6 + 0x3c + UInt32(2 * $0))) }
        c.messageTable = mem.r32(a6 + 0x4a)
        c.cheats = Int(mem.r16(a6 + 0x70))
        if c.section != nil {
            switch loadedSection {
            case 0:
                let lvl = Int(mem.r16(0x60c26)), col = Int(mem.r16(0x60c28))
                let j = GameContext.Jungle(level: lvl, column: col, worldX: Int(mem.r16(0x60c30)),
                                           hut: lvl == 5 ? Int(mem.r16(0x60c40)) : nil, bridge: Int(mem.r16(0x60c9c)),
                                           torch: mem.r8(0x60cbd) != 0, playerState: Int(mem.r16(0x5f89a)),
                                           enemyState: Int(mem.r16(0x5f888)))
                c.jungle = j
                c.area = lvl == 5 ? .hut : (lvl == 0 && (0x30...0x54).contains(col) ? .village : .jungle)
            case 1:
                if pc == 0x18b0e || pc == 0x18bd8 {
                    c.area = .flare
                } else {
                    c.area = .tunnels
                    let x = Int(mem.r8(0x1a0b0)), y = Int(mem.r8(0x1a0b1)), inRoom = mem.r8(0x3b230) != 0
                    var room: Int?
                    if inRoom {
                        let w = UInt16(x << 8 | y)
                        room = (0..<10).first { mem.r16(0x19aec + UInt32(2 * $0)) == w }
                    }
                    c.tunnels = GameContext.Tunnels(x: x, y: y, heading: Int(mem.r16(a6 + 0x2a) & 3), inRoom: inRoom, room: room)
                }
            case 2:
                let f = GameContext.FinalJungle(room: Int(mem.r8(0x18f1c)), dirs: mem.r32(0x18f40),
                                                exits: Int(mem.r8(0x57f44)), roomType: Int(mem.r8(0x57f45)),
                                                barnesHP: Int(mem.r8(0x57e6a)))
                c.finalJungle = f
                // the room slots are cleared while a room is entered: decide only while the main loop runs
                if pc == 0x17118 && ticks != s2AreaTicks {
                    s2AreaTicks = ticks
                    s2Area = f.exits == 0 ? .bunker : .finalJungle
                }
                c.area = s2Area
            default: break
            }
        }
        return c
    }

    // MARK: - game side (called by the translated game; game thread or interrupt handlers)

    let lock = NSLock()
    weak var platoon: Platoon?
    var earlyReasons = Set<String>()
    private var pending: [GameEventRecord] = []
    var screen: GameContext.Screen = .boot
    var loadedSection = -1
    var inSection = false
    var inGame = false
    var difficulty: DifficultyPreset = .original
    var modePC: UInt32 = 0
    var modeTicks = 0
    var screenText: [String] = []
    var capturingText = false
    private var s2Area: GameContext.Area = .finalJungle
    private var s2AreaTicks = -1
    private var prevMen: [GameContext.Man]?
    private var prevManIndex: Int?
    private var lastScreen: GameContext.Screen = .boot
    private var lastLoggedArea: GameContext.Area = .none, lastLoggedScreen: GameContext.Screen = .boot

    /// One-line summary of a context (debug log / tests).
    public static func describe(_ c: GameContext) -> String {
        var s = "screen=\(c.screen.rawValue) area=\(c.area.rawValue) section=\(c.section.map(String.init) ?? "-")"
        s += " loaded=\(c.loadedSection) inGame=\(c.inGame ? 1 : 0) man=\(c.currentMan) morale=\(String(c.morale, radix: 16))"
        s += " score=\(c.score) sound=\(c.soundFlags) mode=\(c.hiscoreMode)"
        if let j = c.jungle { s += " jungle(level=\(j.level) col=\(j.column) hut=\(j.hut.map(String.init) ?? "-") bridge=\(j.bridge))" }
        if let t = c.tunnels { s += " tunnels(\(t.x),\(t.y) heading=\(t.heading) room=\(t.room.map(String.init) ?? (t.inRoom ? "?" : "-")))" }
        if let f = c.finalJungle { s += String(format: " final(room=%d exits=%02x)", f.room, f.exits) }
        if let t = c.text { s += " text=\"\(t.replacingOccurrences(of: "\n", with: " / "))\"" }
        return s
    }

    func record(_ frame: UInt64, _ e: GameEvent) {
        lock.lock(); pending.append(GameEventRecord(frame: frame, event: e)); lock.unlock()
    }

    private func takePending() -> [GameEventRecord] {
        lock.lock(); defer { lock.unlock() }
        let p = pending; pending.removeAll(keepingCapacity: true); return p
    }

    func setScreen(_ s: GameContext.Screen) {
        lock.lock(); screen = s; if s != .textScreen { capturingText = false }; lock.unlock()
    }

    /// Main-loop heads and wait loops of the sections (original PCs passed to tickPoint) -> screen kind.
    /// Returns nil for PCs that don't identify a mode (most tickPoints).
    static func screenForTick(_ pc: UInt32) -> GameContext.Screen? {
        switch pc {
        case 0x17186, 0x17e52,                               // S0 main loop, wait-messages after N
             0x170c4, 0x171c6, 0x171d8, 0x18b0e, 0x18bd8,    // S1 tunnels restart/main loop, flare enter/loop
             0x17068, 0x170f4, 0x17118:                      // S2 restart, room entered, main loop
            return .playing
        case 0x17dae: return .trapDoorPrompt
        case 0x19758, 0x19772: return .manSelect
        case 0x19850, 0x1986c, 0x1770e: return .textScreen   // S0 wait-fire after the end texts, S2 text screen
        default: return nil
        }
    }

    /// One-line description of an event (debug log / tests).
    public static func describe(_ r: GameEventRecord) -> String {
        let e: String
        switch r.event {
        case .message(let m):
            e = String(format: "message sec=%@ idx=$%02x table=$%05x%@ \"%@\"", m.section.map(String.init) ?? "k", m.index,
                       m.table, m.dropped ? " DROPPED" : "", m.text.replacingOccurrences(of: "\n", with: " / "))
        case .fx(let id, let on): e = String(format: "fx $%02x%@", id, on ? "" : " (fx off)")
        case .score(let a, let t): e = String(format: "score +%x = %08x", a, t)
        case .wounded(let m, let h): e = "wounded man=\(m) hits=\(h)"
        case .death(let m): e = "death man=\(m)"
        case .manSelect: e = "manSelect"
        case .manChanged(let a, let b): e = "manChanged \(a)->\(b)"
        case .newGame(let s): e = "newGame section=\(s)"
        case .sectionStart(let s, _): e = "sectionStart \(s)"
        case .sectionEnd(let s): e = "sectionEnd \(s)"
        case .textScreen(let t): e = "textScreen \"\(t.replacingOccurrences(of: "\n", with: " / "))\""
        case .gameOver(let s, let sec): e = String(format: "gameOver score=%08x section=%d", s, sec)
        case .hiscore(let r, let s, let n, let m): e = String(format: "hiscore rank=%d score=%08x name=\"%@\" mode=%@", r, s, n, m)
        case .aborted: e = "aborted"
        case .soundFlags(let f): e = "soundFlags \(f)"
        case .screen(let s): e = "screen \(s.rawValue)"
        }
        return "f\(r.frame) \(e)"
    }
}
