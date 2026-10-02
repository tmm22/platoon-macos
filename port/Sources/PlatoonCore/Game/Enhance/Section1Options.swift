// Enhancement options of Tunnels & flare night (section 1).
// OWNER: the section1 agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Items (IDs: port/PORTING.md "Enhancement IDs"): M3 variant B automap, M4 keep items / flare-night retry / checkpoint respawn,
// S9 tunnel+flare fixes, M15 section-1 men (flags in GameplayOptions), M10 section-1 knobs, L2 direct aiming,
// L3 randomiser (tunnels part). The hooks are `// ENHANCEMENT <ID>` sites in Game/Section1/*.swift; the shared
// helpers live in Game/Section1/Section1Enhance.swift.
//
// Add an option: a stored property with the ORIGINAL behaviour as default, an entry in `options`, and the hook in
// translated code marked `// ENHANCEMENT <ID>` reading `enhancements.section1.<field>`.
// Difficulty knobs (M10) go into Section1Difficulty (Optionals, nil = original; keys "s1.diff.<knob>").

public struct Section1Options: EnhancementGroup {
    public init() {}
    public static let prefix = "s1"
    public static let title = "Tunnels & flare night (section 1)"
    public static let owner = "section1"

    // M4 tunnels fairness
    /// Keep the flares, compass, a map found in the tunnels and the taken room items when a soldier dies.
    public var keepItems = false
    /// A death in the flare night restarts the flare night (with the flares you entered it with) instead of the maze.
    public var flareRetry = false
    /// After a death, start the next soldier in front of the last room entered instead of at the maze entrance.
    public var checkpointRespawn = false
    // M3 variant B
    /// The map window shows the parts of the maze you have seen, even without the map (the map item still shows all).
    public var exploredMap = false
    // S9 section-1 fixes
    /// Morale gained from room items is clamped at the maximum instead of wrapping to almost 0.
    public var fixMoraleWrap = false
    /// The last bullet can kill (the original tests the ammunition after the shot).
    public var fixLastBullet = false
    /// Flare night: the enemy spawn interval never becomes 0 (which silently disables all later spawns).
    public var fixFlareSpawn = false
    /// Food can only be eaten once per soldier (the original gives +500 on every click).
    public var fixFoodFarm = false
    // L2 (b)
    /// The crosshair jumps to a pointer target set by the host (TunnelAim API; input agent), within the original bounds.
    public var directAim = false
    // L3
    /// Randomiser seed for the room contents (0 = off, the original rooms).
    public var randomSeed = 0

    /// M10 knobs of this section (resolved from the preset at game start).
    public var difficulty = Section1Difficulty()

