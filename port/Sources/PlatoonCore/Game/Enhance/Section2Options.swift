// Enhancement options of Final jungle & foxhole (section 2).
// OWNER: the section2 agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Items (port/ENHANCEMENT_IDEAS.md): S9 (a)(h)(j) fixes, M5 compass assist, M15 section-2 men (flags in
// GameplayOptions), M10 section-2 knobs. Hooks: Game/Section2/*.swift, marked `// ENHANCEMENT <ID>`; helpers in
// Game/Section2/Section2Enhance.swift. The M5 navigator and the M25 room slide are host-only (app overlays
// Overlay/Final*.swift, model Game/Section2/FinalNavigator.swift) and need no option here.
//
// Every default below is the original behaviour; with all defaults the section is byte-identical to the original.

public struct Section2Options: EnhancementGroup {
    public init() {}
    public static let prefix = "s2"
    public static let title = "Final jungle & foxhole (section 2)"
    public static let owner = "section2"

    /// S9 (a): room_setup's `clr.w $68.l` (absolute) was meant to be `clr.w $68(a6)`: with the fix the airstrike timer
    /// is stopped while a room change fades/decodes (~18 frames per room, ~5 s over the shortest route) and restarts
    /// at room_enter_done (`st.b $68(a6)`, original code).
    public var fixRoomTimer = false
    /// S9 (h): the timer is stopped when the napalm strike starts (s2_time_up), so the HUD does not wrap to 59:59
    /// during the white flash. (The kernel's kernel.timerStopsAtZero does the same for every section.)
    public var napalmStopsTimer = false
    /// S9 (h): morale 0 shows the intended "YOUR PLATOON HAS WITHDRAWN FROM ACTION" screen ($18c14) instead of
    /// "YOUR PLATOON HAS BEEN DESTROYED!" (the original loads it into a0 and then overwrites a0).
    public var withdrawnText = false
    /// S9 (j): no phantom '.' key after Barnes' death (obj_player tests the '.' key with a proper d0.w, so the
    /// remaining grenades are not thrown automatically one after another).
    public var fixPhantomGrenades = false
    /// M5 (level 1, gameplay variant): start the final jungle with the compass ($26(a6) = 1 at fj_restart): the HUD
    /// shows the heading and hint 0 becomes "GET GOING!" instead of "A COMPASS WOULD HELP !".
    public var compassAssist = false

    /// M10 knobs of this section (resolved from the preset at game start).
    public var difficulty = Section2Difficulty()

