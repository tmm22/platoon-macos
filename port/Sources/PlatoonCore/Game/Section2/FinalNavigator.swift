import Foundation
// Section 2 host-side model (owner: section2): READ-ONLY views of the final jungle for the M5 navigator and the M25
// room slide (app overlays PlatoonApp/Overlay/Final*.swift). Nothing here writes game RAM or is called by the
// translated game (except the opt-in PLATOON_S2NAV verification log, Section2Enhance.swift).
//
// Everything is computed from RAM (the disk is the only data source): the room map $18ea4 (12 rows x 10 columns,
// one room type per cell), exits per type $18f2e, picture per type $18f1d, the current room $18f1c and the direction
// long $18f40 = signed room offsets [R, B, L, F] of the current heading. The room transitions are the exact ones of
// trans_right ($18192: room += R, dirs rol 8) and trans_left ($181b4: room += L, dirs ror 8), byte arithmetic.
// The BFS was validated against re/finaljungle/assets/maze_graph.json (Tests/PlatoonCoreTests/FinalJungleTests).

/// Heading in the final jungle (the HUD compass $2a(a6): 0 N, 1 E, 2 S, 3 W; "north" = up in the room map).
public enum FinalJungleHeading: Int, CaseIterable {
    case north, east, south, west
    public var letter: String { ["N", "E", "S", "W"][rawValue] }
    public var name: String { ["north", "east", "south", "west"][rawValue] }
    /// Heading from the direction long (F = its low byte: -10 N, +1 E, +10 S, -1 W).
    public init?(dirs: UInt32) {
        switch Int8(bitPattern: UInt8(dirs & 0xff)) {
        case -10: self = .north
        case 1: self = .east
        case 10: self = .south
        case -1: self = .west
        default: return nil
        }
    }
    /// Map step (dx, dy) when moving forward.
    public var delta: (dx: Int, dy: Int) { [(0, -1), (1, 0), (0, 1), (-1, 0)][rawValue] }
}

/// The final-jungle maze as the game sees it.
public struct FinalJungleMaze: Equatable {
    public static let columns = 10, rows = 12
    public static let startRoom = 0x69
    public static let startDirs: UInt32 = 0x010afff6
    /// Depth from which the side exits can be taken (pl_move: `y s>= $5a`).
    public static let exitDepth = 0x5a
    /// Barnes' room type.
    public static let bunkerType = 16

    public enum Exit: String { case left = "L", right = "R" }
    public struct State: Hashable, CustomStringConvertible {
        public var room: Int
        public var dirs: UInt32
        public init(room: Int, dirs: UInt32) { self.room = room; self.dirs = dirs }
        public var heading: FinalJungleHeading? { FinalJungleHeading(dirs: dirs) }
        public var description: String { "\(room)\(heading?.letter ?? "?")" }
    }

    /// Room type of each of the 120 cells ($18ea4).
    public var types: [UInt8]
    /// Exit mask per room type ($18f2e): bit0 left, bit1 right, 0 = bunker room.
    public var exitsByType: [UInt8]
    /// Background picture (1..10) per room type ($18f1d).
    public var pictureByType: [UInt8]

    public init(types: [UInt8], exitsByType: [UInt8], pictureByType: [UInt8]) {
        self.types = types; self.exitsByType = exitsByType; self.pictureByType = pictureByType
    }

    /// Reads the maze from section-2 RAM (valid while section 2 is loaded).
    public init(memory m: Memory) {
        types = (0..<120).map { m.r8(0x18ea4 + UInt32($0)) }
        exitsByType = (0..<17).map { m.r8(0x18f2e + UInt32($0)) }
        pictureByType = (0..<17).map { m.r8(0x18f1d + UInt32($0)) }
    }

