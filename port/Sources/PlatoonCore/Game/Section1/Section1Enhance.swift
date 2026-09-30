import Foundation

// Section-1 enhancements (owner: section1). Helpers for the `// ENHANCEMENT <ID>` sites in Section1.swift,
// Section1Engine.swift, Tunnels.swift and Flare.swift. Options: Enhance/Section1Options.swift (keys "s1.*") and the
// M15 flags game.lives / game.fullPlatoon (Enhance/GameplayOptions.swift).
//
// With every option at its default none of this code runs and nothing here writes RAM (tools/regress_all.sh).
//
// State that must survive a death / loop head lives in RAM (so savestates and rewind capture it without any host
// variable): a scratch block at $3f000, above everything section 1 uses ($3b220-$3d7c4 variables; NOTE the flare
// night's bob blit clears 560x10 words from $3b742, i.e. up to $3e302; $68000 flare picture) and zero in the
// original at that point. It is initialised at section entry ($17000) when an option that
// needs it is on; its first word is a tag so a stale block (e.g. section-0 data left in RAM) is never trusted.

enum S1E {
    static let base: UInt32 = 0x3f000
    /// w tag $5331 ("S1") once initialised at section entry.
    static let tag: UInt32 = base
    /// w flares carried into the flare night (M4: restored on a flare-night retry / return to the tunnels).
    static let flaresAtFlare: UInt32 = base + 2
    /// b $ff while the flare night runs (set at $18b0e, cleared by the next tunnel life start).
    static let inFlare: UInt32 = base + 4
    /// b $ff = a checkpoint exists (M4 checkpoint respawn), w position x<<8|y, w heading.
    static let cpValid: UInt32 = base + 5
    static let cpPos: UInt32 = base + 6
    static let cpDir: UInt32 = base + 8
    /// 43*43 bytes: maze cells seen ($ff) for the explored-map window (M3 variant B).
    static let seen: UInt32 = base + 0x100
    static let tagValue: UInt16 = 0x5331
    /// Blank map-display tile (all planes 0) used for unexplored cells.
    static let blankTile: UInt8 = 32
}

extension Platoon {
    var s1opt: Section1Options { enhancements.section1 }

    /// True when the scratch block was initialised for this section run.
    var s1e_active: Bool { mem.r16(S1E.tag) == S1E.tagValue }

    // MARK: section entry ($17000)

    /// ENHANCEMENT M4/M3/L3 at section entry: scratch block, randomised rooms.
    func s1e_sectionEntry() {
        if s1opt.needsScratch {
            mem.fill(S1E.base, count: 0x100 + 43 * 43)
            mem.w16(S1E.tag, S1E.tagValue)
        }
        if s1opt.randomSeed != 0 { s1e_randomiseRooms(seed: UInt64(s1opt.randomSeed)) }
    }

    // MARK: M15 section-1 men

    /// Men that may play in this section: records 0..<n (original 2; fullPlatoon: all five, dead ones skipped).
    var s1e_menLimit: Int {
        let g = enhancements.game
        return g.fullPlatoon ? 5 : min(max(g.lives, 2), 5)
    }

    /// ENHANCEMENT M15: KIA of the current man -> the next living man (index order after the current one, wrapping),
    /// or the platoon is destroyed.
    func s1e_killedInAction() {
        let cur = Int(mem.r16(a6 + 0x22))
        let n = s1e_menLimit
        let order = Array((cur + 1)..<max(n, cur + 1)) + Array(0..<min(cur, n))
        if let i = order.first(where: { mem.r16(a6 + UInt32(6 * $0) + 4) < 4 }) {
            mem.w16(a6 + 0x22, UInt16(i))
            mem.w32(a6 + 0x1e, a6 + UInt32(6 * i))
            mem.w8(S1.soldierLost, 0xff)
        } else {
            mem.w8(S1.destroyed, 0xff)
        }
    }

    /// ENHANCEMENT M15 (fullPlatoon): keep the carried-over records; the kernel already selected the first living
    /// man (k_section_start). Returns false when nobody is alive (then the original re-init runs).
    func s1e_keepPlatoon() -> Bool {
        guard enhancements.game.fullPlatoon else { return false }
        guard let i = (0..<5).first(where: { mem.r16(a6 + UInt32(6 * $0) + 4) < 4 }) else { return false }
        let cur = Int(mem.r16(a6 + 0x22))
        if cur > 4 || mem.r16(a6 + UInt32(6 * cur) + 4) >= 4 {
            mem.w16(a6 + 0x22, UInt16(i))
            mem.w32(a6 + 0x1e, a6 + UInt32(6 * i))
        } else {
            mem.w32(a6 + 0x1e, a6 + UInt32(6 * cur))
        }
        return true
    }

    // MARK: M4 tunnels fairness

