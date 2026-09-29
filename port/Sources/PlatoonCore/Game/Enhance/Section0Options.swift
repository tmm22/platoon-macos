// Enhancement options of Jungle & village (section 0).
// OWNER: the section0 agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Planned items (port/ENHANCEMENT_IDEAS.md): S6 bridge failsafe, S7 forgiving booby traps, S9 jungle/village fixes, M6 mini-map variants, M14 explicit jump/crouch, M10 section-0 knobs.
//
// Add an option: a stored property with the ORIGINAL behaviour as default, an entry in `options`, and the hook in
// translated code marked `// ENHANCEMENT <ID>` reading `enhancements.section0.<field>`.
// Difficulty knobs (M10) go into Section0Difficulty (Optionals, nil = original; keys "s0.diff.<knob>").

public struct Section0Options: EnhancementGroup {
    public init() {}
    public static let prefix = "s0"
    public static let title = "Jungle & village (section 0)"
    public static let owner = "section0"

    /// M10 knobs of this section (resolved from the preset at game start).
    public var difficulty = Section0Difficulty()

    public static let options: [EnhancementOption<Section0Options>] = [
        // .bool("example", \.example, id: "S0", gameplay: true, help: "..."),
        // .optionalInt("diff.example", \.difficulty.example, id: "M10", gameplay: true, help: "..."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }
}

/// M10 difficulty knobs of Jungle & village (section 0) (all nil = original).
public struct Section0Difficulty: DifficultyKnobs {
    public init() {}
    // public var example: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> Section0Difficulty {
        let k = Section0Difficulty()
        switch p {
        case .recruit: break          // k.example = ...
        case .veteran: break
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: Section0Difficulty) -> Section0Difficulty {
        let r = base
        // if let v = example { r.example = v }
        return r
    }
}