    /// Room type of room index `room` (byte index into the map, like room_setup: `$18ea4[d0 & $ff]`).
    public func type(ofRoom room: Int) -> Int {
        let i = room & 0xff
        return i < types.count ? Int(types[i]) : 0
    }
    /// Exit mask of a room (bit0 left, bit1 right; 0 = the bunker room).
    public func exits(ofRoom room: Int) -> Int {
        let t = type(ofRoom: room)
        return t < exitsByType.count ? Int(exitsByType[t]) : 0
    }
    public func isBunker(_ room: Int) -> Bool { exits(ofRoom: room) == 0 }
    public func picture(ofRoom room: Int) -> Int {
        let t = type(ofRoom: room)
        return t < pictureByType.count ? Int(pictureByType[t]) : 0
    }

    /// The state after leaving `s` by exit `e` (trans_right / trans_left).
    public func next(_ s: State, _ e: Exit) -> State {
        switch e {
        case .right:
            let r = UInt8(truncatingIfNeeded: s.room) &+ UInt8(s.dirs >> 24)
            return State(room: Int(r), dirs: s.dirs << 8 | s.dirs >> 24)
        case .left:
            let r = UInt8(truncatingIfNeeded: s.room) &+ UInt8((s.dirs >> 8) & 0xff)
            return State(room: Int(r), dirs: s.dirs >> 8 | s.dirs << 24)
        }
    }

    /// The exits usable in `s` and where they lead.
    public func successors(_ s: State) -> [(exit: Exit, to: State)] {
        let e = exits(ofRoom: s.room)
        var r: [(Exit, State)] = []
        if e & 1 != 0 { r.append((.left, next(s, .left))) }
        if e & 2 != 0 { r.append((.right, next(s, .right))) }
        return r
    }

    /// Shortest exit sequence from `s` to a bunker room (BFS over (room, heading) states); [] when `s` is a bunker
    /// room, nil when no bunker is reachable. Ties: left before right.
    public func route(from s: State) -> [Exit]? {
        if isBunker(s.room) { return [] }
        var prev: [State: (State, Exit)] = [:]
        var queue = [s], head = 0
        var seen: Set<State> = [s]
        while head < queue.count {
            let c = queue[head]; head += 1
            for (e, n) in successors(c) where !seen.contains(n) {
                seen.insert(n); prev[n] = (c, e); queue.append(n)
                if isBunker(n.room) {
                    var path: [Exit] = [], x = n
                    while let (p, pe) = prev[x] { path.append(pe); x = p }
                    return path.reversed()
                }
            }
        }
        return nil
    }

    /// Every state reachable from `s` (incl. `s`) with its successors (for maps / tests).
    public func reachable(from s: State = State(room: startRoom, dirs: startDirs)) -> [State: [(exit: Exit, to: State)]] {
        var out: [State: [(exit: Exit, to: State)]] = [:]
        var queue = [s], head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            if out[c] != nil { continue }
            let succ = successors(c)
            out[c] = succ
            for (_, n) in succ where out[n] == nil { queue.append(n) }
        }
        return out
    }
}

/// Live read-only view of the final jungle (host side, e.g. in Machine.frameHook).
public struct FinalJungleLive: Equatable {
    public var room: Int
    public var dirs: UInt32
    /// HUD compass $2a(a6) (0..3) and whether the compass is carried ($26(a6)).
    public var compass: Int
    public var hasCompass: Bool
    /// Exit mask of the room ($57f44; 0 = bunker room).
    public var exits: Int
    /// Player position (slot 0): x, depth (0 = nearest; exits usable from $5a).
    public var playerX: Int, playerDepth: Int
    /// Barnes' hit points (bunker room, slot 4 byte 0).
    public var barnesHP: Int
    /// A room change is in progress: the level-3 fade hook is installed or the top palette is the fade palette.
    public var transition: Bool
    /// Top palette pointer $5a(a6) and back buffer $62(a6) (for presentation timing).
    public var topPalette: UInt32, backBuffer: UInt32

    public var state: FinalJungleMaze.State { .init(room: room, dirs: dirs) }
    public var heading: FinalJungleHeading? { FinalJungleHeading(dirs: dirs) }
    public var atFarEnd: Bool { playerDepth >= FinalJungleMaze.exitDepth }