    /// ENHANCEMENT M4 at the tunnel life start ($170c4) after the position/items part: flares back after a lost
    /// flare night (keep items), checkpoint position. Returns true when the item resets must be skipped.
    func s1e_lifeStartKeepItems() -> Bool {
        guard s1opt.keepItems, s1e_active else { return false }
        if mem.r8(S1E.inFlare) != 0 {
            // back from a lost flare night: the flare boxes stay emptied, so give back the flares that were
            // brought (otherwise the exit could never be used again - the roadmap's softlock)
            mem.w16(a6 + 0x2c, mem.r16(S1E.flaresAtFlare))
        }
        return true
    }

    /// ENHANCEMENT M4 checkpoint respawn: position/heading of the next life.
    func s1e_lifeStartPosition() {
        guard s1e_active else { return }
        mem.w8(S1E.inFlare, 0)
        guard s1opt.checkpointRespawn, mem.r8(S1E.cpValid) != 0 else { return }
        mem.w16(S1.posX, mem.r16(S1E.cpPos))
        mem.w16(a6 + 0x2a, mem.r16(S1E.cpDir) & 3)
    }

    /// ENHANCEMENT M4 at room entry ($184c0): the corridor cell in front of the room, facing away from it (as after
    /// leaving the room), is the checkpoint.
    func s1e_roomEntered(before pos: UInt16) {
        guard s1opt.checkpointRespawn, s1e_active else { return }
        mem.w8(S1E.cpValid, 0xff)
        mem.w16(S1E.cpPos, pos)
        mem.w16(S1E.cpDir, (mem.r16(a6 + 0x2a) &+ 2) & 3)
    }

    /// ENHANCEMENT M4 at flare entry ($18b0e): remember the flares brought into the night.
    func s1e_flareEntered() {
        guard s1e_active else { return }
        mem.w16(S1E.flaresAtFlare, mem.r16(a6 + 0x2c))
        mem.w8(S1E.inFlare, 0xff)
    }

    /// ENHANCEMENT M4 flare-night retry: instead of $172f6 exit_back_to_tunnels, show the same "ONE MORE CHANCE"
    /// screen and restart the flare night with the next soldier and the flares that were brought into it.
    func s1e_flareRetry() -> Never {
        s1_textScreenMusic3(S1.txtOneMoreChance)
        mem.w16(a6 + 0x2c, mem.r16(S1E.flaresAtFlare))
        mem.w8(S1.soldierLost, 0)
        mem.w8(S1.destroyed, 0)
        mem.w8(S1.list1, 0)                      // a flare still rising
        mem.w8(S1.lightCycle, 0)
        mem.w16(S1.killBonus, 0)
        mem.w8(S1.enemyHit, 0)
        mem.w8(S1.shotFlag, 0)
        k_set_hud_pal(S1.palHud)
        k_hud_init()
        s1_flareEnter(S1.objs)
    }

    // MARK: M3 variant B: explored map window

    /// Marks the cells the player can see from (x, y) facing `dir` (the view's scans: current cell and its
    /// neighbours, up to 4 cells ahead while the corridor continues, and the side cells along that way).
    func s1e_markSeen() {
        guard s1e_active else { return }
        let x = Int(mem.r8(S1.posX)), y = Int(mem.r8(S1.posY))
        for c in TunnelMaze.visibleCells(x: x, y: y, heading: Int(mem.r16(a6 + 0x2a) & 3), cell: { cx, cy in
            self.mem.r8(S1.maze + UInt32(cy * 43 + cx))
        }) {
            mem.w8(S1E.seen + UInt32(c), 0xff)
        }
    }

    /// The map window is drawn without the map item (the cells that were seen).
    var s1e_exploredWindow: Bool { s1opt.exploredMap && s1e_active }

    // MARK: L3 randomiser

    /// Shuffles, per hotspot position, the item codes of rooms with the same picture type ($19a24): the flare
    /// boxes stay in desk/type-1 rooms, the EXIT stays behind a type-3 door, the "leave" hotspot stays last.
    /// Deterministic in the seed (no k_random call). The item words live in the section data, reloaded per load.
    func s1e_randomiseRooms(seed: UInt64) {
        var rng = SplitMix64(seed: seed ^ 0x5031_5431)
        var byType: [UInt16: [Int]] = [:]
        for k in 0..<10 { byType[mem.r16(S1.roomType + UInt32(2 * k)), default: []].append(k) }
        for t in byType.keys.sorted() {
            let rooms = byType[t]!
            guard rooms.count > 1 else { continue }
            let groups = Int(mem.r16(mem.r32(S1.hotspotsByType + UInt32(4 * t))))
            for g in 0..<max(groups - 1, 0) {
                let addrs = rooms.map { mem.r32(S1.roomItems + UInt32(4 * $0)) + UInt32(2 * g) }
                var vals = addrs.map { mem.r16($0) & ~0x80 }
                for i in stride(from: vals.count - 1, to: 0, by: -1) {
                    let j = Int(rng.next() % UInt64(i + 1))
                    vals.swapAt(i, j)
                }
                for (a, v) in zip(addrs, vals) { mem.w16(a, v) }
            }
        }
    }
}

