import Foundation

// L2 pointer aiming for the crosshair parts of section 1 (owner: section1; the input agent drives it).
//
// (b) DIRECT aiming (gameplay option `s1.directAim`, default off): while a target is set, the crosshair handlers
//     ($1858c in_combat, $18654 in_room, $19048 flare h_crosshair) first move the crosshair onto the target (with the
//     original bounds) and ignore the stick directions; fire, recoil jitter, hit tests and room clicks are unchanged.
//     The host sets the target from the game thread's point of view once per frame (e.g. in Machine.frameHook /
//     AppServices.onFrame, game parked):
//
//         TunnelAim.setTarget(machine, x: vx, y: vy)     // visible-screen lowres coords of the crosshair CENTRE
//         TunnelAim.clearTarget(machine)                 // back to the stick
//
//     Coordinates are the overlay's visible-screen system (OverlayLayout.point(x:y:): x 0..319 from DIW h $71,
//     y 0..255 from line $2c). Section-1 bitplane pixel (px, py) is visible (px, py + 16); the crosshair object's
//     (x, y) is its top-left, its centre (the point the hit tests use) is +9,+9, and tunnel objects are drawn from
//     byte column $3b3f8 (0 with the map window, 10 without).
// (a) ASSISTED aiming (host-only, no option): read `TunnelAim.info(memory, area:)` every frame and press the virtual
//     stick toward the target; `Info.centre` is where the crosshair is now and `Info.bounds` where it can go.
//
// Headless test hook: PLATOON_S1_AIM="FRAME:X,Y;FRAME:X,Y;FRAME:-" sets (or clears, "-") the target from that
// emulated frame on (used by port/verify/enh-section1).

public enum TunnelAim {
    public enum Mode: String {
        /// Tunnels with an enemy / shot / live room guard: fast crosshair, auto-fire.
        case tunnelCombat
        /// Tunnel room search: slow cursor, fire clicks a hotspot.
        case tunnelRoom
        /// Flare night dugout.
        case flare
    }

