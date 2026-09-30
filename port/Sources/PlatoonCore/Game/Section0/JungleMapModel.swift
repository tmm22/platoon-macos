// M6 jungle & village mini-map model (owner: section0). READ-ONLY: a schematic of the section-0 map computed from
// RAM (the disk is the only data source; nothing is bundled) for the app's overlay (PlatoonApp/Overlay/JungleMap.swift).
//
//   map      $1b000 + level*$10e + row*90 + col   (6 strips x 3 tile rows x 90 columns; row 2 = ground)
//   attrs    $5dc00 + tile*$30                    (6 x 8 cells per tile; solid = $b0, $da, $c0..$d0, as solid_at)
//   doors    $1aaf4 (hut 5..0 door columns), search spots $1aafa (20 x {lo, hi, msg, msg_after})
//   player   level $60c2a (plevel), world x $60c30 (8-px units), facing $5f886, state $5f89a
//
// Levels 0..4 are the jungle strips (0 = rearmost, contains the village street; 1 = front, the start); level 5 is the
// hut-interior overlay of level 0. Bottom-row tile 3 = path up (to level-1), 4 = path down (to level+1).

import Foundation

public struct JungleMapModel: Equatable {
    public static let columns = 90
    public static let cells = 90 * 8           // 8-px cells per strip (world x in the units of $60c30)

    public struct Strip: Equatable {
        /// Per 8-px cell: solid at the player's probe height (a tree or wall the player can't walk through).
        public var blocked: [Bool]
        /// Columns with a path up / down (bottom-row tile 3 / 4).
        public var up: [Int], down: [Int]
        /// Columns of river tiles (level 1, bottom-row tiles $87..$97) and the bridge planks ($47/$48).
        public var water: [Int]
    }

    public enum SpotKind: String { case torch, map, boobyTrap, food, other }
    /// A hut search spot (one entry of the search table with a reachable position).
    public struct Spot: Equatable {
        public var entry: Int
        /// Hut 0..5 and the world x ($60c30) where searching (UP inside the hut) triggers it.
        public var hut: Int, worldX: Int
        public var kind: SpotKind
        /// Message shown when searching (decoded).
        public var text: String
    }

    public var strips: [Strip] = []
    /// Door column of hut 0..5.
    public var hutDoors: [Int] = []
    /// World-x span inside each hut (from the level-5 walls; walk limits of re/village §a.1).
    public static let hutSpans: [ClosedRange<Int>] = [0x18c...0x196, 0x1b4...0x1c6, 0x1e4...0x1ee, 0x20c...0x216, 0x23c...0x24e, 0x26c...0x276]
    /// Hut 1 trap door (T = $35, $60c34 = 0 -> $60c30 = $1c4).
    public static let trapDoorWorldX = 0x1c4
    public var spots: [Spot] = []

    /// Items of the jungle (fixed by the section code, re/jungle §h.9, re/village §b.11).
    public static let explosivesLevel = 4, explosivesCols = 0x31...0x35
    public static let bridgeLevel = 1, bridgeCols = 0x47...0x48, doomCol = 0x4e, villageAccessCol = 0x54

    static func solid(_ c: UInt8) -> Bool { c == 0xb0 || c == 0xda || (c >= 0xc0 && c <= 0xd0) }

    /// Builds the schematic from RAM (section 0 must be loaded).
    public static func build(_ mem: Memory) -> JungleMapModel {
        var m = JungleMapModel()
        for level in 0...4 {
            let base = 0x1b000 + UInt32(level * 0x10e)
            var blocked = [Bool](repeating: false, count: cells)
            var up: [Int] = [], down: [Int] = [], water: [Int] = []
            for col in 0..<columns {
                let mid = UInt32(mem.r8(base + 90 + UInt32(col)))
                let attr = 0x5dc00 + mid * 0x30 + 5 * 8           // cell row 5 of the middle tile row (probe y $58)
                for x in 0..<8 where solid(mem.r8(attr + UInt32(x))) { blocked[col * 8 + x] = true }
                let bottom = mem.r8(base + 180 + UInt32(col))
                if bottom == 3 { up.append(col) }
                if bottom == 4 { down.append(col) }
                if level == 1 && bottom >= 0x87 && bottom <= 0x97 { water.append(col) }
            }
            m.strips.append(Strip(blocked: blocked, up: up, down: down, water: water))
        }
        // $1aaf4 lists the door columns of huts 5..0
        m.hutDoors = (0..<6).map { Int(mem.r8(0x1aaf4 + UInt32(5 - $0))) }
        m.spots = spots(mem)
        return m
    }

