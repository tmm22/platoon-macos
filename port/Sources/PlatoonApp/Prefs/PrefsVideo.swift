import Foundation
import PlatoonCore

// presentation: [presentation] agent — renderer, shaders, framing looks (S13, S14, S16, S17, M19, M20, M21, M24).
// Only the owner edits this file. All of these are display-only (nothing here changes what the game does), so none
// is `.gameplay()`. Keys: Video/VideoLook.swift (VideoKeys). VideoFX reloads the look whenever UserDefaults change.

extension PrefsRegistry {
    static var videoSections: [PrefSection] {
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        let isCustomCRT = { Prefs.int(VideoKeys.crtPreset) == CRTPreset.custom.rawValue }
        return [
            PrefSection(tab: .video, title: "CRT look (M20)",
                        footer: "Used when the filter is CRT (⌘3). Classic is the port's original CRT shader; the presets tie the "
                            + "phosphor mask to the output resolution, so it doesn't make moiré at 1080p/1440p. The scanline "
                            + "slider above drives Classic and Custom. A look only: it doesn't change the 25 Hz jungle movement.",
                        order: 5, items: [
                .choice(VideoKeys.crtPreset, "Preset", default: 0, CRTPreset.allCases.map { ($0.rawValue, $0.title) }),
                .choice(VideoKeys.crtMask, "Phosphor mask", default: 2, [(0, "None"), (1, "Aperture grille"), (2, "Slot mask")]).enabled(if: isCustomCRT),
                .slider(VideoKeys.crtMaskStrength, "Mask strength", default: 0.4, range: 0...1, step: 0.05, format: pct).enabled(if: isCustomCRT),
                .slider(VideoKeys.crtBloom, "Bloom", default: 0.25, range: 0...1, step: 0.05, format: pct).enabled(if: isCustomCRT),
                .slider(VideoKeys.crtPersistence, "Phosphor persistence", default: 0.2, range: 0...0.8, step: 0.05, format: pct,
                        help: "Trails of bright objects that fade per emulated frame.").enabled(if: isCustomCRT),
                .slider(VideoKeys.crtBleed, "Composite colour bleed", default: 0, range: 0...1, step: 0.05, format: pct).enabled(if: isCustomCRT),
                .slider(VideoKeys.crtSharpness, "Horizontal sharpness", default: 0.6, range: 0...1, step: 0.05, format: pct).enabled(if: isCustomCRT),
                .toggle(VideoKeys.crtColour, "1084 / PAL colour response", default: true, help: "A little more gamma and warmer whites, like a Commodore monitor.").enabled(if: isCustomCRT),
            ]),
            PrefSection(tab: .video, title: "Pixel-art upscaler (M19)", footer: "Used when the filter is Pixel-Art Upscaler (MMPX, ⌘4).",
                        order: 4, items: [
                .toggle(VideoKeys.mmpxSharpHud, "Keep the status bar sharp", default: true,
                        help: "The upscaler smooths the game window only; the HUD's digits and bars stay crisp square pixels."),
            ]),
            PrefSection(tab: .video, title: "Around the picture", order: 10, items: [
                .choice(VideoKeys.backdrop, "Side bars (S14)", default: 0, [(0, "Black (original)"), (1, "Ambient glow of the picture")],
                        help: "Fills the bars beside the picture with a blurred, darkened extension of the frame."),
                .slider(VideoKeys.backdropBrightness, "Glow brightness", default: 0.55, range: 0.1...1, step: 0.05, format: pct)
                    .enabled(if: { Prefs.int(VideoKeys.backdrop) == 1 }),
                .choice(VideoKeys.shake, "Screen shake (S13)", default: 0, [(0, "Off (original)"), (1, "Subtle"), (2, "Strong")],
                        help: "Explosions, the bridge blast, hits and the napalm strike shake the picture by up to 2-3 pixels. Never in screenshots or recordings."),
                .toggle(VideoKeys.hitTint, "Red screen-edge flash when you are hit", default: false,
                        help: "A visual cue for playing without sound."),
                .toggle(SniperCue.key, "Final jungle: show which side a sniper shot comes from", default: false,
                        help: "A \"◀ SNIPER\" / \"SNIPER ▶\" caption while the idle shot (the punishment for standing at one depth) "
                            + "is in flight - a visual cue for playing without sound. Display only."),
                .toggle(VideoKeys.srgbTag, "Colour-managed output (sRGB)", default: false,
                        help: "Tags the picture as sRGB so wide-gamut (P3) displays show the Amiga colours as intended "
                            + "instead of more saturated. Off: the colour values go to the display unchanged, as before."),
            ]),
            PrefSection(tab: .video, title: "Accessibility", order: 20, items: [
                .toggle(VideoKeys.nightLift, "Brighten the dark night scenes (S16)", default: false,
                        help: "The tunnels and the flare night were made for a 1084's black level and are nearly invisible on LCD/OLED screens. "
                            + "This lifts the dark tones of the game window only while they are on screen (black stays black). "
                            + "It makes enemies a little easier to spot in the flare night."),
                .slider(VideoKeys.nightLiftAmount, "   amount", default: 0.5, range: 0.1...1, step: 0.05, format: pct)
                    .enabled(if: { Prefs.bool(VideoKeys.nightLift) }),
                .toggle(VideoKeys.reduceFlashing, "Reduce flashing (S17)", default: false,
                        help: "Tones down the red flash when you are hit in the tunnels and the flare night, caps the napalm white-out, "
                            + "and softens the flare's sudden light-up. Display only: the game is unchanged."),
                .slider(VideoKeys.flashCap, "   flash strength", default: 0.5, range: 0.2...1, step: 0.05, format: pct)
                    .enabled(if: { Prefs.bool(VideoKeys.reduceFlashing) }),
                PrefItem.toggle("presentation.steadyPause", "Steady background colour while TAB-paused", default: false,
                                help: "S17 (core option kernel.steadyPauseColour): the original pause cycles the background colour. Applies after a reset.")
                    .enhancement("kernel.steadyPauseColour"),
                .choice(VideoKeys.colourVision, "Colour vision (M21)", default: 0, ColourVision.allCases.map { ($0.rawValue, $0.title) },
                        help: "Assist modes shift the colour differences you can't see into ones you can (the HUD's red/green bars, "
                            + "enemies against the jungle). The simulation modes show how the game looks with that colour-vision type."),
                .slider(VideoKeys.colourVisionStrength, "   strength", default: 1, range: 0.1...1, step: 0.05, format: pct)
                    .enabled(if: { Prefs.int(VideoKeys.colourVision) != 0 }),
                .choice(VideoKeys.hudMagnifier, "HUD magnifier (M21)", default: 0, [(0, "Off"), (1, "Enlarged copy below the picture")],
                        help: "Shows the status bar (time, score, morale, ammo, items) again, magnified, under the game picture; the picture gets smaller to make room."),
                .slider(VideoKeys.hudMagnification, "   magnification", default: 2, range: 1.25...3, step: 0.25, format: { String(format: "%.2f×", $0) })
                    .enabled(if: { Prefs.int(VideoKeys.hudMagnifier) != 0 }),
            ]),
            PrefSection(tab: .video, title: "Recording (M24)",
                        footer: "View ▸ Record Video (⌥⌘R) / Record GIF (⌥⌘G). Recordings run in game time at 50 frames per second "
                            + "(fast-forward is recorded at normal speed, pauses are left out) and show the plain game picture.",
                        order: 30, items: [
                .choice(VideoKeys.recordFolder, "Save recordings to", default: 0,
                        [(0, "Movies ▸ Platoon"), (1, "Desktop"), (2, "Pictures ▸ Platoon")]),
                .choice(VideoKeys.screenshotFolder, "Save screenshots (⌘S) to", default: 0,
                        [(0, "Desktop (original)"), (1, "The recordings folder"), (2, "Pictures ▸ Platoon")]),
                .toggle(VideoKeys.screenshotClipboard, "Also copy ⌘S screenshots to the clipboard", default: false,
                        help: "⌥⌘C copies just the visible picture (320×256) to the clipboard without saving a file."),
                .choice(VideoKeys.recordScale, "Video size", default: 3, [(2, "640×512 (2×)"), (3, "960×768 (3×)"), (4, "1280×1024 (4×)")]),
                .toggle(VideoKeys.recordAspect, "Tag videos with the PAL pixel aspect (16:15)", default: true,
                        help: "Players that honour it (QuickTime, browsers) show the picture 4:3, like the game window."),
                .choice(VideoKeys.gifRate, "GIF frame rate", default: 25, [(25, "25 fps (smaller)"), (50, "50 fps")]),
                .choice(VideoKeys.gifScale, "GIF size", default: 1, [(1, "320×256"), (2, "640×512")]),
                .toggle(VideoKeys.recordBadge, "Show a REC badge while recording", default: true),
                .action("presentation.showRecordings", "Recordings folder", button: "Show in Finder") {
                    VideoCommands.revealFolder()
                },
            ]),
        ]
    }
}