    public static let options: [EnhancementOption<Section1Options>] = [
        .bool("keepItems", \.keepItems, id: "M4", gameplay: true,
              help: "Tunnels: flares, compass, a map found here and emptied drawers are kept when a soldier dies."),
        .bool("flareRetry", \.flareRetry, id: "M4", gameplay: true,
              help: "A death in the flare night restarts the flare night with the next soldier (and the flares you brought) instead of the maze."),
        .bool("checkpointRespawn", \.checkpointRespawn, id: "M4", gameplay: true,
              help: "Tunnels: the next soldier starts in front of the last room entered instead of at the entrance."),
        .bool("exploredMap", \.exploredMap, id: "M3", gameplay: true,
              help: "Tunnels: the map window is always shown and draws the corridors you have seen (the map item reveals everything)."),
        .bool("fixMoraleWrap", \.fixMoraleWrap, id: "S9", gameplay: true,
              help: "Fix: morale from room items stops at the maximum instead of wrapping around to almost nothing."),
        .bool("fixLastBullet", \.fixLastBullet, id: "S9", gameplay: true,
              help: "Fix: your last bullet can kill (tunnels and flare night)."),
        .bool("fixFlareSpawn", \.fixFlareSpawn, id: "S9", gameplay: true,
              help: "Fix: heavy firing in the flare night can no longer switch enemy spawns off for good."),
        .bool("fixFoodFarm", \.fixFoodFarm, id: "S9", gameplay: true,
              help: "Fix: food in the tunnel rooms gives its 500 points once per soldier, not on every click."),
        .bool("directAim", \.directAim, id: "L2", gameplay: true,
              help: "Crosshair follows a pointer/touch target from the host (mouse aiming) instead of the stick."),
        .int("randomSeed", \.randomSeed, range: 0...0x7fff_ffff, id: "L3", gameplay: true,
             help: "Randomiser: shuffles what lies in each tunnel room (same kind of room; the exit stays behind a door). 0 = off."),
        .optionalInt("diff.hitMorale", \.difficulty.hitMorale, range: 0...0xffff, id: "M10", gameplay: true,
                     help: "Morale lost per wound in the tunnels / flare night (original $c00)."),
        .optionalInt("diff.spawnDelay", \.difficulty.spawnDelay, range: 1...0xce, id: "M10", gameplay: true,
                     help: "Tunnels: minimum ticks between enemies (original $10; the random part $00-$31 is added)."),
        .optionalInt("diff.enemyAim", \.difficulty.enemyAim, range: 1...0x7fff, id: "M10", gameplay: true,
                     help: "Tunnels: ticks a corridor enemy aims before it fires (original $f)."),
        .optionalInt("diff.itemMorale", \.difficulty.itemMorale, range: 0...0xffff, id: "M10", gameplay: true,
                     help: "Morale gained per useful room item (original $200)."),
        .optionalInt("diff.flareSpawnBase", \.difficulty.flareSpawnBase, range: 4...0x7fff, id: "M10", gameplay: true,
                     help: "Flare night: enemy spawn interval base (original $90; larger = fewer enemies)."),
        .optionalInt("diff.flareShotSlack", \.difficulty.flareShotSlack, range: 0...0xf, id: "M10", gameplay: true,
                     help: "Flare night: how fast a firing enemy hits you (original $d; smaller = more time to shoot back)."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }

    /// Any option that needs the section-1 enhancement scratch RAM (Section1Enhance.swift).
    var needsScratch: Bool { keepItems || flareRetry || checkpointRespawn || exploredMap }
}

/// M10 difficulty knobs of Tunnels & flare night (section 1) (all nil = original).
public struct Section1Difficulty: DifficultyKnobs {
    public init() {}
    /// $17e2e morale_sub(d0 = $c00) after a wound (tunnels and flare night).
    public var hitMorale: Int? = nil
    /// $171f8 spawn countdown `(rand & $31) + $10`: the constant part.
    public var spawnDelay: Int? = nil
    /// $17996 h_enemy_aim: ticks until the corridor enemy fires (`cmpi.w #$f`).
    public var enemyAim: Int? = nil
    /// $1888c item taken: morale + $200.
    public var itemMorale: Int? = nil
    /// $18b6c / $1922a flare spawn base $90 (spawn interval = (base + kill bonus) / 4, -2 per shot).
    public var flareSpawnBase: Int? = nil
    /// $191cc h_enemy_shoot: threshold ((|light - 3| + 1) * 16) - $d.
    public var flareShotSlack: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> Section1Difficulty {
        var k = Section1Difficulty()
        switch p {
        case .recruit:
            k.hitMorale = 0x800; k.spawnDelay = 0x20; k.enemyAim = 0x19; k.itemMorale = 0x300
            k.flareSpawnBase = 0xc0; k.flareShotSlack = 5
        case .veteran:
            k.hitMorale = 0x1000; k.spawnDelay = 0x08; k.enemyAim = 0x0b; k.itemMorale = 0x100
            k.flareSpawnBase = 0x70; k.flareShotSlack = 0xf
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: Section1Difficulty) -> Section1Difficulty {
        var r = base
        if let v = hitMorale { r.hitMorale = v }
        if let v = spawnDelay { r.spawnDelay = v }
        if let v = enemyAim { r.enemyAim = v }
        if let v = itemMorale { r.itemMorale = v }
        if let v = flareSpawnBase { r.flareSpawnBase = v }
        if let v = flareShotSlack { r.flareShotSlack = v }
        return r
    }
}
