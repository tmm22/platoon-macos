import Foundation

// OWNER: [presentation]. Static presentation settings (from Preferences) used by MetalRenderer, and their keys.
// Everything here is display-only: nothing reaches the emulated machine.

enum VideoKeys {
    static let crtPreset = "presentation.crtPreset"
    static let crtMask = "presentation.crt.mask"
    static let crtMaskStrength = "presentation.crt.maskStrength"
    static let crtBloom = "presentation.crt.bloom"
    static let crtPersistence = "presentation.crt.persistence"
    static let crtBleed = "presentation.crt.bleed"
    static let crtSharpness = "presentation.crt.sharpness"
    static let crtColour = "presentation.crt.colour1084"
    static let backdrop = "presentation.backdrop"
    static let backdropBrightness = "presentation.backdropBrightness"
    static let shake = "presentation.shake"
    static let hitTint = "presentation.hitEdgeTint"
    static let nightLift = "presentation.nightLift"
    static let nightLiftAmount = "presentation.nightLiftAmount"
    static let reduceFlashing = "presentation.reduceFlashing"
    static let flashCap = "presentation.flashCap"
    static let colourVision = "presentation.colourVision"
    static let colourVisionStrength = "presentation.colourVisionStrength"
    static let hudMagnifier = "presentation.hudMagnifier"
    static let hudMagnification = "presentation.hudMagnification"
    static let recordFolder = "presentation.record.folder"
    static let recordScale = "presentation.record.scale"
    static let recordAspect = "presentation.record.aspect"
    static let gifRate = "presentation.record.gifRate"
    static let gifScale = "presentation.record.gifScale"
    static let recordBadge = "presentation.record.badge"
    static let screenshotFolder = "presentation.screenshot.folder"
}

/// CRT look presets (M20). `classic` is the original single-pass CRT shader of the port, unchanged.
enum CRTPreset: Int, CaseIterable {
    case classic = 0, c1084 = 1, pvm = 2, a520 = 3, custom = 4
    var title: String {
        switch self {
        case .classic: return "Classic (original port look)"
        case .c1084: return "Commodore 1084S (slot mask, bloom)"
        case .pvm: return "Sony PVM (aperture grille, sharp)"
        case .a520: return "A520 composite (colour bleed)"
        case .custom: return "Custom"
        }
    }
    var shortTitle: String { ["Classic", "1084S", "PVM", "A520 Composite", "Custom"][rawValue] }
}

/// Phosphor mask types of the CRT presets.
enum CRTMask: Int { case none = 0, aperture = 1, slot = 2 }

/// Colour-vision modes (M21). Assist modes shift the colour differences a player can't see into ones they can
/// (daltonisation); the simulation modes show how the game looks to such a player (for comparison).
enum ColourVision: Int, CaseIterable {
    case off = 0, deutan = 1, protan = 2, tritan = 3, simDeutan = 4, simProtan = 5, simTritan = 6, greyscale = 7
    var title: String {
        switch self {
        case .off: return "Off"
        case .deutan: return "Deuteranopia assist (green-weak)"
        case .protan: return "Protanopia assist (red-weak)"
        case .tritan: return "Tritanopia assist (blue-weak)"
        case .simDeutan: return "Simulate deuteranopia"
        case .simProtan: return "Simulate protanopia"
        case .simTritan: return "Simulate tritanopia"
        case .greyscale: return "Greyscale"
        }
    }
}

/// The resolved CRT parameters (preset or custom sliders).
struct CRTParams: Equatable {
    var mask: CRTMask = .none
    var maskStrength: Float = 0
    var scanline: Float = 0.35
    var bloom: Float = 0
    var persistence: Float = 0
    var bleed: Float = 0
    var sharpness: Float = 1
    var colour1084 = false

    static func preset(_ p: CRTPreset, scanline: Float) -> CRTParams {
        switch p {
        case .classic: return CRTParams(scanline: scanline)
        case .c1084: return CRTParams(mask: .slot, maskStrength: 0.45, scanline: 0.45, bloom: 0.3, persistence: 0.25, bleed: 0.15, sharpness: 0.55, colour1084: true)
        case .pvm: return CRTParams(mask: .aperture, maskStrength: 0.35, scanline: 0.7, bloom: 0.1, persistence: 0.1, bleed: 0, sharpness: 1, colour1084: false)
        case .a520: return CRTParams(mask: .none, maskStrength: 0, scanline: 0.25, bloom: 0.2, persistence: 0.3, bleed: 0.85, sharpness: 0.25, colour1084: true)
        case .custom:
            return CRTParams(mask: CRTMask(rawValue: Prefs.int(VideoKeys.crtMask)) ?? .none,
                             maskStrength: Float(Prefs.double(VideoKeys.crtMaskStrength)), scanline: scanline,
                             bloom: Float(Prefs.double(VideoKeys.crtBloom)), persistence: Float(Prefs.double(VideoKeys.crtPersistence)),
                             bleed: Float(Prefs.double(VideoKeys.crtBleed)), sharpness: Float(Prefs.double(VideoKeys.crtSharpness)),
                             colour1084: Prefs.bool(VideoKeys.crtColour))
        }
    }
}

/// Every presentation preference the renderer needs, read from Prefs in one go (VideoFX reloads it when
/// UserDefaults change).
struct VideoLook: Equatable {
    var crtPreset: CRTPreset = .classic
    var crt = CRTParams()
    /// S14: 0 black bars (original), 1 ambient glow.
    var backdrop = 0
    var backdropBrightness: Float = 0.45
    /// S13: 0 off, 1 subtle, 2 strong.
    var shake = 0
    var hitTint = false
    /// S16.
    var nightLift = false
    var nightLiftAmount: Float = 0.5
    /// S17.
    var reduceFlashing = false
    var flashCap: Float = 0.5
    /// M21.
    var colourVision: ColourVision = .off
    var colourVisionStrength: Float = 1
    var hudMagnifier = false
    var hudMagnification: Float = 2

    static func load() -> VideoLook {
        var l = VideoLook()
        l.crtPreset = CRTPreset(rawValue: Prefs.int(VideoKeys.crtPreset)) ?? .classic
        // the existing "CRT scanline strength" slider drives Classic and Custom; the other presets use their own
        l.crt = CRTParams.preset(l.crtPreset, scanline: Float(Prefs.double("scanlines")))
        l.backdrop = Prefs.int(VideoKeys.backdrop)
        l.backdropBrightness = Float(Prefs.double(VideoKeys.backdropBrightness))
        l.shake = Prefs.int(VideoKeys.shake)
        l.hitTint = Prefs.bool(VideoKeys.hitTint)
        l.nightLift = Prefs.bool(VideoKeys.nightLift)
        l.nightLiftAmount = Float(Prefs.double(VideoKeys.nightLiftAmount))
        l.reduceFlashing = Prefs.bool(VideoKeys.reduceFlashing)
        l.flashCap = Float(Prefs.double(VideoKeys.flashCap))
        l.colourVision = ColourVision(rawValue: Prefs.int(VideoKeys.colourVision)) ?? .off
        l.colourVisionStrength = Float(Prefs.double(VideoKeys.colourVisionStrength))
        l.hudMagnifier = Prefs.int(VideoKeys.hudMagnifier) != 0
        l.hudMagnification = Float(Prefs.double(VideoKeys.hudMagnification))
        return l
    }
}
