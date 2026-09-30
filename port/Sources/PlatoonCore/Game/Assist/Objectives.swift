import Foundation

// M2 objectives, briefings and numeric HUD readouts (owner: assist). Read-only: everything is derived from the F1
// context (GameContext, refreshed every frame by GameProbe) plus a few RAM bytes it doesn't decode; nothing here
// writes game RAM. The app draws the results in overlay panels (PlatoonApp/Assist/).
//
// Facts used (RE notes re/jungle, re/village, re/tunnels, re/flare, re/finaljungle, re/foxhole):
//   S0: explosives $28(a6) (box on jungle level 4, columns 49-53); bridge $60c9c (0 intact, 1 charge set, 2 blown;
//       planted automatically at column 72 of level 1); village street = level 0 columns $30-$54, reached through
//       the up-path at level 1 column $54 east of the bridge; huts 0-5 from west to east: 0 torch (+booby trap),
//       1 trap door, 2 VC guard + map, 4 booby trap; torch $60cbd; map $24(a6).
//   S1: flares $2c(a6) (rooms 0 and 8; 8 needed at the exit in room 9), compass $26(a6) (room 4), map $24(a6)
//       (room 0); flare night: survive the light cycle after your last flare.
//   S2: final-jungle timer $6c/$6d(a6); bunker room = exit mask 0; Barnes' hit points byte $57e6a ($32 = 5 grenade
//       hits); walk into the bunker door after he is dead.

/// How much the objectives panel tells.
public enum ObjectiveTier: Int, CaseIterable, Codable {
    /// What to do ("Find the explosives").
    case goals = 1
    /// + where / how ("on the deepest jungle strip, near its east end").
    case hints = 2
    /// + the full solution (final-jungle route, room numbers).
    case solution = 3
}

public struct Objective: Equatable {
    public enum State: Equatable { case todo, done, failed }
    public var id: String
    public var title: String
    /// Extra line (hints tier and up).
    public var detail: String?
    public var state: State
    /// Not required to finish the section.
    public var optional = false
    /// Progress text shown after the title ("5/8").
    public var progress: String?
}

public struct ObjectiveSheet: Equatable {
    public var section: Int
    public var title: String
    public var objectives: [Objective]
    /// Short situational advice ("You need the torch before going down").
    public var advice: [String]
}

/// Keeps the per-run progress that RAM alone doesn't show (village reached, tunnel exit found, flares fired) and
/// builds the checklist of the current section.
public final class ObjectiveTracker {
    public init() {}

    private var villageReached = false
    private var bunkerReached = false
    private var barnesHP0: Int?
    private var flareStartCount: Int?
    private var lastSection: Int?
    private var mazeCells = Set<Int>()

    /// Forget the run (new game / reset).
    public func reset() {
        villageReached = false; bunkerReached = false; barnesHP0 = nil; flareStartCount = nil; lastSection = nil
        mazeCells.removeAll()
    }

    /// Call every frame (or every displayed frame) with the current context.
    public func update(_ c: GameContext) {
        guard c.inGame, let s = c.section else { return }
        if s != lastSection {
            lastSection = s
            villageReached = false; bunkerReached = false; barnesHP0 = nil; flareStartCount = nil; mazeCells.removeAll()
        }
        switch s {
        case 0:
            if c.area == .village || c.area == .hut { villageReached = true }
        case 1:
            if c.area == .flare {
                if flareStartCount == nil { flareStartCount = c.flares }
            } else if let t = c.tunnels {
                flareStartCount = nil
                mazeCells.insert(t.x << 8 | t.y)
            }
        case 2:
            if c.area == .bunker {
                bunkerReached = true
                if let f = c.finalJungle, barnesHP0 == nil, f.barnesHP > 0 { barnesHP0 = f.barnesHP }
            }
        default: break
        }
    }

