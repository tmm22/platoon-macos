import XCTest
@testable import PlatoonCore

// Owner: section0. Section-0 options (Enhance/Section0Options.swift): defaults, keys, difficulty presets, and the
// read-only L4 geometry. Gameplay behaviour is tested headless by port/verify/section0/enh/features.py.
final class Section0OptionsTests: XCTestCase {
    func testDefaultsAreOriginal() {
        let o = Section0Options()
        XCTAssertFalse(o.bridgeFailsafe || o.forgivingTraps || o.fixMoraleWrap || o.fixHutDummy || o.fixTripwireSpawn
                       || o.fixTrapdoorBonus || o.explicitJumpCrouch)
        XCTAssertNil(o.villageSeed); XCTAssertNil(o.jumpKey); XCTAssertNil(o.crouchKey)
        XCTAssertFalse(o.bridgeFailsafeOn); XCTAssertFalse(o.trapsWoundOn)
        XCTAssertEqual(Section0Difficulty.preset(.original).merged(over: Section0Difficulty()).shootMask, nil)
    }

    func testKeysAndAssist() throws {
        var e = Enhancements()
        try e.apply("s0.bridgeFailsafe=1,s0.villageSeed=42,s0.diff.shootMask=0x3f")
        XCTAssertTrue(e.section0.bridgeFailsafe)
        XCTAssertEqual(e.section0.villageSeed, 42)
        XCTAssertEqual(e.section0.difficulty.shootMask, 0x3f)
        XCTAssertFalse(e.assistReasons.isEmpty, "gameplay options must taint the run")
        // M14 key bindings alone are not gameplay (they do nothing without explicitJumpCrouch)
        var k = Enhancements()
        try k.apply("s0.jumpKey=0x32")
        XCTAssertTrue(k.assistReasons.isEmpty)
    }

    func testPresets() throws {
        var e = Enhancements()
        try e.apply("difficulty=recruit")
        let r = e.resolved().section0
        XCTAssertTrue(r.bridgeFailsafeOn && r.trapsWoundOn)
        XCTAssertEqual(r.difficulty.hitMorale, 0x400)
        var v = Enhancements()
        try v.apply("difficulty=veteran,s0.diff.grenades=2")
        let rv = v.resolved().section0
        XCTAssertEqual(rv.difficulty.grenades, 2, "explicit knobs win over the preset")
        XCTAssertEqual(rv.difficulty.ammo, 0x60)
        XCTAssertFalse(rv.bridgeFailsafeOn)
        var c = Enhancements()
        try c.apply("difficulty=custom")
        XCTAssertNil(c.resolved().section0.difficulty.shootMask, "custom = only what is set")
    }

    func testWideGeometry() {
        XCTAssertEqual(JungleWidescreen.windowWidth, 304)
        XCTAssertEqual(JungleWidescreen.canvasLeftEdge, 33)
        XCTAssertEqual(JungleWidescreen.canvasRightEdge, 337)
        XCTAssertEqual(JungleWidescreen.canvasFirstLine, 36)
        let s = JungleWideLatch.State(frame: 0, level: 1, T: 5, c34: 2, hscroll: 3, palette: 0x19ff8, valid: true)
        XCTAssertEqual(s.worldX0, 6 * 64 + 16 + 16)
    }
}
