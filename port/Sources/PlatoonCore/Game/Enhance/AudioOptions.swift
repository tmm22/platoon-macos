// Enhancement options of the audio (music driver / Paula side).
// OWNER: the audio agent (wave 2). Only the owner edits this file. Registry rules: Enhance/Registry.swift.
//
// All audio options are presentation only (gameplay: false): they never change RAM, registers, interrupts or timing,
// so they don't taint a run. They are applied to the machine's Paula when the run's music driver first runs
// (Game/Audio/AudioEnhance.swift); only values that differ from the default are applied, so the app's live mixer
// settings (Prefs/PrefsAudio.swift, applied straight to Paula) are left alone. Headless use:
//   platoon-headless --enh audio.ghostVoices=1,audio.synthesis=blep,audio.sfxVolume=0.5 --wav out.wav ...
//   (the --music-test / --sfx-test harness reads PLATOON_ENH="audio.ghostVoices=1,..." instead)

public struct AudioOptions: EnhancementGroup {
    public init() {}
    public static let prefix = "audio"
    public static let title = "Audio"
    public static let owner = "audio"

    /// M12: music survives sound effects on 4 host-only ghost voices.
    public var ghostVoices = false
    /// M25: Paula synthesis (legacy = the original output; blep = band-limited steps).
    public var synthesis = PaulaSynthesis.legacy
    /// S10: music / sound-effect volume (1 = original).
    public var musicVolume = 1.0
    public var sfxVolume = 1.0
    /// S10: pan of voices 0-3 (-1 left ... +1 right; Amiga = -1, 1, 1, -1).
    public var pan0 = -1.0, pan1 = 1.0, pan2 = 1.0, pan3 = -1.0
    /// M25: ambience reverb on the sound-effect stem (auto = follows the area).
    public var ambience = PaulaAmbience.off
    public var ambienceLevel = 1.0

    public static let options: [EnhancementOption<AudioOptions>] = [
        .bool("ghostVoices", \.ghostVoices, id: "M12", gameplay: false,
              help: "Ghost voices: the music keeps all four parts while sound effects use its channels."),
        .choice("synthesis", \.synthesis, id: "M25", gameplay: false,
                help: "Paula synthesis: legacy (the original output, bit-identical) or blep (band-limited, less aliasing)."),
        .double("musicVolume", \.musicVolume, range: 0...4, id: "S10", gameplay: false, help: "Music volume (1 = original)."),
        .double("sfxVolume", \.sfxVolume, range: 0...4, id: "S10", gameplay: false, help: "Sound-effect volume (1 = original)."),
        .double("pan0", \.pan0, range: -1...1, id: "S10", gameplay: false, help: "Pan of voice 0 (-1 left ... 1 right; Amiga -1)."),
        .double("pan1", \.pan1, range: -1...1, id: "S10", gameplay: false, help: "Pan of voice 1 (Amiga 1)."),
        .double("pan2", \.pan2, range: -1...1, id: "S10", gameplay: false, help: "Pan of voice 2 (Amiga 1)."),
        .double("pan3", \.pan3, range: -1...1, id: "S10", gameplay: false, help: "Pan of voice 3 (Amiga -1)."),
        .choice("ambience", \.ambience, id: "M25", gameplay: false,
                help: "Ambience reverb on the sound effects: off, auto (per area), jungle, hut, tunnels, night, bunker."),
        .double("ambienceLevel", \.ambienceLevel, range: 0...3, id: "M25", gameplay: false, help: "Ambience amount (1 = preset)."),
    ]

    /// Applies the options that differ from their defaults to `p` (host presentation settings).
    public func apply(to p: Paula) {
        let d = AudioOptions()
        if ghostVoices != d.ghostVoices { p.ghostVoices = ghostVoices }
        if synthesis != d.synthesis { p.synthesis = synthesis }
        if musicVolume != d.musicVolume { p.musicGain = Float(musicVolume) }
        if sfxVolume != d.sfxVolume { p.sfxGain = Float(sfxVolume) }
        let pans = [pan0, pan1, pan2, pan3], dp = [d.pan0, d.pan1, d.pan2, d.pan3]
        if pans != dp { p.pan = pans.map { Float($0) } }
        if ambience != d.ambience { p.ambience = ambience }
        if ambienceLevel != d.ambienceLevel { p.ambienceLevel = Float(ambienceLevel) }
    }
}
