// Enhancement options of the assists that need a hook in core / translated code (the host-only assists - overlays,
// maps, message log, captions - are app settings and do not need entries here).
// OWNER: the assist agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Planned items (port/ENHANCEMENT_IDEAS.md): M11 practice mode (flag-gated patches + game-over redirect), L3 randomiser
// (seed), M5 compass assist if done as the one-write variant, M3 variant B (if not owned by section1).
//
// Add an option: a stored property with the ORIGINAL behaviour as default, an entry in `options`, and the hook marked
// `// ENHANCEMENT <ID>` reading `enhancements.assist.<field>`. Anything that changes the game: gameplay: true.

public struct AssistOptions: EnhancementGroup {
    public init() {}
    public static let prefix = "assist"
    public static let title = "Assists"
    public static let owner = "assist"

    public static let options: [EnhancementOption<AssistOptions>] = [
        // .int("randomiserSeed", \.randomiserSeed, id: "L3", gameplay: true, help: "..."),
    ]
}
