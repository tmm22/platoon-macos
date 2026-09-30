import Foundation
import PlatoonCore

// input: [input] agent — controls, key/controller bindings (S2, S3, S15, S18 host part, M7, M13, L2a, S13 rumble).
// Only the owner edits this file. Every option here is host-only (the translated game is untouched); the defaults
// are the original app's behaviour, except the S2 controller extras (buttons that did nothing before) and the S3
// layout-following letters (a bug fix for non-US keyboards; identical on US layouts).

extension PrefsRegistry {
    static var inputSections: [PrefSection] {
        let apply: () -> Void = { InputFeature.shared.applyPrefs() }
        let kbPresets: [(Int, String)] = BindingSet.KeyboardPreset.allCases.map { ($0.rawValue, $0.title) } + [(BindingSet.customPreset, "Custom (Controls & Bindings window)")]
        let padPresets: [(Int, String)] = BindingSet.PadPreset.allCases.map { ($0.rawValue, $0.title) } + [(BindingSet.customPreset, "Custom (Controls & Bindings window)")]
        return [
            PrefSection(tab: .input, title: "Keyboard", footer: "S3/M7. Keys that are not bound to an action type their Amiga key, so the cheat codes and "
                        + "the high-score name still work. Click \"Controls & Bindings…\" to rebind single actions.", order: 0, items: [
                .choice(InputSettings.keyboardPresetKey, "Layout", default: 0, kbPresets,
                        help: "Original: Space is fire AND the Amiga SPACE key (jungle grenade, flare), Z is fire. Separate: Z/X fire, Space only SPACE.")
                    .onChange { InputFeature.applyPresetPrefs(keyboard: true) },
                .toggle(InputSettings.layoutLettersKey, "Letter keys follow the keyboard layout", default: true,
                        help: "S3. On QWERTZ/AZERTY the key labelled Y answers Yes and the key labelled Z fires. Off = US key positions (the original port).")
                    .onChange { InputFeature.shared.applyBindings() },
                .action("input.openControls", "Rebind keys and controller buttons", button: "Controls & Bindings…") {
                    ControlsWindowController.shared.show()
                },
            ]),
            PrefSection(tab: .input, title: "Controller", footer: "S2. Extended adds jobs only to buttons that did nothing: X = SPACE (grenade / flare), "
                        + "Y = change soldier, LB = Yes, LT = No. Hold the left stick button to fast-forward, R3 to rewind (when on).", order: 10, items: [
                .choice(InputSettings.padPresetKey, "Buttons", default: 0, padPresets)
                    .onChange { InputFeature.applyPresetPrefs(keyboard: false) },
                .toggle(InputSettings.padContextKey, "Trap door: A answers Yes, B answers No", default: true,
                        help: "S2 context buttons: at the trap-door prompt a fresh press of A (or another fire button) also sends Y, B sends N.")
                    .onChange(apply),
                .toggle(InputSettings.padHintsKey, "Show controller hints at prompts", default: true,
                        help: "Trap door, choose your man and name entry show the controller's buttons (only while a controller is connected).")
                    .onChange(apply),
                .slider(InputSettings.deadZoneKey, "Stick dead zone", default: 0.4, range: 0.15...0.8, step: 0.05,
                        format: { "\(Int(($0 * 100).rounded()))%" }).onChange(apply),
            ]),
            PrefSection(tab: .input, title: "High-score name", order: 20, items: [
                PrefItem.toggle("input.keyboardNameEntry", "Type the high-score name on the keyboard", default: false,
                                help: "S18. Letters, digits and space type, Backspace deletes, Return finishes; the joystick still works. Keys that type don't fire meanwhile. Applies after a reset.")
                    .enhancement("kernel.keyboardNameEntry"),
            ]),
            PrefSection(tab: .input, title: "Motor accessibility", footer: "S15/M13. Host-only: the game still reads the stick at its own rate. "
                        + "Tap stretching and toggles don't mark the run; auto-fire marks it as assisted once it fires.", order: 30, items: [
                .toggle(InputSettings.tapStretchKey, "Stretch short taps (minimum hold)", default: false,
                        help: "S15. Every press and release of the stick, fire and the Amiga keys lasts at least the frames below, so quick taps aren't lost between the tunnels' 4-frame stick reads.")
                    .onChange(apply),
                .choice(InputSettings.tapStretchFramesKey, "Minimum hold", default: 4, [(2, "2 frames"), (3, "3 frames"), (4, "4 frames"), (6, "6 frames"), (8, "8 frames")])
                    .onChange(apply).enabled(if: { Prefs.bool(InputSettings.tapStretchKey) }),
                .toggle(InputSettings.toggleFireKey, "Toggle fire (tap to hold, tap again to release)", default: false).onChange(apply),
                .toggle(InputSettings.toggleDirsKey, "Toggle directions (tap UP to keep walking)", default: false,
                        help: "A tap latches a direction; tapping it again, or the opposite direction, releases it. Only during play.").onChange(apply),
                .choice(InputSettings.autoFireKey, "Auto-fire", default: 0, [(0, "Off"), (1, "While fire is held"), (2, "Turbo-fire button only")],
                        help: "M13. Fire pulses on and off (at least one game tick each), useful for the final jungle's one-shot-per-press rifle. Bind the turbo-fire button in Controls & Bindings.")
                    .onChange(apply),
                .choice(InputSettings.autoFireRateKey, "Auto-fire speed", default: 0, [(0, "Automatic per section"), (2, "Fast (2 frames)"), (3, "3 frames"), (4, "4 frames"), (6, "Slow (6 frames)")])
                    .onChange(apply).enabled(if: { Prefs.int(InputSettings.autoFireKey) != 0 }),
            ]),
            PrefSection(tab: .input, title: "Aiming (tunnels and flare)", footer: "L2. The mouse / trackpad pointer over the picture, or the right stick, "
                        + "steers the crosshair by pressing the virtual stick for you (original speed and limits). Left click fires, right click is SPACE in the flare dugout. "
                        + "Marks the run as assisted once it aims. With the gameplay option \"Direct aim\" (Gameplay tab) the crosshair jumps to the pointer instead.", order: 40, items: [
                .choice(InputSettings.aimAssistKey, "Assisted aiming", default: 0, [(0, "Off (original)"), (1, "Pointer and right stick")]).onChange(apply),
                .slider(InputSettings.aimSpeedKey, "Right stick reach", default: 40, range: 10...120, step: 5, format: { "\(Int($0)) px" })
                    .onChange(apply).enabled(if: { Prefs.int(InputSettings.aimAssistKey) != 0 }),
            ]),
            PrefSection(tab: .input, title: "Controller rumble", footer: "S13. Explosions, hits, shots, wounds, the bridge blast and the napalm strike.", order: 50, items: [
                .toggle(InputSettings.rumbleKey, "Rumble on game events", default: false).onChange(apply),
                .slider(InputSettings.rumbleStrengthKey, "Strength", default: 1.0, range: 0.2...1, step: 0.1, format: { "\(Int(($0 * 100).rounded()))%" })
                    .onChange(apply).enabled(if: { Prefs.bool(InputSettings.rumbleKey) }),
            ]),
        ]
    }
}

extension InputFeature {
    /// A preset popup changed: rewrite that half of the binding table (Custom leaves it alone).
    static func applyPresetPrefs(keyboard: Bool) {
        var b = InputSettings.load()
        if keyboard {
            guard let p = BindingSet.KeyboardPreset(rawValue: Prefs.int(InputSettings.keyboardPresetKey)) else { return }
            b.applyKeyboard(p)
        } else {
            guard let p = BindingSet.PadPreset(rawValue: Prefs.int(InputSettings.padPresetKey)) else { return }
            b.applyPad(p)
        }
        InputSettings.save(b)
        shared.applyBindings()
        ControlsWindowController.shared.model.reload()
    }
}
