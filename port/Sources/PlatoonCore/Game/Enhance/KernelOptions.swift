// Kernel / resident enhancement options (owner: core). Hooks in Kernel*.swift / Resident.swift, marked
// `// ENHANCEMENT <ID>`. All defaults = original behaviour (except originalCredits, a presentational default).

public struct KernelOptions: EnhancementGroup {
    public init() {}
    public static let prefix = "kernel"
    public static let title = "Kernel (title, HUD, hiscores)"
    public static let owner = "core"

    /// Credits page: the original Ocean lines instead of the Darc crack's (Resident.swift reloc_stub). Default on.
    public var originalCredits = true
    /// Verification only (not in the Preferences): reproduce tools/amiga/emu instead of a real A500 - the
    /// Musashi CPU timing with instant blits (KernelSupport CPU-time model) and the emulator's simplified Paula
    /// (no audio DMA slot limit, no LED filter, 4.9 kHz fixed filter). The regression and audio gates run with
    /// it, so they stay byte-identical to the pinned pre-enhancement baseline. Default off = real A500.
    public var referenceEmulator = false
    /// S12: music/FX mode (the F10 state, $66(a6): bit0 music, bit1 fx) set at the first boot instead of 3 (both on).
    /// nil = original. The host persists the player's last F10 state from GameContext.soundFlags.
    public var soundFlagsAtBoot: Int? = nil
    /// S17: TAB pause without the COLOR00 sawtooth strobe (level6_raster skips the pause colour write).
    public var steadyPauseColour = false
    /// S18: type the hiscore name on the keyboard (A-Z, 0-9, space, Backspace, Return) besides the joystick.
    /// The host must stop mapping letter keys (Z!) to joystick fire while GameContext.screen == .nameEntry.
    public var keyboardNameEntry = false
    /// S9 (h), kernel part: the BCD mission timer stops at 00:00 instead of wrapping to 59:59 (the 59:59 flash on
    /// the HUD during the section-2 napalm strike). Time-up detection (timer == 0) is unchanged.
    public var timerStopsAtZero = false
    /// S5: runs that used the original cheats (HAMBURGER / MEGA CHEAT, $70(a6) != 0) are scored in the assisted
    /// table. Default off = original (cheat scores enter the table as on the Amiga).
    public var separateCheatScores = false
    /// M10 kernel knobs.
    public var difficulty = KernelDifficulty()

    public static let options: [EnhancementOption<KernelOptions>] = [
        .bool("originalCredits", \.originalCredits, id: "kernel", gameplay: false,
              help: "Credits page shows the original Ocean lines (default on)."),
        .bool("referenceEmulator", \.referenceEmulator, id: "verify", gameplay: false,
              help: "Verification: tools/amiga/emu timing (instant blits) and Paula instead of a real A500."),
        .optionalInt("soundFlagsAtBoot", \.soundFlagsAtBoot, range: 0...3, id: "S12", gameplay: false,
                     help: "F10 music/FX mode at power-on: 0 off, 1 music, 2 fx, 3 both (original: 3)."),
        .bool("steadyPauseColour", \.steadyPauseColour, id: "S17", gameplay: false,
              help: "TAB pause without the flashing background colour."),
        .bool("keyboardNameEntry", \.keyboardNameEntry, id: "S18", gameplay: false,
              help: "Type your hiscore name on the keyboard (Backspace, Return = end)."),
        .bool("timerStopsAtZero", \.timerStopsAtZero, id: "S9h", gameplay: false,
              help: "Mission timer stops at 00:00 instead of wrapping to 59:59 during the napalm strike."),
        .bool("separateCheatScores", \.separateCheatScores, id: "S5", gameplay: false,
              help: "Games played with the original cheat codes go to the assisted hiscore table."),
        .optionalInt("diff.startMorale", \.difficulty.startMorale, range: 0x100...0xffff, id: "M10", gameplay: true,
                     help: "Morale at the start of a new game (8.8 fixed point; original $9000)."),
    ]

    public mutating func applyDifficulty(_ preset: DifficultyPreset) {
        difficulty = difficulty.resolving(preset)
    }
}

/// M10 knobs that live in kernel code.
public struct KernelDifficulty: DifficultyKnobs {
    public init() {}
    /// New-game morale (k_title_poll / k_start_new_game: `move.w #$9000,$2e(a6)`). Custom "half morale" = $4800.
    public var startMorale: Int? = nil

    public static func preset(_ p: DifficultyPreset) -> KernelDifficulty {
        var k = KernelDifficulty()
        switch p {
        case .recruit: k.startMorale = 0xc000
        case .veteran: k.startMorale = 0x6c00
        case .original, .custom: break
        }
        return k
    }

    public func merged(over base: KernelDifficulty) -> KernelDifficulty {
        var r = base
        if let v = startMorale { r.startMorale = v }
        return r
    }
}
