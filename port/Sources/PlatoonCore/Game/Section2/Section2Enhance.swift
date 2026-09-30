import Foundation
// Section 2 enhancement helpers (owner: section2). The hooks themselves are in FinalJungle.swift / Foxhole.swift at
// `// ENHANCEMENT <ID>` sites; with every option at its default they execute the original code path unchanged
// (M10 knobs are read as `knob ?? <literal>`, random draws are clamped after the original k_random() call).
// Options: Enhance/Section2Options.swift (s2.*) and Enhance/GameplayOptions.swift (game.lives / game.fullPlatoon).

extension Platoon {
    /// Section-2 options of this run.
    @inline(__always) var s2Opt: Section2Options { enhancements.section2 }
    /// M10 knobs (preset resolved at game start).
    @inline(__always) var s2Diff: Section2Difficulty { enhancements.section2.difficulty }

    /// M10: timer value (BCD mm:ss word) for `seconds`.
    static func s2_bcdTimer(seconds s: Int) -> UInt16 {
        let v = max(0, min(59 * 60 + 59, s))
        let mm = v / 60, ss = v % 60
        let hi: Int = (mm / 10) << 12 | (mm % 10) << 8
        let lo: Int = (ss / 10) << 4 | ss % 10
        return UInt16(hi | lo)
    }

    /// M10 sniper: idle-shot countdown after a depth change ($32) and after a room entry / hit / shot ($64).
    @inline(__always) func s2_idleReset() -> UInt16 { s2Diff.sniperDelay.map { UInt16(min($0, 0x7fff)) } ?? 0x32 }
    @inline(__always) func s2_idleLong() -> UInt16 { s2Diff.sniperDelay.map { UInt16(min(2 * $0, 0xfffe)) } ?? 0x64 }

    /// M15: the man who takes over when the current one is killed, or nil (= the platoon is destroyed).
    /// Records usable in section 2: 0..<lives (fresh, re-initialised at the section start), or with game.fullPlatoon
    /// all 5 records carried over from the jungle (lives is then not used: the jungle decided who is left).
    /// The next man is the first record after the current one that has fewer than 4 wounds.
    func s2_nextMan() -> Int? {
        let n = enhancements.game.fullPlatoon ? 5 : max(2, min(5, enhancements.game.lives))
        let cur = Int(mem.r16(a6 &+ 0x22))
        guard cur + 1 < n else { return nil }
        return ((cur + 1)..<n).first { mem.r16(a6 &+ UInt32(6 * $0) &+ 4) < 4 }
    }

    /// M15 (full platoon): first living man at the section start, nil if nobody is alive.
    func s2_firstLivingMan() -> Int? {
        (0..<5).first { mem.r16(a6 &+ UInt32(6 * $0) &+ 4) < 4 }
    }
}

// MARK: - verification log (off by default; PLATOON_S2NAV=<file>)

/// Verification aid (not game logic, off by default, no RAM writes, no CPU-time charges): PLATOON_S2NAV=<file> makes
/// the section log, at every room entry, the room, heading, exits and the navigator's (FinalJungleMaze) shortest
/// route, and after every picture decode whether the host renderer (FinalJungleRenderer) reproduces the game's
/// decoded background at $68000 exactly and, at the first drawn tick of a room, the drawn playfield (static objects
/// + player). Used by port/verify/section2/enh/run_enh.sh.
let s2NavLog: FileHandle? = {
    guard let p = ProcessInfo.processInfo.environment["PLATOON_S2NAV"] else { return nil }
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
}()
/// Main-loop ticks until the drawn-room check (host-side verification state only; 0 = none pending).
var s2NavDrawCountdown = 0

extension Platoon {
    func s2_navWrite(_ s: String) { s2NavLog?.write((s + "\n").data(using: .utf8)!) }

