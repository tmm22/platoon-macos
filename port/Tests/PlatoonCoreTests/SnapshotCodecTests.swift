import XCTest
@testable import PlatoonCore

// Owner: snapshot. Savestate container / codec (Game/Snapshot, Platform/MachineSnapshot.swift). The behavioural
// round-trip tests (restore and continue = identical to an uninterrupted run) are headless: port/verify/snapshot.
final class SnapshotCodecTests: XCTestCase {
    private func sampleSnapshot() throws -> GameSnapshot {
        let disk = try Disk(data: [UInt8](repeating: 0, count: 160 * Disk.trackSize))
        let m = Machine(disk: disk)
        for i in 0..<Memory.size { m.memory.bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        m.chip.regs[0x40] = 0x1234; m.chip.dmacon = 0x83f0; m.chip.intena = 0x6028; m.chip.ciaB.alarm = 0x0000cc
        m.chip.ciaB.tod = 0x31; m.chip.ciaA.taLatch = 0x2345; m.chip.canvas[1234] = 0xff123456
        m.input.up = true; m.input.key(0x40, down: true)
        var host = PlatoonHostState()
        host.cpuCycles = 777; host.loadedSection = 1; host.musicPlaying = true; host.irqBusyUntil = 123_456
        host.runAssist = ["trainer"]; host.hsActiveMode = "assisted"; host.hsModeTables = ["recruit": [1, 2, 3]]
        let info = SnapshotInfo(loop: .tunnels, frame: 4242, created: Date(timeIntervalSince1970: 1_000_000), scoreBCD: 0x0001_2500,
                                morale: 0x9000, manIndex: 1, buildTag: "test", adfTag: GameSnapshot.adfTag(disk), assisted: false,
                                thumbnailPNG: Data([1, 2, 3]), label: "Quick save")
        return GameSnapshot(info: info, machine: m.captureState(), host: host)
    }

    func testEncodeDecodeIsLossless() throws {
        let s = try sampleSnapshot()
        let d = s.encoded()
        let r = try GameSnapshot.decode(d)
        XCTAssertEqual(r.encoded(), d, "re-encoding a decoded snapshot must give the same bytes")
        XCTAssertEqual(r.info.frame, 4242); XCTAssertEqual(r.info.loop, .tunnels); XCTAssertEqual(r.info.score, "12500")
        XCTAssertEqual(r.machine.memory, s.machine.memory)
        XCTAssertEqual(r.machine.chip.canvas[1234], 0xff123456)
        XCTAssertEqual(r.machine.input.keyQueue, [0x40]); XCTAssertTrue(r.machine.input.up)
        XCTAssertEqual(r.host.cpuCycles, 777); XCTAssertEqual(r.host.hsModeTables["recruit"], [1, 2, 3])
        XCTAssertEqual(r.host.runAssist, ["trainer"]); XCTAssertEqual(r.host.hsActiveMode, "assisted")
        XCTAssertEqual(try GameSnapshot.readInfo(d).label, "Quick save")
    }

    func testRestoreIntoMachineReproducesState() throws {
        let s = try sampleSnapshot()
        let m = Machine(disk: try Disk(data: [UInt8](repeating: 0, count: 160 * Disk.trackSize)))
        m.startResumed(from: s.machine) { _ in }
        let c = m.captureState()
        var a = SnapWriter(), b = SnapWriter()
        c.encode(into: &a); s.machine.encode(into: &b)
        XCTAssertEqual(a.data, b.data, "restoreState/captureState must round-trip every field")
        XCTAssertEqual(m.frameCount, s.machine.frameCount)
        m.stop()
    }

    func testRejectsGarbageAndOtherDisks() throws {
        XCTAssertThrowsError(try GameSnapshot.decode(Data([1, 2, 3])))
        var d = try sampleSnapshot().encoded()
        d[d.count - 5] ^= 0xff
        XCTAssertThrowsError(try GameSnapshot.decode(d))
        let s = try sampleSnapshot()
        var other = [UInt8](repeating: 0, count: 160 * Disk.trackSize); other[99] = 1
        XCTAssertThrowsError(try s.compatibility(with: try Disk(data: other)))
    }
}
