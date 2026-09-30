// Enhancement options of Jungle & village (section 0).
// OWNER: the section0 agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Items (port/ENHANCEMENT_IDEAS.md): S6 bridge failsafe, S7 forgiving booby traps, S9 jungle/village fixes (b f g k),
// M14 explicit jump/crouch, L3 village randomiser, M10 section-0 knobs. Hooks: Game/Section0/*.swift, marked
// `// ENHANCEMENT <ID>`; helpers in Game/Section0/Section0Enhance.swift. The M6 mini-map and the L4 widescreen side
// columns are host-only (app overlays Overlay/Jungle*.swift, read-only models Game/Section0/JungleMapModel.swift and
// JungleWidescreen.swift) and need no option here.
//
// Every default below is the original behaviour; with all defaults the section is byte-identical to the original.

public struct Section0Options: EnhancementGroup {
    public init() {}
    public static let prefix = "s0"
    public static let title = "Jungle & village (section 0)"
    public static let owner = "section0"

    /// S6: walking right towards the unblown bridge without having planted the explosives stops the player at the
    /// last column before the doom column $4e (like the game's own suicide guard) and shows "SET THE EXPLOSIVES ON
    /// THE BRIDGE", instead of freezing him and wiping out the whole platoon.
    public var bridgeFailsafe = false
    /// S7: tripwires and the two booby-trapped hut drawers count as a normal hit (+1 wound, morale -$800) instead of
    /// killing the current man outright (the original sets his hits to 3 before the hit adds the 4th).
    public var forgivingTraps = false
    /// S9 (b): morale bonuses (supply crates, torch, map) are clamped at $ffff instead of wrapping round to a
    /// nearly empty morale bar.
    public var fixMoraleWrap = false
    /// S9 (f): the invisible hut-1 "dummy" enemy can no longer be shot (it kept the street enemy's stale x, gave
    /// +300 points and marked the hut-2 guard as dead, so the map could be taken without fighting).
    public var fixHutDummy = false
    /// S9 (g): tripwires always appear at the screen edge ahead: the original keeps the high byte of $60c34, so with
    /// a negative coarse scroll a tripwire walking right appears BEHIND the player (x $28..$2c).
    public var fixTripwireSpawn = false
    /// S9 (k): the trap-door bonus (1000 per living man) counts the five men; the original counts five records from
    /// the CURRENT man, so with man 2..5 in control it reads kernel variables as "men".
    public var fixTrapdoorBonus = false
    /// M14: explicit jump and crouch controls (host buttons, see Section0Host; optionally Amiga keys jumpKey /
    /// crouchKey). UP/DOWN then only take paths and hut doors. A rule change: jumping on path tiles / at doors.
    public var explicitJumpCrouch = false
    /// M14: Amiga raw keycode that jumps (nil = host button only). E.g. $32 (Mac X).
    public var jumpKey: Int? = nil
    /// M14: Amiga raw keycode that crouches (nil = host button only). E.g. $33 (Mac C).
    public var crouchKey: Int? = nil
    /// L3: seed of the village randomiser (nil = original placement): torch, map and the two booby traps are moved
    /// to other search spots of the huts (seeded, the same seed gives the same village every game).
    public var villageSeed: Int? = nil

    /// M10 knobs of this section (resolved from the preset at game start).
    public var difficulty = Section0Difficulty()

