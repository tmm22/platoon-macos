// Enhancement options of the audio (music driver / Paula side).
// OWNER: the audio agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
// Planned items (port/ENHANCEMENT_IDEAS.md): M12 ghost voices (hooks in md_channelTick / md_effects, never through
// chip.write), S10 music/SFX stem tagging, M25 BLEP synthesis ("Legacy" = current output). Host-side mixer settings
// (volumes, pan) belong to the app's Settings, not here; options here are the ones the core must know at game start.
//
// Add an option: a stored property with the ORIGINAL behaviour as default, an entry in `options`, and the hook marked
// `// ENHANCEMENT <ID>` reading `enhancements.audio.<field>`. Audio options are normally not gameplay (gameplay: false).

public struct AudioOptions: EnhancementGroup {
    public init() {}
    public static let prefix = "audio"
    public static let title = "Audio"
    public static let owner = "audio"

    public static let options: [EnhancementOption<AudioOptions>] = [
        // .bool("ghostVoices", \.ghostVoices, id: "M12", gameplay: false, help: "..."),
    ]
}