    public static func read(_ m: Memory) -> FinalJungleLive {
        let a6 = Platoon.a6
        let pal = m.r32(a6 + 0x5a)
        return FinalJungleLive(room: Int(m.r8(0x18f1c)), dirs: m.r32(0x18f40), compass: Int(m.r16(a6 + 0x2a) & 3),
                               hasCompass: m.r16(a6 + 0x26) != 0, exits: Int(m.r8(0x57f44)),
                               playerX: Int(m.s16(0x57e24)), playerDepth: Int(m.s16(0x57e26)), barnesHP: Int(m.r8(0x57e6a)),
                               transition: m.r32(0x6c) == 0x172c2 || pal == 0x57f70, topPalette: pal, backBuffer: m.r32(a6 + 0x62))
    }
}

/// Host-side renderer of final-jungle rooms (M25 room slide): the game's RLE picture decoder ($17604), its bob
/// cookie-cut (draw_bob $17850) and depth sort, reproduced read-only into a 320x144 image.
public enum FinalJungleRenderer {
    public static let width = 320, height = 144
    /// Game palette $18fc2 (playfield colours).
    public static let paletteAddr: UInt32 = 0x18fc2

    /// Decodes picture n (1..10) exactly like room_load_picture: 4 planes of $17c0 bytes (152 rows x 40 bytes).
    public static func decodePlanes(_ m: Memory, picture n: Int) -> [UInt8] {
        guard (1...10).contains(n) else { return [UInt8](repeating: 0, count: 4 * 0x17c0) }
        var out = [UInt8](repeating: 0, count: 4 * 0x2000)
        var a1 = m.r32(0x18f9a + UInt32(n - 1) * 4) &+ 0x19400
        for p in 0..<4 {
            var o = p * 0x2000, left = 0x17c0
            let esc = m.r8(a1); a1 &+= 1
            while left > 0 {
                let b = m.r8(a1); a1 &+= 1
                if b != esc { out[o] = b; o += 1; left -= 1; continue }
                let v = m.r8(a1), c = m.r8(a1 &+ 1); a1 &+= 2
                var cnt = c == 0 ? 256 : Int(c)
                while cnt > 0 && left > 0 { out[o] = v; o += 1; left -= 1; cnt -= 1 }
            }
        }
        return out
    }

    /// Palette (0xFFRRGGBB) of 16 Amiga colour words at `addr`.
    public static func palette(_ m: Memory, _ addr: UInt32 = paletteAddr) -> [UInt32] {
        (0..<16).map { i in
            let c = UInt32(m.r16(addr + UInt32(2 * i)))
            return 0xff000000 | ((c >> 8) & 0xf) * 0x11 << 16 | ((c >> 4) & 0xf) * 0x11 << 8 | (c & 0xf) * 0x11
        }
    }

