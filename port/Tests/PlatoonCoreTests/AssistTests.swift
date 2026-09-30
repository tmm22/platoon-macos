import XCTest
@testable import PlatoonCore

// Owner: assist. Headless tests of the assist models (PlatoonCore/Game/Assist): S8 message log + speech text, M2
// objectives / HUD readout, M16 run timer + service record, M17 input replays (record -> play back must be
// byte-identical), M11 practice drills (prepared snapshots resume where they should).
// The game runs are the verified scripts of port/verify with --deterministic, like the regression gate.
final class AssistTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func disk() throws -> Disk {
        let adf = AssistTests.root.appendingPathComponent("re/platoon_port.adf")
        guard FileManager.default.fileExists(atPath: adf.path) else { throw XCTSkip("no re/platoon_port.adf") }
        return try Disk(contentsOf: adf)
    }

    private func script(_ rel: String) throws -> [(Int, [String])] {
        let u = AssistTests.root.appendingPathComponent(rel)
        guard let t = try? String(contentsOf: u, encoding: .utf8) else { throw XCTSkip("no \(rel)") }
        return PracticeScripts.events(t)
    }

    // MARK: S8

    func testSpeechText() {
        XCTAssertEqual(SpeechText.readable("YOU DID'NT BLOW UP THE BRIDGE, YOUR PLATOON HAS BEEN WIPED OUT!"),
                       "You didn't blow up the bridge, your platoon has been wiped out!")
        XCTAssertEqual(SpeechText.readable("A COMPASS WOULD HELP !"), "A compass would help!")
        XCTAssertEqual(SpeechText.readable("HERE IS A TRAP DOOR.... GO DOWN (Y/N)?"), "Here is a trap door... Go down? Y or N.")
        XCTAssertEqual(SpeechText.readable("A BOX OF VIET CONG AMMUNITION."), "A box of viet cong ammunition.")
        XCTAssertEqual(SpeechText.readable("THE TUNNEL SYSTEM\nPRESS FIRE TO CONTINUE"), "The tunnel system. Press fire to continue")
        XCTAssertEqual(SpeechText.readable("ENTERING THE COMBAT ZONE...."), "Entering the combat zone...")
        XCTAssertEqual(SpeechText.readable("!THE JUNGLE!\nYOU HAVE TWO  MINUTES"), "!The jungle! You have two minutes")
    }

    func testMessageLogFolding() {
        let log = MessageLog()
        func msg(_ i: Int, _ t: String, dropped: Bool = false) -> GameEvent.Message {
            .init(section: 0, index: i, table: 0x1a6de, dropped: dropped, text: t)
        }
        XCTAssertNotNil(log.add(msg(0x18, "PLEASE DON'T ATTEMPT SUICIDE!!"), frame: 8371))
        // the game re-queues it every 2 frames (and drops most of them): one entry
        for f in stride(from: UInt64(8374), through: 8404, by: 2) { XCTAssertNil(log.add(msg(0x18, "PLEASE DON'T ATTEMPT SUICIDE!!", dropped: f >= 8380), frame: f)) }
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].count, 17)
        XCTAssertFalse(log.entries[0].dropped)
        // a dropped message nobody saw stays marked
        XCTAssertEqual(log.add(msg(0x0e, "YOU'RE HIT", dropped: true), frame: 8500)?.dropped, true)
        // the same text much later is a new entry
        XCTAssertNotNil(log.add(msg(0x18, "PLEASE DON'T ATTEMPT SUICIDE!!"), frame: 9000))
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertTrue(log.exportText().contains("[not shown by the game]"))
        XCTAssertEqual(MessageLog.clock(8371), "2:47")
    }

    // MARK: M2 / M16 / S8 on the honest final-jungle route (port/verify/section2/honest1.txt: bunker, Barnes, win)

    func testFinalJungleRunModels() throws {
        let events = try script("port/verify/section2/honest1.txt")
        let m = Machine(disk: try disk())
        var cfg = GameConfig(); cfg.deterministicRNG = true; cfg.enhancements.kernel.originalCredits = false
        let probe = GameProbe(); cfg.probe = probe
        let log = MessageLog(), objectives = ObjectiveTracker(), timer = RunTimer(), record = ServiceRecorder()
        var sheets: [String: ObjectiveSheet] = [:]
        var hudBunker: [HudReadout.Line] = []
        probe.addObserver { r in
            if case .message(let msg) = r.event { log.add(msg, frame: r.frame) }
            timer.event(r.event); record.event(r.event)
        }
        m.start { PlatoonGame.main($0, config: cfg) }
        var ei = 0
        for f in 0..<2700 {
            while ei < events.count && events[ei].0 <= f { PracticeDrills.apply(events[ei].1, to: m); ei += 1 }
            m.runFrame()
            let c = probe.context
            objectives.update(c); timer.frame(c); record.frame(c)
            if let s = objectives.sheet(c, tier: .solution) { sheets["\(c.area)"] = s }
            if c.area == .bunker, hudBunker.isEmpty { hudBunker = HudReadout.lines(c) }
        }
        // timer + splits
        XCTAssertEqual(timer.status, .won)
        XCTAssertEqual(timer.splits.map(\.id), ["s2.bunker", "s2.barnes", "s2.huey"])
        XCTAssertEqual(timer.startSection, 0, "the script starts from the title (poked section)")
        XCTAssertTrue(timer.frames > 1300 && timer.frames < 2000, "run time \(timer.frames)")
        var pbs = SpeedrunRecords()
        XCTAssertTrue(pbs.record(category: timer.category, frames: timer.frames, splits: timer.splits, won: true))
        XCTAssertFalse(pbs.record(category: timer.category, frames: timer.frames + 1, splits: timer.splits, won: true))
        XCTAssertEqual(pbs.pbSplit(timer.category, "s2.bunker"), timer.splits[0].frames)
        // service record: a win with > 1:00 left
        XCTAssertEqual(record.record.gamesStarted, 1)
        XCTAssertEqual(record.record.gamesWon, 1)
        XCTAssertEqual(record.record.gamesLost, 0)
        XCTAssertNotNil(record.record.medals["complete"])
        XCTAssertNotNil(record.record.medals["beatTheClock"])
        XCTAssertEqual(record.record.bestScore["original"], 1500)
        // objectives
        let fj = try XCTUnwrap(sheets["finalJungle"]), bunker = try XCTUnwrap(sheets["bunker"])
        XCTAssertEqual(fj.objectives.first?.state, .todo)
        XCTAssertTrue(fj.objectives.first?.detail?.contains("L R L R") ?? false, "solution tier shows the route")
        XCTAssertEqual(bunker.objectives.first { $0.id == "s2.bunker" }?.state, .done)
        XCTAssertEqual(bunker.objectives.first { $0.id == "s2.barnes" }?.state, .done)
        XCTAssertTrue(hudBunker.contains { $0.label == "BARNES" && $0.value == "5 hits" }, "\(hudBunker)")
        XCTAssertTrue(hudBunker.contains { $0.label == "TIME" })
        // message log: the compass hint was re-queued within 5 s and folded
        let compass = log.entries.filter { $0.text == "A COMPASS WOULD HELP !" }
        XCTAssertFalse(compass.isEmpty)
        XCTAssertTrue(compass.contains { $0.count > 1 })
        XCTAssertTrue(log.entries.contains { $0.text == "YOU'RE HIT" })
    }

    // MARK: M17

    /// Records a run driven by a script (plus key taps: TAB pause on/off, F10 twice), plays the recording back in a
    /// fresh Machine and requires every frame's full-RAM hash to be identical.
    func testReplayRoundTripIsExact() throws {
        let d = try disk()
        var events = try script("port/verify/section2/honest1.txt").filter { $0.1.first != "poke" }
        events += [(1200, ["key", "0x42", "1"]), (1204, ["key", "0x42", "0"]), (1300, ["key", "0x42", "1"]), (1304, ["key", "0x42", "0"]),
                   (1400, ["key", "0x59", "1"]), (1401, ["key", "0x59", "0"]), (1500, ["key", "0x59", "1"]), (1502, ["key", "0x59", "0"])]
        events.sort { $0.0 < $1.0 }
        let frames = 2400
        var cfg = GameConfig(); cfg.deterministicRNG = true; cfg.startSection = 2

        let a = Machine(disk: d)
        a.start { PlatoonGame.main($0, config: cfg) }
        let rec = InputRecorder(machine: a)
        XCTAssertTrue(rec.valid)
        var hashes: [UInt64] = []
        var ei = 0
        for f in 0..<frames {
            while ei < events.count && events[ei].0 <= f { PracticeDrills.apply(events[ei].1, to: a); ei += 1 }
            rec.observe(a)                           // as the app does: at the start of the frame
            a.runFrame()
            hashes.append(a.memory.hash(0, 0x80000))
        }
        a.stop()
        var h = ReplayHeader(); h.startSection = 2
        let replay = rec.replay(header: h)
        XCTAssertEqual(replay.events.filter { if case .key = $0.kind { return true }; return false }.count, 8, "8 key deliveries")
        XCTAssertEqual(replay.minKeySpacing.map { $0 >= 1 }, true)
        // text round trip
        let text = replay.encoded()
        let back = try InputReplay.decode(text)
        XCTAssertEqual(back.events, replay.events)
        XCTAssertEqual(back.header.startSection, 2)
        XCTAssertTrue(text.contains("--start-section 2"))

        // play back (the app player: key gap 0)
        let b = Machine(disk: d)
        b.input.keyGapFrames = 0
        b.start { PlatoonGame.main($0, config: cfg) }
        let player = InputPlayer(back)
        for f in 0..<frames {
            player.apply(b)
            b.runFrame()
            if b.memory.hash(0, 0x80000) != hashes[f] { XCTFail("replay diverged at frame \(f)"); break }
        }
        b.stop()

        // headless playback: the text file is a --script (original key pacing, gap 2): same result for keys >= 3 apart
        let c = Machine(disk: d)
        c.start { PlatoonGame.main($0, config: cfg) }
        let hs = PracticeScripts.events(text)
        ei = 0
        var same = true
        for f in 0..<frames {
            while ei < hs.count && hs[ei].0 <= f { PracticeDrills.apply(hs[ei].1, to: c); ei += 1 }
            c.runFrame()
            if c.memory.hash(0, 0x80000) != hashes[f] { same = false; break }
        }
        c.stop()
        XCTAssertEqual(same, (replay.minKeySpacing ?? 3) >= 3)
    }

    // MARK: M11

    private func resumeAndRun(_ snap: GameSnapshot, frames: Int, disk d: Disk) -> GameContext {
        let m = Machine(disk: d)
        var cfg = GameConfig(); let probe = GameProbe(); cfg.probe = probe
        PlatoonGame.resume(m, from: snap, config: cfg, assisted: "Practice")
        for _ in 0..<frames { m.runFrame() }
        let c = probe.context
        m.stop()
        return c
    }

    func testPracticeDrillsSection2AndFlare() throws {
        let d = try disk()
        let barnes = try PracticeDrills.prepare(try XCTUnwrap(PracticeDrills.drill("barnes")), disk: d)
        XCTAssertEqual(barnes.info.loop, .finalJungle)
        var c = resumeAndRun(barnes, frames: 20, disk: d)
        XCTAssertEqual(c.area, .bunker)
        XCTAssertEqual(c.finalJungle?.barnesHP, 0x32)
        XCTAssertTrue(c.assisted)

        let flare = try PracticeDrills.prepare(try XCTUnwrap(PracticeDrills.drill("flare")), disk: d)
        XCTAssertEqual(flare.info.loop, .flare)
        c = resumeAndRun(flare, frames: 20, disk: d)
        XCTAssertEqual(c.area, .flare)
        XCTAssertEqual(c.flares, 8)
        XCTAssertEqual(c.cheats, 0)

        let start = try PracticeDrills.prepare(try XCTUnwrap(PracticeDrills.drill("tunnels")), disk: d)
        XCTAssertEqual(start.info.loop, .tunnels)
        c = resumeAndRun(start, frames: 20, disk: d)
        XCTAssertEqual(c.section, 1)
        XCTAssertEqual(c.tunnels.map { [$0.x, $0.y] }, [21, 3])
    }

    func testPracticeDrillsJungle() throws {
        let d = try disk()
        let bridge = try PracticeDrills.prepare(try XCTUnwrap(PracticeDrills.drill("bridge")), disk: d)
        XCTAssertEqual(bridge.info.loop, .jungle)
        XCTAssertEqual(bridge.machine.memory[0x60ca0], 0, "invincibility poke cleared")
        var c = resumeAndRun(bridge, frames: 10, disk: d)
        XCTAssertEqual(c.area, .jungle)
        XCTAssertTrue(c.explosives)
        XCTAssertEqual(c.jungle?.bridge, 0)
        XCTAssertEqual(c.jungle?.level, 1)
        let o = ObjectiveTracker(); o.update(c)
        let sheet = try XCTUnwrap(o.sheet(c, tier: .goals))
        XCTAssertEqual(sheet.objectives.map { $0.state == .done }, [true, false, false, false, false, false])

        let village = try PracticeDrills.prepare(try XCTUnwrap(PracticeDrills.drill("village")), disk: d)
        c = resumeAndRun(village, frames: 10, disk: d)
        XCTAssertEqual(c.area, .village)
        XCTAssertEqual(c.jungle?.bridge, 2)
        XCTAssertTrue(PracticeDrills.goalReached(.bridge, context: c, event: nil))
    }
}