/// Small deterministic PRNG for the randomiser (independent of the game's RNG).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Read-only helpers on the tunnel maze for the host (automap overlay, M3) and the explored map window.
public enum TunnelMaze {
    public static let size = 43
    public static let mazeAddr: UInt32 = 0x29720
    /// Heading deltas N E S W.
    public static let delta: [(Int, Int)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]

    /// Cell value: 2 corridor, 3 room, anything else wall (the map tile index).
    public static func cell(_ mem: Memory, _ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < size, y < size else { return 0 }
        return mem.r8(mazeAddr + UInt32(y * size + x))
    }

    /// Cell indices (y*43+x) visible from (x, y) facing `heading`: the cell itself and its 8 neighbours, then
    /// forward up to 4 cells while the corridor continues (like draw_view's scan), with the cells to both sides of
    /// each step (and their outer neighbours when they are openings).
    public static func visibleCells(x: Int, y: Int, heading: Int, cell: (Int, Int) -> UInt8) -> [Int] {
        var out: [Int] = []
        func add(_ cx: Int, _ cy: Int) {
            if cx >= 0, cy >= 0, cx < size, cy < size { out.append(cy * size + cx) }
        }
        for dy in -1...1 { for dx in -1...1 { add(x + dx, y + dy) } }
        let (fx, fy) = delta[heading & 3]
        let (lx, ly) = delta[(heading + 3) & 3]
        var cx = x, cy = y
        for _ in 0..<4 {
            cx += fx; cy += fy
            guard cx >= 0, cy >= 0, cx < size, cy < size else { break }
            add(cx, cy)
            for s in [1, -1] {
                let sx = cx + s * lx, sy = cy + s * ly
                add(sx, sy)
                if cell(sx, sy) == 2 { add(sx + s * lx, sy + s * ly); add(sx + fx, sy + fy); add(sx - fx, sy - fy) }
            }
            add(cx + fx, cy + fy)
            if cell(cx, cy) != 2 { break }
        }
        return out
    }

    /// One tunnel room: entry cell, picture type and its item codes (hotspot order, last = leave).
    public struct Room: Equatable {
        public var index: Int
        public var entryX: Int, entryY: Int
        public var type: Int
        /// Item code per hotspot (message index; see `itemName`) and whether it was taken (bit 7).
        public var items: [(code: Int, taken: Bool)]
        public static func == (a: Room, b: Room) -> Bool {
            a.index == b.index && a.entryX == b.entryX && a.entryY == b.entryY && a.type == b.type
                && a.items.map { $0.code } == b.items.map { $0.code } && a.items.map { $0.taken } == b.items.map { $0.taken }
        }
    }

    /// The 10 rooms as currently in RAM (section 1 must be loaded).
    public static func rooms(_ mem: Memory) -> [Room] {
        (0..<10).map { k in
            let e = mem.r16(0x19aec + UInt32(2 * k))
            let t = Int(mem.r16(0x19a24 + UInt32(2 * k)))
            let groups = Int(mem.r16(mem.r32(0x19b00 + UInt32(4 * (t & 3)))))
            let list = mem.r32(0x19a38 + UInt32(4 * k))
            let items = (0..<min(groups, 8)).map { g -> (code: Int, taken: Bool) in
                let w = mem.r16(list + UInt32(2 * g))
                return (code: Int(w & 0x7f), taken: w & 0x80 != 0)
            }
            return Room(index: k, entryX: Int(e >> 8), entryY: Int(e & 0xff), type: t, items: items)
        }
    }

    /// Short names of the item codes (message indices $00-$16 of the tunnel text table).
    public static func itemName(_ code: Int) -> String {
        switch code {
        case 0x00: return "leave"
        case 0x01: return "map"
        case 0x02: return "tea"
        case 0x03: return "poetry"
        case 0x04: return "flares"
        case 0x05: return "documents"
        case 0x06: return "empty"
        case 0x07: return "boots"
        case 0x08: return "broken device"
        case 0x09: return "diary"
        case 0x0a: return "food"
        case 0x0b: return "drawer"
        case 0x0c: return "ammo"
        case 0x0d: return "medical kit"
        case 0x0e: return "weapons"
        case 0x0f: return "blocked exit"
        case 0x10: return "handbook"
        case 0x11: return "compass"
        case 0x12: return "Roman Empire"
        case 0x13: return "cards"
        case 0x14: return "combat manual"
        case 0x15: return "EXIT"
        case 0x16: return "?"
        default: return String(format: "$%02x", code)
        }
    }

    /// Items worth showing on a map (flares, compass, map, EXIT, ammo, medical kit).
    public static func isKeyItem(_ code: Int) -> Bool { [0x01, 0x04, 0x0c, 0x0d, 0x11, 0x15].contains(code) }
}
