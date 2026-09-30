import XCTest
@testable import PlatoonCore

// Owner: core. Cheats (Enhance/CheatOptions.swift): registry keys, legacy aliases, assist reasons, and short game runs
// (original cheats in RAM, live switching, per-game assisted marks). The full per-section checks are the headless
// harness port/verify/cheats/run_cheats.py.
final class CheatTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func disk() throws -> Disk {
        let adf = CheatTests.root.appendingPathComponent("re/platoon_port.adf")
        guard FileManager.default.fileExists(atPath: adf.path) else { throw XCTSkip("no re/platoon_port.adf") }
        return try Disk(contentsOf: adf)
    }

    func testCheatsDefaultOffAndKeys() throws {
        let e = Enhancements()
        XCTAssertFalse(e.cheats.anyOn)
        XCTAssertTrue(e.cheatAssistReasons.isEmpty)
        let keys = Set(Enhancements.catalog.filter { $0.group == "cheat" }.map(\.key))
        XCTAssertEqual(keys, ["cheat.original", "cheat.invincible", "cheat.infiniteAmmo", "cheat.infiniteGrenades",
                              "cheat.infiniteFlares", "cheat.infiniteMorale", "cheat.freezeTimer", "cheat.infiniteMen"])
        for i in Enhancements.catalog where i.group == "cheat" {
            XCTAssertTrue(i.gameplay, i.key)
            XCTAssertEqual(i.defaultValue, "0", i.key)
        }
        XCTAssertEqual(CheatOptions.all.assistReasons.count, CheatOptions.options.count)
    }

    func testLegacyAliasesAndReasons() throws {
        var e = Enhancements()
        try e.apply("infiniteAmmo=1")                                      // legacy PLATOON_ENH key
        XCTAssertTrue(e.cheats.infiniteAmmo)
        try e.apply("cheat.invincible=1,cheat.original=1")
        XCTAssertEqual(e.cheats.assistReasons, ["cheat.infiniteAmmo", "cheat.invincible", "cheat.original"])
        XCTAssertTrue(e.cheatAssistReasons.isSuperset(of: ["cheat.invincible", "cheat.original", "infiniteAmmo"]))
        XCTAssertTrue(e.assistReasons.isSuperset(of: e.cheatAssistReasons))
        XCTAssertEqual(Platoon.hiscoreMode(for: e.assistReasons), "assisted")
        XCTAssertEqual(Platoon.hiscoreMode(for: e.cheatAssistReasons), "assisted")
        // a cheat together with a difficulty preset is still "assisted", not the preset's table
        try e.apply("difficulty=recruit")
        XCTAssertEqual(Platoon.hiscoreMode(for: e.assistReasons), "assisted")
    }

    /// Original cheats on the title, live switching from a frame hook, per-game assisted marks.
    func testOriginalCheatsLiveAndPerGame() throws {
        let m = Machine(disk: try disk())
        var cfg = GameConfig()
        cfg.deterministicRNG = true
        try cfg.enhancements.apply("cheat.original=1")
        var pending: CheatOptions?
        m.frameHook = { mm in
            if let c = pending { PlatoonGame.setCheats(mm, c); pending = nil }
        }
        m.start { PlatoonGame.main($0, config: cfg) }
        for _ in 0..<700 { m.runFrame() }
        XCTAssertEqual(m.memory.r16(0x12e4e), 3, "$70(a6): CHEAT!!! + MEGA CHEAT")
        XCTAssertEqual(m.memory.r8(0x115b3), 0)
        XCTAssertEqual(m.memory.r8(0x115c2), 0)
        XCTAssertTrue(PlatoonGame.assistReasons(m).contains("cheat.original"))
        // live: original off (RAM restored), invincibility on (marked)
        var c = CheatOptions(); c.invincible = true
        pending = c
        for _ in 0..<5 { m.runFrame() }
        XCTAssertEqual(m.memory.r16(0x12e4e) & 3, 0)
        XCTAssertNotEqual(m.memory.r8(0x115b3), 0)
        XCTAssertNotEqual(m.memory.r8(0x115c2), 0)
        XCTAssertEqual(PlatoonGame.cheats(m), c)
        XCTAssertTrue(PlatoonGame.assistReasons(m).contains("cheat.invincible"))
        // everything off: a new game from the title is an ordinary game again
        pending = CheatOptions()
        for _ in 0..<5 { m.runFrame() }
        m.input.fire = true
        for _ in 0..<6 { m.runFrame() }
        m.input.fire = false
        for _ in 0..<60 { m.runFrame() }
        XCTAssertTrue(PlatoonGame.assistReasons(m).isEmpty, "\(PlatoonGame.assistReasons(m))")
    }

    /// Invincibility in the jungle: 3000 frames standing in enemy fire, no wound; the control run is hit.
    func testJungleInvincible() throws {
        func hits(_ enh: String) throws -> (hits: Int, morale: UInt16) {
            let m = Machine(disk: try disk())
            var cfg = GameConfig()
            cfg.deterministicRNG = true
            cfg.startSection = 0
            try cfg.enhancements.apply(enh)
            m.start { PlatoonGame.main($0, config: cfg) }
            for _ in 0..<3000 { m.runFrame() }
            let h = (0..<5).map { Int(m.memory.r16(0x12dde + UInt32(6 * $0) + 4)) }.reduce(0, +)
            return (h, m.memory.r16(0x12e0c))
        }
        XCTAssertEqual(try hits("cheat.invincible=1,cheat.infiniteMorale=1").hits, 0)
        XCTAssertEqual(try hits("cheat.invincible=1,cheat.infiniteMorale=1").morale, 0x9000)
        XCTAssertGreaterThan(try hits("").hits, 0)
    }
}
