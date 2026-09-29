// M10 difficulty presets: schema (owner: core). The per-section knob VALUES are filled in by the section owners in
// their own groups (Section0Options.swift, ...); the kernel's own knobs are in KernelOptions.swift.
//
// Rules (port/ENHANCEMENT_IDEAS.md M10):
// - Every knob is an Optional; nil = the original literal. Hooks read `enhancements.sectionN.difficulty.x ?? <literal>`
//   and must never add or remove a k_random() call (mask/clamp AFTER the call), so Original stays bit-exact.
// - `Original` resolves to all-nil knobs. `Recruit` / `Veteran` fill knobs that were not set explicitly.
//   `Custom` uses only the knobs set explicitly (keys "<prefix>.diff.<knob>", e.g. "s0.diff.hitMorale=0x400").
// - Presets are resolved once at game start (Enhancements.resolved(), PlatoonGame.main), so a change needs a reset.
// - Any preset other than Original, and any explicitly set knob, taints the run; its hiscores go to a per-mode table
//   (hiscores-recruit.bin / hiscores-veteran.bin / hiscores-custom.bin, see Enhance/Hiscores.swift).
// - The preset is shown on the "ENTERING THE COMBAT ZONE" screen by the host (F1 context `difficulty`), not queued
//   as a HUD message.

/// The preset chosen by the player.
public enum DifficultyPreset: String, CaseIterable {
    case original, recruit, veteran, custom
    public var title: String {
        switch self {
        case .original: return "Original"
        case .recruit: return "Recruit"
        case .veteran: return "Veteran"
        case .custom: return "Custom"
        }
    }
}

/// A group's set of difficulty knobs (all Optionals, nil = original).
public protocol DifficultyKnobs {
    init()
    /// Knob values of a preset (`.original` and `.custom` must return all-nil).
    static func preset(_ p: DifficultyPreset) -> Self
    /// `self` (explicitly set knobs) over `base` (preset values): non-nil fields of self win.
    func merged(over base: Self) -> Self
}

extension DifficultyKnobs {
    /// The knobs after resolving preset `p` (explicit values win).
    public func resolving(_ p: DifficultyPreset) -> Self { merged(over: Self.preset(p)) }
}
