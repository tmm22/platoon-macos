import XCTest
@testable import PlatoonCore

// Owner: core. The enhancement registry (Enhance/Registry.swift), difficulty resolution and assist reasons.
final class EnhancementRegistryTests: XCTestCase {
    func testDefaultsAreOriginal() {
        let e = Enhancements()
        XCTAssertTrue(e.changed.isEmpty, "defaults must equal the catalogue defaults: \(e.changed)")
        XCTAssertTrue(e.assistReasons.isEmpty)
        XCTAssertEqual(e.difficulty, .original)
        XCTAssertTrue(e.originalCredits)
        XCTAssertNil(e.kernel.soundFlagsAtBoot)
        XCTAssertNil(e.resolved().kernel.difficulty.startMorale)
        XCTAssertEqual(Platoon.hiscoreMode(for: e.assistReasons), "original")
    }

    func testKeyValueParsing() throws {
        var e = Enhancements()
        try e.apply("originalCredits=0, kernel.soundFlagsAtBoot=$1;game.lives=3 steadyPauseColour")
        XCTAssertFalse(e.originalCredits)
        XCTAssertFalse(e.kernel.originalCredits)
        XCTAssertEqual(e.kernel.soundFlagsAtBoot, 1)
        XCTAssertEqual(e.game.lives, 3)
        XCTAssertTrue(e.kernel.steadyPauseColour)               // bare unique key = 1
        try e.set("kernel.soundFlagsAtBoot", "original")
        XCTAssertNil(e.kernel.soundFlagsAtBoot)
        try e.set("kernel.diff.startMorale", "0x4800")
        XCTAssertEqual(e.kernel.difficulty.startMorale, 0x4800)
        XCTAssertEqual(try e.value("game.lives"), "3")
        XCTAssertThrowsError(try e.set("nope", "1"))
        XCTAssertThrowsError(try e.set("game.lives", "9"))      // out of range
        XCTAssertThrowsError(try e.set("game.fullPlatoon", "maybe"))
        XCTAssertThrowsError(try e.set("originalCredits", "2"))
        // legacy PLATOON_ENH form still works
        var l = Enhancements()
        try l.apply("originalCredits=0,infiniteAmmo=1,infiniteMorale=1")
        XCTAssertTrue(l.infiniteAmmo && l.infiniteMorale && !l.originalCredits)
        // array form returns errors instead of throwing
        var a = Enhancements()
        let errs = a.apply(["game.lives=4", "bogus=1"])
        XCTAssertEqual(errs.count, 1)
        XCTAssertEqual(a.game.lives, 4)
    }

    func testCatalogueKeysUniqueAndRoundTrip() throws {
        let keys = Enhancements.catalog.map { $0.key }
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate keys")
        // every option accepts its own default and its printed value round-trips
        var e = Enhancements()
        for i in Enhancements.catalog {
            try e.set(i.key, i.defaultValue)
            XCTAssertEqual(try e.value(i.key), i.defaultValue, i.key)
        }
        XCTAssertTrue(e.changed.isEmpty)
    }

    func testAssistReasonsAndModes() throws {
        var e = Enhancements()
        try e.apply("kernel.steadyPauseColour=1,kernel.keyboardNameEntry=1,originalCredits=0")
        XCTAssertTrue(e.assistReasons.isEmpty, "presentational options must not taint")
        try e.apply("difficulty=recruit")
        XCTAssertEqual(e.assistReasons, ["difficulty:recruit"])
        XCTAssertEqual(Platoon.hiscoreMode(for: e.assistReasons), "recruit")
        XCTAssertEqual(e.resolved().kernel.difficulty.startMorale, 0xc000)
        try e.apply("kernel.diff.startMorale=0x5000")                    // explicit knob wins over the preset
        XCTAssertEqual(e.resolved().kernel.difficulty.startMorale, 0x5000)
        XCTAssertEqual(Platoon.hiscoreMode(for: e.assistReasons), "custom")
        var c = Enhancements()
        try c.apply("difficulty=custom")
        XCTAssertNil(c.resolved().kernel.difficulty.startMorale)
        XCTAssertEqual(Platoon.hiscoreMode(for: c.assistReasons), "custom")
        var g = Enhancements()
        try g.apply("game.fullPlatoon=1")
        XCTAssertEqual(Platoon.hiscoreMode(for: g.assistReasons), "assisted")
        XCTAssertEqual(Platoon.hiscoreMode(for: ["trainer"]), "assisted")
        XCTAssertEqual(Platoon.hiscoreMode(for: ["difficulty:veteran"]), "veteran")
    }

    func testPrintTextDecoder() {
        let m = Memory()
        // [5,3] "AB" 0 [1,4] colour(2,6) "CD" + last char 'E'|$80
        m.load([5, 3, 0x41, 0x42, 0, 1, 4, 2, 6, 0x43, 0x44, 0xC5] as [UInt8], at: 0x1000)   // 0xC5 = "E" | $80
        let s = PrintText.segments(m, 0x1000)
        XCTAssertEqual(s, [.init(col: 5, row: 3, text: "AB"), .init(col: 1, row: 4, text: "CDE")])
        XCTAssertEqual(PrintText.plain(s), "AB\nCDE")
        m.load([0, 0, 0x48, 0x49, 0xff], at: 0x2000)
        XCTAssertEqual(PrintText.decode(m, 0x2000), "HI")
        XCTAssertEqual(Platoon.bcdValue(0x0001_2345), 12345)
    }
}
