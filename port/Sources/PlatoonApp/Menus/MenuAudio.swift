import AppKit
import PlatoonCore

// audio: [audio] agent — mixer, voices, audio robustness (S10, S12 sound flags, M12, M22, M25 audio).
// Only the owner edits this file.
//  - `audioMenus`: extra menu items (see Menus/MenuRegistry.swift: MenuContribution, ClosureMenuItem).
//    Pref toggles can appear in menus automatically with PrefItem.inMenu(_:) instead.
//  - `audioInstall`: called once at launch, after menus are built and before the disk is loaded. Register
//    observers and overlay panels here through AppServices (app.onFrame / onDisplay / onReset / onSectionStart /
//    onHostReady, app.overlay.add(panel), app.addPauseMenuItem(...)).

extension MenuRegistry {
    static func audioMenus(_ app: AppServices) -> [MenuContribution] {
        func toggle(_ key: String) { Prefs.set(key, !Prefs.bool(key)) }
        let synth = ClosureMenuItem("Band-limited Synthesis", state: { Prefs.int(AudioPrefs.synthesis) == 1 }) {
            Prefs.set(AudioPrefs.synthesis, Prefs.int(AudioPrefs.synthesis) == 1 ? 0 : 1)
        }
        let amb = ClosureMenuItem("Ambience (Automatic)", state: { Prefs.int(AudioPrefs.ambience) != 0 }) {
            Prefs.set(AudioPrefs.ambience, Prefs.int(AudioPrefs.ambience) == 0 ? 1 : 0)
        }
        let st = ClosureMenuItem("Replacement Soundtrack", state: { Prefs.bool(AudioPrefs.soundtrack) }) {
            toggle(AudioPrefs.soundtrack); AudioEnhancements.shared.soundtrack.rescan()
        }
        let folder = ClosureMenuItem("Choose Soundtrack Folder…") { SoundtrackUI.chooseFolder() }
        let mixer = ClosureMenuItem("Audio Mixer…") { app.openPreferences(tab: .audio) }
        return [MenuContribution(menu: .sound, order: 50, items: [synth, amb, st, folder, mixer])]
    }
}

extension FeatureHooks {
    static func audioInstall(_ app: AppServices) {
        AudioEnhancements.shared.install(app)
    }
}