    public static let options: [EnhancementOption<Section0Options>] = [
        .bool("bridgeFailsafe", \.bridgeFailsafe, id: "S6", gameplay: true,
              help: "Jungle: without explosives you are stopped before the bridge instead of the whole platoon being wiped out."),
        .bool("forgivingTraps", \.forgivingTraps, id: "S7", gameplay: true,
              help: "Tripwires and booby-trapped drawers wound (like a bullet) instead of killing the soldier."),
        .bool("fixMoraleWrap", \.fixMoraleWrap, id: "S9b", gameplay: true,
              help: "Morale bonuses (crates, torch, map) stop at full instead of wrapping round to almost nothing."),
        .bool("fixHutDummy", \.fixHutDummy, id: "S9f", gameplay: true,
              help: "The invisible 'enemy' in the trap-door hut can't be shot (it gave points and killed the hut-2 guard)."),
        .bool("fixTripwireSpawn", \.fixTripwireSpawn, id: "S9g", gameplay: true,
              help: "Tripwires never appear behind you (original quirk with some scroll positions)."),
        .bool("fixTrapdoorBonus", \.fixTrapdoorBonus, id: "S9k", gameplay: true,
              help: "Trap-door bonus counts your five soldiers (the original counts from the current soldier)."),
        .bool("explicitJumpCrouch", \.explicitJumpCrouch, id: "M14", gameplay: true,
              help: "Separate jump and crouch controls; up/down only take paths and doors."),
        .optionalInt("jumpKey", \.jumpKey, range: 0...0x67, id: "M14", gameplay: false,
                     help: "Amiga keycode that jumps with explicitJumpCrouch (e.g. $32 = X; default: host button only)."),
        .optionalInt("crouchKey", \.crouchKey, range: 0...0x67, id: "M14", gameplay: false,
                     help: "Amiga keycode that crouches with explicitJumpCrouch (e.g. $33 = C; default: host button only)."),
        .optionalInt("villageSeed", \.villageSeed, range: 0...0x7fff_ffff, id: "L3", gameplay: true,
                     help: "Village randomiser: torch, map and booby traps move to other hut spots (seeded)."),
        .optionalInt("diff.shootMask", \.difficulty.shootMask, range: 0...0xff, id: "M10", gameplay: true,
                     help: "Walking soldiers try to shoot when random & mask == 0 each tick (original $1f = 1 in 32)."),
        .optionalInt("diff.hitMorale", \.difficulty.hitMorale, range: 0...0xffff, id: "M10", gameplay: true,
                     help: "Morale lost per hit in the jungle (8.8 fixed point; original $800)."),
        .optionalInt("diff.villagerMorale", \.difficulty.villagerMorale, range: 0...0xffff, id: "M10", gameplay: true,
                     help: "Morale lost for killing a villager (original $1200)."),
        .optionalInt("diff.grenades", \.difficulty.grenades, range: 0...9, id: "M10", gameplay: true,
                     help: "Grenades per soldier at the start of the jungle (original 9)."),
        .optionalInt("diff.ammo", \.difficulty.ammo, range: 0...0x90, id: "M10", gameplay: true,
                     help: "Rounds per soldier at the start of the jungle (original $90 = 144)."),
        .optionalInt("diff.spawnFloor", \.difficulty.spawnFloor, range: 0...0xfe, id: "M10", gameplay: true,
                     help: "Minimum enemy spawn chance per tick, out of 256 (original 7)."),
        .optionalInt("diff.rifleKillsSpider", \.difficulty.rifleKillsSpider, range: 0...1, id: "M10", gameplay: true,
                     help: "1 = rifle bullets kill the spider-hole VC (original: grenades only)."),
        .optionalInt("diff.trapsWound", \.difficulty.trapsWound, range: 0...1, id: "M10", gameplay: true,
                     help: "1 = booby traps wound instead of kill (same as s0.forgivingTraps)."),
        .optionalInt("diff.bridgeFailsafe", \.difficulty.bridgeFailsafe, range: 0...1, id: "M10", gameplay: true,
                     help: "1 = bridge failsafe (same as s0.bridgeFailsafe)."),
        .optionalInt("diff.noMap", \.difficulty.noMap, range: 0...1, id: "M10", gameplay: true,
                     help: "1 = the tunnel map in hut 2 can't be found (Custom challenge)."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }

    // MARK: effective switches (option OR difficulty knob) used by the hooks

    var bridgeFailsafeOn: Bool { bridgeFailsafe || difficulty.bridgeFailsafe == 1 }
    var trapsWoundOn: Bool { forgivingTraps || difficulty.trapsWound == 1 }
}

/// M10 difficulty knobs of Jungle & village (section 0) (all nil = original).
/// Hooks read `knob ?? <original literal>` and never add or remove a k_random() call.
public struct Section0Difficulty: DifficultyKnobs {
    public init() {}
    /// en_st2_walk: `rand() & $1f == 0` -> try to shoot. Larger mask = fewer shots.
    public var shootMask: Int? = nil
    /// ph_done: morale_sub($800) per hit.
    public var hitMorale: Int? = nil
    /// enemy_score: morale_sub($1200) for a villager.
    public var villagerMorale: Int? = nil
    /// sec0_restart: 9 grenades per man (HUD bar: 9 cells max).
    public var grenades: Int? = nil
    /// sec0_restart: $90 rounds per man (HUD bar max; crate refills still cap at $90).
    public var ammo: Int? = nil
    /// main_loop: the spawn chance $60cae decays to 7 (`if < 8: 8; -1`).
    public var spawnFloor: Int? = nil
    /// hit_pbullet: 1 = the rifle kills the spider-hole VC (state 5) like a grenade does.
    public var rifleKillsSpider: Int? = nil
    /// 1 = booby traps wound (S7).
    public var trapsWound: Int? = nil
    /// 1 = bridge failsafe (S6).
    public var bridgeFailsafe: Int? = nil
    /// 1 = no map in hut 2 (item_map always answers "A TABLE.").
    public var noMap: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> Section0Difficulty {
        var k = Section0Difficulty()
        switch p {
        case .recruit:
            k.shootMask = 0x3f            // half as many enemy shots
            k.hitMorale = 0x400
            k.villagerMorale = 0x900
            k.spawnFloor = 4
            k.rifleKillsSpider = 1
            k.trapsWound = 1
            k.bridgeFailsafe = 1
        case .veteran:
            k.shootMask = 0x0f            // twice as many
            k.hitMorale = 0xc00
            k.villagerMorale = 0x1b00
            k.grenades = 6
            k.ammo = 0x60
            k.spawnFloor = 12
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: Section0Difficulty) -> Section0Difficulty {
        var r = base
        if let v = shootMask { r.shootMask = v }
        if let v = hitMorale { r.hitMorale = v }
        if let v = villagerMorale { r.villagerMorale = v }
        if let v = grenades { r.grenades = v }
        if let v = ammo { r.ammo = v }
        if let v = spawnFloor { r.spawnFloor = v }
        if let v = rifleKillsSpider { r.rifleKillsSpider = v }
        if let v = trapsWound { r.trapsWound = v }
        if let v = bridgeFailsafe { r.bridgeFailsafe = v }
        if let v = noMap { r.noMap = v }
        return r
    }
}