    /// The checklist for the section being played (nil outside a section).
    /// `randomised`: the village / tunnel randomiser is on (no location hints).
    public func sheet(_ c: GameContext, tier: ObjectiveTier, randomisedVillage: Bool = false,
                      randomisedTunnels: Bool = false) -> ObjectiveSheet? {
        guard let s = c.section else { return nil }
        let hints = tier.rawValue >= ObjectiveTier.hints.rawValue
        let solution = tier == .solution
        func d(_ h: String?, _ sol: String? = nil) -> String? { solution ? (sol ?? h) : hints ? h : nil }
        var o: [Objective] = [], advice: [String] = []
        switch s {
        case 0:
            let j = c.jungle
            let bridge = j?.bridge ?? 0
            let blown = bridge == 2
            o.append(Objective(id: "s0.explosives", title: "Find the explosives",
                               detail: d("They lie on the deepest jungle strip, towards its east end.",
                                         "Level 4 (deepest strip), columns 49-53: walk over the box."),
                               state: c.explosives || bridge != 0 ? .done : .todo))
            o.append(Objective(id: "s0.bridge", title: "Blow up the bridge",
                               detail: d("The bridge is on the front strip. Walk onto it with the explosives.",
                                         "Front strip (level 1), column 72: the charge is set by itself, then keep walking right."),
                               state: blown ? .done : .todo))
            o.append(Objective(id: "s0.village", title: "Reach the village",
                               detail: d("Past the bridge, a path leads up to the village street.",
                                         "Level 1 column 84 (east of the bridge): push up onto the village street (level 0)."),
                               state: villageReached ? .done : .todo))
            o.append(Objective(id: "s0.torch", title: "Find a torch",
                               detail: d(randomisedVillage ? "Search the huts (the village is randomised)." : "Search the huts at the west end of the street.",
                                         randomisedVillage ? nil : "Westernmost hut (hut 0). Mind the booby-trapped drawer."),
                               state: (j?.torch ?? false) ? .done : .todo))
            o.append(Objective(id: "s0.map", title: "Take the tunnel map", detail: d(
                                randomisedVillage ? "It is somewhere in the huts; a VC guards one of them." : "A VC guards the hut that holds it.",
                                randomisedVillage ? nil : "Third hut from the west (hut 2): kill the guard, then search."),
                               state: c.map ? .done : .todo, optional: true))
            o.append(Objective(id: "s0.trapdoor", title: "Go down the trap door",
                               detail: d(randomisedVillage ? "One of the huts hides a trap door; you need the torch." : "It is in one of the huts; you need the torch.",
                                         randomisedVillage ? nil : "Second hut from the west (hut 1): stand on it, answer Y."),
                               state: .todo))
            if !blown, let j, j.level == 1, j.column >= 0x45, j.column < 0x4e, !c.explosives, bridge == 0 {
                advice.append("Without the explosives, going on east will cost you the whole platoon.")
            }
            if c.screen == .trapDoorPrompt, !(j?.torch ?? false) { advice.append("You need the torch first.") }
        case 1:
            let flare = c.area == .flare
            if !flare {
                o.append(Objective(id: "s1.flares", title: "Collect 8 flares",
                                   detail: d(randomisedTunnels ? "Boxes of flares are hidden in the rooms." : "Two rooms hold boxes of flares.",
                                             randomisedTunnels ? nil : "Rooms 0 (the guarded room near the entrance, 5 flares) and 8."),
                                   state: c.flares >= 8 ? .done : .todo, progress: "\(min(c.flares, 8))/8"))
                o.append(Objective(id: "s1.compass", title: "Find the compass",
                                   detail: d("It shows your heading on the HUD.", randomisedTunnels ? nil : "Room 4."),
                                   state: c.compass ? .done : .todo, optional: true))
                o.append(Objective(id: "s1.map", title: "Have the tunnel map",
                                   detail: d("From the village hut, or a plan in one of the rooms.",
                                             randomisedTunnels ? nil : "Hut 2 in the village, or room 0 here."),
                                   state: c.map ? .done : .todo, optional: true))
                o.append(Objective(id: "s1.exit", title: "Find the exit",
                                   detail: d("One room has a way out. It opens only with 8 flares.",
                                             randomisedTunnels ? nil : "Room 9."),
                                   state: .todo))
                if let t = c.tunnels, t.inRoom, t.room == 9, c.flares < 8 { advice.append("You need \(8 - c.flares) more flare\(8 - c.flares == 1 ? "" : "s").") }
            } else {
                let start = flareStartCount ?? c.flares
                let fired = max(0, start - c.flares)
                o.append(Objective(id: "s1.exit", title: "Find the exit", state: .done))
                o.append(Objective(id: "s1.night", title: "Survive the night",
                                   detail: d("Fire your flares one at a time (SPACE, or fire on the flare box) and shoot the VC while it is light.",
                                             "Each flare starts a light cycle; you win when the cycle after your last flare ends."),
                                   state: .todo, progress: start > 0 ? "\(fired)/\(start) flares" : nil))
                if c.flares > 0 && hints { advice.append("\(c.flares) flare\(c.flares == 1 ? "" : "s") left.") }
            }
        case 2:
            let f = c.finalJungle
            let inBunker = c.area == .bunker
            let hp = inBunker ? (f?.barnesHP ?? 0) : 0
            o.append(Objective(id: "s2.bunker", title: "Find the bunker before the airstrike",
                               detail: d("Every room has side exits; the way is long. Watch the timer.",
                                         "From the start: L R L R L R L R R L R L R L (walk to the far end of each room first)."),
                               state: bunkerReached ? .done : .todo,
                               progress: String(format: "%d:%02d", c.timerMinutes, c.timerSeconds)))
            let total = barnesHP0 ?? 0x32
            let hitsLeft = (hp + 9) / 10, hitsTotal = (total + 9) / 10
            o.append(Objective(id: "s2.barnes", title: "Kill Sgt Barnes",
                               detail: d("Only grenades hurt him.", "\(hitsTotal) grenade hits (fire throws them here)."),
                               state: bunkerReached && hp == 0 ? .done : .todo,
                               progress: bunkerReached ? "\(hitsTotal - hitsLeft)/\(hitsTotal) hits" : nil))
            o.append(Objective(id: "s2.door", title: "Walk into the bunker", detail: d("After Barnes is dead, walk up to the door."),
                               state: .todo))
            if c.timerMinutes == 0 && c.timerSeconds <= 30 && c.timerRunning { advice.append("The airstrike is coming!") }
        default: return nil
        }
        return ObjectiveSheet(section: s, title: ObjectiveTracker.sectionTitle(s, area: c.area), objectives: o, advice: advice)
    }