    /// Room entered (room_enter_done $170f4): log the state and the route the navigator suggests.
    func s2_navLogRoom() {
        let maze = FinalJungleMaze(memory: mem)
        let st = FinalJungleMaze.State(room: Int(mem.r8(Platoon.S2.vRoom)), dirs: mem.r32(Platoon.S2.vDirs))
        let route = maze.route(from: st).map { $0.map(\.rawValue).joined() } ?? "none"
        let h = st.heading?.letter ?? "?"
        s2_navWrite(String(format: "f%d room %d heading %@ compass %d exits %d type %d route %@ dist %d",
                           m.frameCount, st.room, h, Int(mem.r16(a6 &+ 0x2a)), Int(mem.r8(Platoon.S2.vExits)),
                           Int(mem.r8(Platoon.S2.vRoomType)), route, maze.route(from: st)?.count ?? -1))
        s2NavDrawCountdown = 2
    }

    /// Picture decoded ($1764e): compare the host decoder with the game's background.
    func s2_navLogDecode() {
        let t = Int(mem.r8(Platoon.S2.vRoomType))
        let pic = Int(mem.r8(Platoon.S2.typePic &+ UInt32(t)))
        let host = FinalJungleRenderer.decodePlanes(mem, picture: pic)
        var diff = 0
        for p in 0..<4 { for i in 0..<0x17c0 where host[p * 0x2000 + i] != mem.r8(0x68000 &+ UInt32(p * 0x2000 + i)) { diff += 1 } }
        s2_navWrite("f\(m.frameCount) decode picture \(pic) type \(t) \(diff == 0 ? "OK" : "DIFF \(diff) bytes")")
    }

    /// Main-loop head: at the second tick of a room the buffer drawn by the first tick is displayed; compare it
    /// with the host rendering of the room (background + static objects), outside the player's bob.
    func s2_navLogDrawn() {
        guard s2NavDrawCountdown > 0 else { return }
        s2NavDrawCountdown -= 1
        guard s2NavDrawCountdown == 0 else { return }
        let t = Int(mem.r8(Platoon.S2.vRoomType))
        var host = FinalJungleRenderer.room(mem, roomType: t, player: false)
        // Barnes faces the player: use his current frame
        if t == FinalJungleMaze.bunkerType {
            host = FinalJungleRenderer.indexed(planes: FinalJungleRenderer.decodePlanes(mem, picture: Int(mem.r8(Platoon.S2.typePic &+ UInt32(t)))))
            var bobs = FinalJungleRenderer.staticObjects(mem, roomType: t)
            bobs.insert(.init(slot: 4, dir: 0x47628, frame: Int(mem.r8(Platoon.S2.slot4 &+ 0x10)), x: 0x96, depth: 0x69), at: 0)
            FinalJungleRenderer.draw(mem, bobs, into: &host)
        }
        let front: UInt32 = mem.r32(a6 &+ 0x62) == 0x70000 ? 0x78000 : 0x70000
        var planes = [UInt8](repeating: 0, count: 4 * 0x2000)
        for p in 0..<4 { for i in 0..<(144 * 40) { planes[p * 0x2000 + i] = mem.r8(front &+ UInt32(p * 0x2000 + i)) } }
        let game = FinalJungleRenderer.indexed(planes: planes)
        // the player's bob (drawn at his position after the first tick's move) is excluded
        let px = Int(Int16(bitPattern: mem.r16(Platoon.S2.playerX))), py = Int(Int16(bitPattern: mem.r16(Platoon.S2.playerY)))
        var diff = 0, total = 0
        for y in 0..<144 {
            for x in 0..<320 where !(x >= px - 2 && x < px + 50 && y >= 0x8f - py - 64 && y <= 0x8f - py + 2) {
                total += 1
                if host[y * 320 + x] != game[y * 320 + x] { diff += 1 }
            }
        }
        s2_navWrite("f\(m.frameCount) drawn type \(t) \(diff == 0 ? "OK" : "DIFF \(diff)") of \(total) px")
    }
}
