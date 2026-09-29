// Enhancement options of Tunnels & flare night (section 1).
// OWNER: the section1 agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Planned items (port/ENHANCEMENT_IDEAS.md): M3 variant B automap, M4 keep items / flare-night retry / checkpoint respawn, S9 tunnel+flare fixes, M15 section-1 men, M10 section-1 knobs, L2 direct aiming.
//
// Add an option: a stored property with the ORIGINAL behaviour as default, an entry in `options`, and the hook in
// translated code marked `// ENHANCEMENT <ID>` reading `enhancements.section1.<field>`.
// Difficulty knobs (M10) go into Section1Difficulty (Optionals, nil = original; keys "s1.diff.<knob>").

public struct Section1Options: EnhancementGroup {
    public init() {}
    public static let prefix = "s1"
    public static let title = "Tunnels & flare night (section 1)"
    public static let owner = "section1"

    /// M10 knobs of this section (resolved from the preset at game start).
    public var difficulty = Section1Difficulty()

    public static let options: [EnhancementOption<Section1Options>] = [
        // .bool("example", \.example, id: "S0", gameplay: true, help: "..."),
        // .optionalInt("diff.example", \.difficulty.example, id: "M10", gameplay: true, help: "..."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }
}

/// M10 difficulty knobs of Tunnels & flare night (section 1) (all nil = original).
public struct Section1Difficulty: DifficultyKnobs {
    public init() {}
    // public var example: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> Section1Difficulty {
        let k = Section1Difficulty()
        switch p {
        case .recruit: break          // k.example = ...
        case .veteran: break
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: Section1Difficulty) -> Section1Difficulty {
        let r = base
        // if let v = example { r.example = v }
        return r
    }
}