    /// The search spots as they are in RAM now (a fired booby trap has become a flavour entry).
    public static func spots(_ mem: Memory) -> [Spot] {
        var out: [Spot] = []
        for i in 0..<20 {
            let a = 0x1aafa + UInt32(4 * i)
            let lo = Int(mem.r8(a)), hi = Int(mem.r8(a + 1)), msg = mem.r8(a + 2), after = mem.r8(a + 3)
            guard lo <= hi, let v = (lo...hi).first(where: { $0 & 1 == 1 && $0 != 0xff }) else { continue }
            let wx = 0x18f + v
            guard let hut = hutSpans.firstIndex(where: { $0.contains(wx) }) else { continue }
            let kind: SpotKind
            switch msg {
            case 0x10: kind = .torch
            case 0x17: kind = .map
            case 0x0f: kind = .boobyTrap
            case 0x01, 0x03, 0x09, 0x0a: kind = .food
            default: kind = .other
            }
            let shown = kind == .torch ? 0x02 : kind == .map ? 0x08 : kind == .boobyTrap ? 0x0f : Int(after)
            out.append(Spot(entry: i, hut: hut, worldX: wx, kind: kind, text: message(mem, shown)))
        }
        return out
    }

    /// Decoded section-0 HUD message `n` (table $1a6de).
    public static func message(_ mem: Memory, _ n: Int) -> String {
        let p = mem.r32(0x1a6de + UInt32(4 * (n & 0xff)))
        guard p >= 0x17000 && p < 0x20000 else { return "" }
        return PrintText.decode(mem, p)
    }

    /// Cheap change detector for the parts of the map the game patches at run time (bridge tiles, search table).
    public static func signature(_ mem: Memory) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ b: UInt8) { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        mix(mem.r8(0x1b209)); mix(mem.r8(0x1b20a))
        for i in 0..<0x50 { mix(mem.r8(0x1aafa + UInt32(i))) }
        return h
    }
}

/// Where the player is on the jungle map (read from RAM every frame; section 0 only).
public struct JunglePlayer: Equatable {
    /// Strip 0..4, or 5 inside a hut (then `hut` is set; drawn on strip 0).
    public var level: Int
    /// World x in 8-px units ($60c30) and map column ($60c28).
    public var worldX: Int, column: Int
    public var facingLeft: Bool
    public var hut: Int?
    public var state: Int
    /// Items: explosives carried ($28(a6)), bridge 0 intact / 1 charge set / 2 blown, torch ($60cbd), map ($24(a6)),
    /// hut-2 guard killed ($60c70).
    public var explosives: Bool, bridge: Int, torch: Bool, map: Bool, guardKilled: Bool

    public static func read(_ mem: Memory) -> JunglePlayer {
        let lvl = Int(mem.r16(0x60c2a))
        return JunglePlayer(level: lvl, worldX: Int(mem.r16(0x60c30)), column: Int(mem.r16(0x60c28)),
                            facingLeft: mem.r16(0x5f886) != 0, hut: lvl == 5 ? Int(mem.r16(0x60c40)) : nil,
                            state: Int(mem.r16(0x5f89a)), explosives: mem.r16(0x12e06) != 0, bridge: Int(mem.r16(0x60c9c)),
                            torch: mem.r8(0x60cbd) != 0, map: mem.r16(0x12e02) != 0, guardKilled: mem.r16(0x60c70) != 0)
    }
}