    public static let options: [EnhancementOption<Section2Options>] = [
        .bool("fixRoomTimer", \.fixRoomTimer, id: "S9a", gameplay: true,
              help: "Final jungle: the airstrike timer pauses while the screen is black between rooms (the original's intent)."),
        .bool("napalmStopsTimer", \.napalmStopsTimer, id: "S9h", gameplay: false,
              help: "Napalm strike: the timer stops at 00:00 instead of showing 59:59 during the flash."),
        .bool("withdrawnText", \.withdrawnText, id: "S9h", gameplay: false,
              help: "Morale 0 in the final jungle shows the intended 'YOUR PLATOON HAS WITHDRAWN FROM ACTION' screen."),
        .bool("fixPhantomGrenades", \.fixPhantomGrenades, id: "S9j", gameplay: false,
              help: "Bunker: after Barnes is dead your remaining grenades are no longer thrown by themselves."),
        .bool("compassAssist", \.compassAssist, id: "M5", gameplay: true,
              help: "Final jungle: you start with the compass (HUD heading; the hint becomes GET GOING!)."),
        .optionalInt("diff.timer", \.difficulty.timer, range: 10...3599, id: "M10", gameplay: true,
                     help: "Airstrike timer in seconds at every (re)start of the final jungle (original 120 = 2:00)."),
        .optionalInt("diff.maxSoldiers", \.difficulty.maxSoldiers, range: 0...5, id: "M10", gameplay: true,
                     help: "At most this many soldiers per room visit (original 0..5, random)."),
        .optionalInt("diff.spawnDelay", \.difficulty.spawnDelay, range: 1...0x7fff, id: "M10", gameplay: true,
                     help: "Minimum ticks between soldiers entering (original 20; +0..15 random)."),
        .optionalInt("diff.fireCooldown", \.difficulty.fireCooldown, range: 1...0x7fff, id: "M10", gameplay: true,
                     help: "Minimum ticks between soldier shots (original 20; +0..15 random)."),
        .optionalInt("diff.sniperDelay", \.difficulty.sniperDelay, range: 5...0x7fff, id: "M10", gameplay: true,
                     help: "Ticks standing at one depth before the sniper shoots (original 50; 100 after a room entry/hit)."),
        .optionalInt("diff.hitMorale", \.difficulty.hitMorale, range: 0...0xffff, id: "M10", gameplay: true,
                     help: "Morale lost per hit in the final jungle (8.8 fixed point; original $800)."),
        .optionalInt("diff.barnesHits", \.difficulty.barnesHits, range: 1...20, id: "M10", gameplay: true,
                     help: "Grenade hits needed to kill Barnes (original 5)."),
        .optionalInt("diff.barnesCooldown", \.difficulty.barnesCooldown, range: 1...0x7fff, id: "M10", gameplay: true,
                     help: "Minimum ticks between Barnes' shots (original 10; +0..15 random)."),
        .optionalInt("diff.grenades", \.difficulty.grenades, range: 0...99, id: "M10", gameplay: true,
                     help: "Grenades per man at the start of the final jungle (original 9)."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }
}

/// M10 difficulty knobs of Final jungle & foxhole (section 2) (all nil = original).
/// Rules: hooks read `knob ?? <literal>`; random draws are masked/clamped AFTER the original k_random() call, so the
/// RNG sequence is unchanged.
public struct Section2Difficulty: DifficultyKnobs {
    public init() {}
    /// Timer at fj_restart in seconds (original 120; stored as BCD mm:ss in $6c(a6)).
    public var timer: Int? = nil
    /// Upper bound of the soldier pool per room (room_setup: `rand & 7`, >5 -> -3; clamped afterwards).
    public var maxSoldiers: Int? = nil
    /// Soldier spawn delay base (soldier_spawn_tick: `(rand & $f) + $14`).
    public var spawnDelay: Int? = nil
    /// Soldier fire cooldown base (soldier_fire_spawn: `(rand & $f) + $14`).
    public var fireCooldown: Int? = nil
    /// Idle-shot countdown after a depth change (idle_reset: $32; the $64 sites use twice this value).
    public var sniperDelay: Int? = nil
    /// Morale per hit (player_hit: `subi.w #$800`).
    public var hitMorale: Int? = nil
    /// Barnes' hit points / 10 (room_setup_bunker: `move.b #$32`).
    public var barnesHits: Int? = nil
    /// Barnes' fire cooldown base (barnes_fire_spawn: `(rand & $f) + $a`).
    public var barnesCooldown: Int? = nil
    /// Grenades per man at fj_entry (original 9).
    public var grenades: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> Section2Difficulty {
        var k = Section2Difficulty()
        switch p {
        case .recruit:
            k.timer = 180                 // 3:00
            k.maxSoldiers = 3
            k.fireCooldown = 0x20
            k.sniperDelay = 80
            k.hitMorale = 0x400
            k.barnesHits = 3
            k.barnesCooldown = 0x18
        case .veteran:
            k.timer = 90                  // 1:30 (the shortest route takes ~32 s)
            k.spawnDelay = 0x0c
            k.fireCooldown = 0x0e
            k.sniperDelay = 35
            k.hitMorale = 0xc00
            k.barnesHits = 7
            k.barnesCooldown = 0x06
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: Section2Difficulty) -> Section2Difficulty {
        var r = base
        if let v = timer { r.timer = v }
        if let v = maxSoldiers { r.maxSoldiers = v }
        if let v = spawnDelay { r.spawnDelay = v }
        if let v = fireCooldown { r.fireCooldown = v }
        if let v = sniperDelay { r.sniperDelay = v }
        if let v = hitMorale { r.hitMorale = v }
        if let v = barnesHits { r.barnesHits = v }
        if let v = barnesCooldown { r.barnesCooldown = v }
        if let v = grenades { r.grenades = v }
        return r
    }
}
