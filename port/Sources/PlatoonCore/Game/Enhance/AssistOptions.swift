// Enhancement options of the assists that need a hook in core / translated code (the host-only assists - overlays,
// maps, message log, captions - are app settings and do not need entries here).
// OWNER: the assist agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Wave 2 result: no option is needed here. The assists (S8 log/captions/speech, M2 objectives/HUD, M16 timer and
// service record, M17 replays) only read the game (F1/F2), and M11 practice starts drills from loop-head snapshots
// (F5/L1) prepared from the verified input scripts instead of patching translated code (Game/Assist/PracticeDrills.swift);
// the snapshot restore marks the game assisted. L3 / M3 variant B / M5 were done by the section owners.
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
