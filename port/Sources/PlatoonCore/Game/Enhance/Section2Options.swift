// Enhancement options of Final jungle & foxhole (section 2).
// OWNER: the section2 agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Planned items (port/ENHANCEMENT_IDEAS.md): S9 (a)(h)(j) fixes, M5 compass assist, M15 section-2 men, M10 section-2 knobs (timer, soldiers per room, Barnes HP).
//
// Add an option: a stored property with the ORIGINAL behaviour as default, an entry in `options`, and the hook in
// translated code marked `// ENHANCEMENT <ID>` reading `enhancements.section2.<field>`.
// Difficulty knobs (M10) go into Section2Difficulty (Optionals, nil = original; keys "s2.diff.<knob>").

public struct Section2Options: EnhancementGroup {
    public init() {}
    public static let prefix = "s2"
    public static let title = "Final jungle & foxhole (section 2)"
    public static let owner = "section2"

    /// M10 knobs of this section (resolved from the preset at game start).
    public var difficulty = Section2Difficulty()

    public static let options: [EnhancementOption<Section2Options>] = [
        // .bool("example", \.example, id: "S0", gameplay: true, help: "..."),
        // .optionalInt("diff.example", \.difficulty.example, id: "M10", gameplay: true, help: "..."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }
}

/// M10 difficulty knobs of Final jungle & foxhole (section 2) (all nil = original).
public struct Section2Difficulty: DifficultyKnobs {
    public init() {}
    // public var example: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> Section2Difficulty {
        let k = Section2Difficulty()
        switch p {
        case .recruit: break          // k.example = ...
        case .veteran: break
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: Section2Difficulty) -> Section2Difficulty {
        let r = base
        // if let v = example { r.example = v }
        return r
    }
}