    public struct Info: Equatable {
        public var mode: Mode
        /// Crosshair centre now (visible-screen lowres coordinates).
        public var centre: (x: Double, y: Double)
        /// Reachable centre positions (visible-screen coordinates, inclusive).
        public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)
        public static func == (a: Info, b: Info) -> Bool {
            a.mode == b.mode && a.centre == b.centre && a.bounds == b.bounds
        }
    }

    /// Visible-screen y of bitplane line 0 in section 1 (DIWSTRT $3c71 vs the overlay's line $2c).
    static let lineOffset = 0x3c - 0x2c
    /// Crosshair centre offset from the object position (hit tests use x+9, y+9).
    static let centreOffset = 9
    static let tunnelBounds = (minX: 0, minY: 0, maxX: 0x8d, maxY: 0x7d)
    static let flareBounds = (minX: 0x1e, minY: 0x0a, maxX: 0x10e, maxY: 0x78)

    // MARK: host API

    private static let lock = NSLock()
    private static var targets: [ObjectIdentifier: (x: Double, y: Double)] = [:]

    /// Sets the direct-aim target (crosshair centre, visible-screen lowres coordinates) of the game on `m`.
    public static func setTarget(_ m: Machine, x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        if targets.count > 8 { targets.removeAll() }
        targets[ObjectIdentifier(m)] = (x, y)
    }

    /// Stops direct aiming (the stick moves the crosshair again).
    public static func clearTarget(_ m: Machine) {
        lock.lock(); defer { lock.unlock() }
        targets[ObjectIdentifier(m)] = nil
    }

    /// The current target of `m`, if any.
    public static func target(_ m: Machine) -> (x: Double, y: Double)? {
        lock.lock(); defer { lock.unlock() }
        return targets[ObjectIdentifier(m)]
    }

    /// Whether the crosshair is under player control now and where it is (read-only; host thread in frameHook).
    /// `area` = the F1 context area (GameContext.area): .tunnels or .flare; nil otherwise.
    public static func info(_ mem: Memory, area: GameContext.Area) -> Info? {
        switch area {
        case .flare:
            let x = Double(Int16(bitPattern: mem.r16(S1.list2 + 2))), y = Double(Int16(bitPattern: mem.r16(S1.list2 + 4)))
            return Info(mode: .flare, centre: (x + 9, y + 9 + Double(lineOffset)),
                        bounds: (Double(flareBounds.minX + 9), Double(flareBounds.minY + 9 + lineOffset),
                                 Double(flareBounds.maxX + 9), Double(flareBounds.maxY + 9 + lineOffset)))
        case .tunnels:
            let mode: Mode
            if mem.r8(S1.obj2) != 0 || mem.r8(S1.obj3) != 0 || mem.r8(S1.obj1) != 0 {
                mode = .tunnelCombat
            } else if mem.r8(S1.inRoom) != 0 {
                mode = (mem.r8(S1.obj4) != 0 && mem.r8(0x19d7b) != 4) ? .tunnelCombat : .tunnelRoom
            } else {
                return nil                                  // corridor navigation: the stick walks
            }
            let col = Double(mem.r32(S1.colLeft) & 0xff) * 8
            let x = Double(Int16(bitPattern: mem.r16(S1.objs + 2))), y = Double(Int16(bitPattern: mem.r16(S1.objs + 4)))
            return Info(mode: mode, centre: (col + x + 9, y + 9 + Double(lineOffset)),
                        bounds: (col + Double(tunnelBounds.minX + 9), Double(tunnelBounds.minY + 9 + lineOffset),
                                 col + Double(tunnelBounds.maxX + 9), Double(tunnelBounds.maxY + 9 + lineOffset)))
        default:
            return nil
        }
    }

    // MARK: headless test script

    static let script: [(frame: UInt64, target: (x: Double, y: Double)?)] = {
        guard let s = ProcessInfo.processInfo.environment["PLATOON_S1_AIM"] else { return [] }
        var out: [(frame: UInt64, target: (x: Double, y: Double)?)] = []
        for item in s.split(separator: ";") {
            let p = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count == 2, let f = UInt64(p[0]) else { continue }
            if p[1] == "-" { out.append((f, nil)); continue }
            let xy = p[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if xy.count == 2 { out.append((f, (xy[0], xy[1]))) }
        }
        return out.sorted { $0.frame < $1.frame }
    }()

    static func scripted(_ frame: UInt64) -> (x: Double, y: Double)?? {
        guard !script.isEmpty else { return nil }
        guard let last = script.last(where: { $0.frame <= frame }) else { return .some(nil) }
        return .some(last.target)
    }
}

extension Platoon {
    /// ENHANCEMENT L2 (s1.directAim): puts the crosshair object a3 onto the host's target (original clamps).
    /// Returns true when a target was applied (the caller then ignores the stick directions).
    func s1e_aimAt(_ a3: UInt32, _ mode: TunnelAim.Mode) -> Bool {
        let t: (x: Double, y: Double)?
        if let s = TunnelAim.scripted(m.frameCount) { t = s } else { t = TunnelAim.target(m) }
        guard let target = t else { return false }
        let b = mode == .flare ? TunnelAim.flareBounds : TunnelAim.tunnelBounds
        let col = mode == .flare ? 0 : Int(mem.r32(S1.colLeft) & 0xff) * 8
        let ox = Int(target.x.rounded()) - col - TunnelAim.centreOffset
        let oy = Int(target.y.rounded()) - TunnelAim.lineOffset - TunnelAim.centreOffset
        mem.w16(a3 + 2, UInt16(min(max(ox, b.minX), b.maxX)))
        mem.w16(a3 + 4, UInt16(min(max(oy, b.minY), b.maxY)))
        return true
    }
}