    /// Palette indices (320 x 144) of 4 planes laid out $2000 apart with 40 bytes per row.
    public static func indexed(planes: [UInt8]) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for xb in 0..<40 {
                let o = y * 40 + xb
                let b0 = planes[o], b1 = planes[o + 0x2000], b2 = planes[o + 0x4000], b3 = planes[o + 0x6000]
                for bit in 0..<8 {
                    let s = 7 - bit
                    let v = (b0 >> s) & 1 | ((b1 >> s) & 1) << 1 | ((b2 >> s) & 1) << 2 | ((b3 >> s) & 1) << 3
                    px[y * width + xb * 8 + bit] = v
                }
            }
        }
        return px
    }

    /// One object to draw: bob directory (+6 of a slot), frame (+$10), anim (+1), x, depth.
    public struct Bob { public var slot: Int, dir: UInt32, frame: Int, anim: Int, x: Int, depth: Int
        public init(slot: Int, dir: UInt32, frame: Int, anim: Int = 0, x: Int, depth: Int) {
            self.slot = slot; self.dir = dir; self.frame = frame; self.anim = anim; self.x = x; self.depth = depth
        }
    }

    /// The static objects room_spawn_objects puts into slots 10.. for room type `t` (room list $18866).
    public static func staticObjects(_ m: Memory, roomType t: Int) -> [Bob] {
        var a0 = m.r32(0x18866 + UInt32(t) * 4)
        var r: [Bob] = []
        for _ in 0..<16 {
            let ty = m.r16(a0); a0 &+= 2
            if Int16(bitPattern: ty) < 0 { break }
            let o = UInt32(ty) << 2
            r.append(Bob(slot: 10 + r.count, dir: m.r32(0x188aa + o), frame: 0, x: Int(m.s16(a0)), depth: Int(m.s16(a0 + 2))))
            a0 &+= 4
        }
        return r
    }

    /// The player as he stands at a room entry (slot 0: x $a0, depth 0, standing frame 4).
    public static let playerAtEntry = Bob(slot: 0, dir: 0x47400, frame: 4, x: 0xa0, depth: 0)

    /// Draws bobs into `px` (320x144 indices) in the game's painter order: objects_update_draw inserts slots 15..0
    /// into 256 depth buckets (key = depth & $ff, linear probe upwards) and objects_draw paints bucket $ff down to 0.
    /// Pixels outside the image are dropped (the original wraps into the next row; not reached by room objects).
    public static func draw(_ m: Memory, _ bobs: [Bob], into px: inout [UInt8]) {
        var buckets = [Int?](repeating: nil, count: 512)
        for (i, o) in bobs.enumerated().sorted(by: { $0.element.slot > $1.element.slot }) {
            var k = o.depth & 0xff
            while k < 511 && buckets[k] != nil { k += 1 }
            buckets[k] = i
        }
        for k in stride(from: 255, through: 0, by: -1) {
            guard let i = buckets[k] else { continue }
            let o = bobs[i]
            let e = UInt32((o.anim & 7) >> 1 + o.frame) & 0xff
            let hdr = m.r32(o.dir &+ e << 3) &+ 0x47700
            let words = Int(m.r16(hdr)) + 1, rows = Int(m.r16(hdr + 2)) + 1
            var top = 0x8f - o.depth - Int(m.r16(o.dir + 6))
            if top < 0 { top = 0 }                       // negative rows read the zero longs below the row table
            let mask = hdr + 4
            let plane = rows * words * 2
            for r in 0..<rows {
                let y = top + r
                if y >= height { break }
                for w in 0..<words {
                    let off = UInt32((r * words + w) * 2)
                    let mw = m.r16(mask + off)
                    if mw == 0 { continue }
                    let p0 = m.r16(mask + off + UInt32(plane)), p1 = m.r16(mask + off + UInt32(2 * plane))
                    let p2 = m.r16(mask + off + UInt32(3 * plane)), p3 = m.r16(mask + off + UInt32(4 * plane))
                    for bit in 0..<16 where mw & (0x8000 >> bit) != 0 {
                        let x = o.x + w * 16 + bit
                        guard x >= 0, x < width else { continue }
                        let s = UInt16(15 - bit)
                        let v = (p0 >> s) & 1 | ((p1 >> s) & 1) << 1 | ((p2 >> s) & 1) << 2 | ((p3 >> s) & 1) << 3
                        px[y * width + x] = UInt8(v)
                    }
                }
            }
        }
    }

    /// The room of type `t` as the game shows it right after entering: background, static objects and (optionally)
    /// the player at the entry. Palette indices, 320 x 144.
    public static func room(_ m: Memory, roomType t: Int, player: Bool = true) -> [UInt8] {
        let pic = Int(m.r8(0x18f1d + UInt32(t)))
        var px = indexed(planes: decodePlanes(m, picture: pic))
        var bobs = staticObjects(m, roomType: t)
        if t == FinalJungleMaze.bunkerType {        // Barnes (room_setup_bunker): x $96, depth $69, frame by player x
            bobs.insert(Bob(slot: 4, dir: 0x47628, frame: 2, x: 0x96, depth: 0x69), at: 0)
        }
        if player { bobs.append(playerAtEntry) }
        draw(m, bobs, into: &px)
        return px
    }

    /// RGB image (0xFFRRGGBB) of palette indices.
    public static func rgb(_ px: [UInt8], palette: [UInt32]) -> [UInt32] { px.map { palette[Int($0 & 15)] } }
}