    public static func sectionTitle(_ s: Int, area: GameContext.Area = .none) -> String {
        switch s {
        case 0: return area == .village || area == .hut ? "The Village" : "The Jungle"
        case 1: return area == .flare ? "The Flare Night" : "The Tunnels"
        default: return area == .bunker ? "The Bunker" : "The Final Jungle"
        }
    }
}

/// Briefing cards shown while a section loads (the host draws them over the LOADING / ENTERING screens; the game's
/// own wait is not changed).
public enum Briefing {
    public struct Card: Equatable {
        public var title: String
        public var lines: [String]
    }

    public static func card(section: Int, tier: ObjectiveTier) -> Card {
        let hints = tier != .goals
        switch section {
        case 0:
            return Card(title: "THE JUNGLE & VILLAGE", lines: [
                "Lead your five men through the jungle to a village held by the Viet Cong.",
                "Find explosives and blow up the bridge, or the enemy will cut you off.",
                "In the village, find a torch and the trap door into the enemy tunnels.",
            ] + (hints ? ["Don't shoot the villagers. Search huts with fire; some drawers are booby-trapped.",
                          "Change soldier with Left-Alt when one is badly wounded."] : []))
        case 1:
            return Card(title: "THE TUNNELS & FLARE NIGHT", lines: [
                "A maze of tunnels under the village. Search the rooms.",
                "You need 8 flares to leave by the exit; a compass and a map help.",
                "Then hold out in a foxhole through the night, lighting it with your flares.",
            ] + (hints ? ["Only two soldiers go down; when both fall, the mission is over."] : []))
        default:
            return Card(title: "THE FINAL JUNGLE", lines: [
                "An airstrike will hit the jungle soon. Find the bunker before the timer runs out.",
                "Sgt Barnes waits there: only grenades will stop him.",
            ] + (hints ? ["Exits are to your left and right; the way through turns often. Walk to the far end of a room before turning."] : []))
        }
    }
}

/// M2 numeric HUD: morale, ammo, grenades and wounds of the platoon as numbers.
public enum HudReadout {
    public struct Line: Equatable { public var label: String; public var value: String; public var warn = false }

    /// Morale in percent of the full bar ($ffff).
    public static func moralePercent(_ morale: Int) -> Int { Int((Double(morale) * 100 / 65535).rounded()) }

    public static func lines(_ c: GameContext) -> [Line] {
        guard c.inGame, c.section != nil else { return [] }
        var out: [Line] = []
        let m = moralePercent(c.morale)
        out.append(Line(label: "MORALE", value: "\(m)%", warn: m < 20))
        if let man = c.man {
            out.append(Line(label: "SOLDIER", value: "\(c.currentMan + 1)  \(woundText(man.hits))", warn: man.hits >= 3))
            out.append(Line(label: "AMMO", value: "\(man.ammo)", warn: man.ammo < 10))
            if c.section != 1 { out.append(Line(label: "GRENADES", value: "\(man.grenades)", warn: man.grenades == 0)) }
        }
        if c.section == 1 { out.append(Line(label: "FLARES", value: "\(c.flares)")) }
        if c.section == 2 || c.timerRunning {
            out.append(Line(label: "TIME", value: String(format: "%d:%02d", c.timerMinutes, c.timerSeconds),
                            warn: c.timerMinutes == 0 && c.timerSeconds < 30))
        }
        if let f = c.finalJungle, c.area == .bunker { out.append(Line(label: "BARNES", value: "\((f.barnesHP + 9) / 10) hits")) }
        out.append(Line(label: "PLATOON", value: platoonText(c)))
        return out
    }

    /// "OK" / "1 wound" / "2 wounds" / "3 wounds" / "KIA".
    public static func woundText(_ hits: Int) -> String {
        switch hits {
        case 0: return "OK"
        case 1: return "1 wound"
        case 4...: return "KIA"
        default: return "\(hits) wounds"
        }
    }

    /// One symbol per soldier: ● fit, ◐ wounded, ◔ badly wounded, ✕ dead; the current one bracketed.
    public static func platoonText(_ c: GameContext) -> String {
        c.men.enumerated().map { i, m in
            let s: String
            switch m.hits { case 0: s = "●"; case 1: s = "◕"; case 2: s = "◑"; case 3: s = "◔"; default: s = "✕" }
            return i == c.currentMan ? "[\(s)]" : s
        }.joined(separator: " ")
    }
}
