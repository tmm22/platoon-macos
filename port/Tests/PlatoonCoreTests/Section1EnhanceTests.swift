import XCTest
@testable import PlatoonCore

// Owner: section1. Section-1 option catalogue, M10 knob resolution and the read-only maze helpers (TunnelMaze).
// Gameplay behaviour of the hooks is tested headless by port/verify/enh-section1/s1test.py.
final class Section1EnhanceTests: XCTestCase {
    func testDefaultsAreOriginal() {
        let o = Section1Options()
        XCTAssertFalse(o.keepItems || o.flareRetry || o.checkpointRespawn || o.exploredMap)
        XCTAssertFalse(o.fixMoraleWrap || o.fixLastBullet || o.fixFlareSpawn || o.fixFoodFarm || o.directAim)
        XCTAssertEqual(o.randomSeed, 0)
        XCTAssertFalse(o.needsScratch)
        let d = Enhancements().resolved().section1.difficulty
        XCTAssertNil(d.hitMorale); XCTAssertNil(d.spawnDelay); XCTAssertNil(d.enemyAim)
        XCTAssertNil(d.itemMorale); XCTAssertNil(d.flareSpawnBase); XCTAssertNil(d.flareShotSlack)
    }

    func testEveryOptionTaintsTheRun() throws {
        for (k, v) in [("s1.keepItems", "1"), ("s1.flareRetry", "1"), ("s1.checkpointRespawn", "1"),
                       ("s1.exploredMap", "1"), ("s1.fixLastBullet", "1"), ("s1.fixMoraleWrap", "1"),
                       ("s1.fixFoodFarm", "1"), ("s1.fixFlareSpawn", "1"), ("s1.directAim", "1"),
                       ("s1.randomSeed", "7"), ("s1.diff.hitMorale", "0x400")] {
            var e = Enhancements()
            try e.set(k, v)
            XCTAssertFalse(e.assistReasons.isEmpty, "\(k) must mark the run as assisted")
        }
    }

    func testPresetsAndExplicitKnobs() throws {
        var e = Enhancements()
        try e.apply("difficulty=recruit")
        XCTAssertEqual(e.resolved().section1.difficulty.hitMorale, 0x800)
        XCTAssertEqual(e.resolved().section1.difficulty.flareSpawnBase, 0xc0)
        try e.apply("s1.diff.hitMorale=0x100")                  // an explicit knob wins over the preset
        XCTAssertEqual(e.resolved().section1.difficulty.hitMorale, 0x100)
        XCTAssertEqual(e.resolved().section1.difficulty.spawnDelay, 0x20)
        var v = Enhancements()
        try v.apply("difficulty=veteran")
        XCTAssertEqual(v.resolved().section1.difficulty.enemyAim, 0x0b)
        var c = Enhancements()
        try c.apply("difficulty=custom")
        XCTAssertNil(c.resolved().section1.difficulty.hitMorale)
        XCTAssertThrowsError(try c.set("s1.diff.flareShotSlack", "0x20"))   // out of range
    }

    func testVisibleCells() {
        // straight N-S corridor at x = 5 in an otherwise solid maze
        func cell(_ x: Int, _ y: Int) -> UInt8 { x == 5 && (0..<43).contains(y) ? 2 : 30 }
        let c = Set(TunnelMaze.visibleCells(x: 5, y: 20, heading: 0, cell: cell))
        for dy in -1...1 { for dx in -1...1 { XCTAssertTrue(c.contains((20 + dy) * 43 + 5 + dx)) } }
        for k in 1...4 { XCTAssertTrue(c.contains((20 - k) * 43 + 5), "forward \(k)") }
        XCTAssertFalse(c.contains(14 * 43 + 5), "no further than 5 ahead")
        XCTAssertFalse(c.contains(23 * 43 + 5), "nothing behind beyond the neighbours")
        // at the maze edge nothing outside the grid is returned
        XCTAssertTrue(TunnelMaze.visibleCells(x: 0, y: 0, heading: 3, cell: cell).allSatisfy { (0..<(43 * 43)).contains($0) })
    }

    func testItemNames() {
        XCTAssertEqual(TunnelMaze.itemName(0x15), "EXIT")
        XCTAssertEqual(TunnelMaze.itemName(0x04), "flares")
        XCTAssertTrue(TunnelMaze.isKeyItem(0x11))
        XCTAssertFalse(TunnelMaze.isKeyItem(0x02))
    }
}
