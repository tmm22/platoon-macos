import Foundation

// Host-side audio glue of the game layer (OWNER: audio; roadmap S10, M12, M25). Not a translation.
// Called from the music driver's play entry once per vblank (`md_play_impl`, marked ENHANCEMENT). It never writes
// RAM or custom registers and charges no CPU time, so the game runs identically; it only configures the machine's
// Paula (a host presentation device):
//   - once per run: the S10 voice tagger (music vs sound effect, from the driver's shadow block $4084+12*ch+$b,
//     "sfx owns channel") and the audio enhancement options of the run (Enhance/AudioOptions.swift);
//   - every vblank with ambience "auto": the ambience preset for the area on screen (F1 context probe).

extension Platoon {
    func md_hostAudioSync() {
        let p = chip.paula
        if p.configuredRun != ObjectIdentifier(self) {
            p.configuredRun = ObjectIdentifier(self)
            let m = mem
            p.voiceIsSfx = { c in m.r8(MD.shadowRegs(c) &+ 0xb) != 0 }
            enhancements.audio.apply(to: p)
        }
        if p.ambience == .auto {
            p.ambienceArea = config.probe.map { Platoon.ambience(for: $0.context) } ?? .off
        }
    }

    /// The ambience preset for what is on screen (auto mode).
    static func ambience(for c: GameContext) -> PaulaAmbience {
        switch c.screen {
        case .playing, .manSelect, .trapDoorPrompt: break
        default: return .off
        }
        switch c.area {
        case .jungle, .village, .finalJungle: return .jungle
        case .hut: return .hut
        case .tunnels: return .tunnels
        case .flare: return .night
        case .bunker: return .bunker
        case .none: return .off
        }
    }
}

extension MusicDriverTestHarness {
    /// PLATOON_ENH audio options for the stand-alone driver harness (--music-test / --sfx-test), which has no
    /// GameConfig: e.g. PLATOON_ENH="audio.ghostVoices=1,audio.synthesis=blep".
    func applyEnvironmentAudioOptions() {
        guard let e = ProcessInfo.processInfo.environment["PLATOON_ENH"] else { return }
        var enh = Enhancements()
        // only the audio keys matter here; other keys (originalCredits, ...) are accepted and ignored
        for kv in e.split(separator: ",") where kv.hasPrefix("audio.") || kv.hasPrefix("referenceEmulator") {
            do { try enh.apply(String(kv)) } catch { FileHandle.standardError.write("PLATOON_ENH: \(error)\n".data(using: .utf8)!) }
        }
        p.enhancements.audio = enh.audio
        if e.contains("referenceEmulator") { p.chip.paula.accurate = !enh.kernel.referenceEmulator }
    }
}
