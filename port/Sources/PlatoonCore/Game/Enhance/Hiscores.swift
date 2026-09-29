import Foundation

// F4 / S5 hiscore integrity (owner: core): assisted (tainted) runs and per-mode hiscore tables.
//
// A run (one game, from the title's fire / config.startSection to its game over) is ASSISTED when any of these apply:
//   - a gameplay enhancement differs from its default (Enhancements.assistReasons, incl. a difficulty preset),
//   - the host declared a session reason (GameConfig.assistedReasons) or marked one during the run
//     (GameProbe.markAssisted / PlatoonGame.markAssisted: trainer, snapshot load, rewind, practice ...),
//   - the Trainer is active (Trainer.apply marks it automatically),
//   - the game was started by GameConfig.startSection / carry (Continue / Start at section),
//   - kernel.separateCheatScores and the original cheat flags $70(a6) are set.
// Its score is ranked in a separate table: "hiscores-<mode>.bin" next to GameConfig.hiscoreURL, where mode is the
// difficulty preset ("recruit", "veteran", "custom") when that is the only reason, else "assisted". The original
// table (hiscores.bin, the in-RAM track 77 image the title shows) is never touched by such a run. Without a
// hiscoreURL the mode tables are kept in memory for the session.
//
// Mechanism: at k_game_over (before the rank search) the mode table's track image is swapped into RAM at $116cc
// (the original's name buffer $11836 is carried over, so the pre-filled name is the player's usual one); the
// original code then ranks, enters the name, shows and saves exactly as usual; saveHiscores() writes the mode
// file; k_init (every path out of the game over, incl. DEL) swaps the original table back. A run that is not
// assisted executes none of this (byte-identical to the original).

extension Platoon {
    /// Table name for a set of assist reasons.
    static func hiscoreMode(for reasons: Set<String>) -> String {
        if reasons.isEmpty { return "original" }
        let diff = reasons.filter { $0.hasPrefix("difficulty:") }
        let knobsOnly = reasons.allSatisfy { $0.hasPrefix("difficulty:") || $0.contains(".diff.") }
        if knobsOnly {
            if let d = diff.first, diff.count == 1, reasons.count == 1 { return String(d.dropFirst("difficulty:".count)) }
            return "custom"
        }
        return "assisted"
    }

    /// F4: marks the current run as assisted (any thread).
    func markAssisted(_ reason: String) {
        assistLock.lock(); runAssist.insert(reason); assistLock.unlock()
    }

    /// All reasons of the current run.
    func currentAssistReasons() -> Set<String> {
        assistLock.lock(); defer { assistLock.unlock() }
        return sessionAssist.union(runAssist)
    }

    /// A new game starts: forget the previous run's marks.
    func beginRun(section: Int, fromConfig: Bool) {
        assistLock.lock()
        runAssist.removeAll()
        if fromConfig {
            runAssist.insert(config.carry != nil ? "continue" : "startSection")
        }
        assistLock.unlock()
        probeNewGame(section)
    }

    /// The hiscore file of a mode table.
    func hiscoreURL(forMode mode: String) -> URL? {
        config.hiscoreURL.map { $0.deletingLastPathComponent().appendingPathComponent("hiscores-\(mode).bin") }
    }

    /// $fee8 k_game_over, before the rank search: swap the run's table into RAM if the run is assisted.
    func hsEnterRunTable() {
        var reasons = currentAssistReasons()
        if enhancements.kernel.separateCheatScores && mem.r16(a6 + KV.cheats) != 0 { reasons.insert("cheats") }
        guard !reasons.isEmpty, hsSavedOriginal == nil else { return }
        let mode = Platoon.hiscoreMode(for: reasons)
        let original = mem.slice(KA.hiscoreTrack, Disk.trackSize)
        var img: [UInt8]? = hsModeTables[mode]
        if img == nil, let url = hiscoreURL(forMode: mode), let d = try? Data(contentsOf: url), d.count == Disk.trackSize {
            img = [UInt8](d)
        }
        var table = img ?? hsPristine ?? original
        // carry the player's name buffer ($11836, 16 bytes) so the entry is pre-filled with the usual name
        let nb = Int(KA.hsNameBuf - KA.hiscoreTrack)
        for i in 0..<16 { table[nb + i] = original[nb + i] }
        hsSavedOriginal = original
        hsActiveMode = mode
        mem.load(table, at: KA.hiscoreTrack)
        log("hiscores: \(mode) table (\(reasons.sorted().joined(separator: ",")))")
    }

    /// k_init: put the original table back after an assisted run's game over (or a DEL abort during it).
    func hsLeaveRunTable() {
        guard let original = hsSavedOriginal, let mode = hsActiveMode else { return }
        hsModeTables[mode] = mem.slice(KA.hiscoreTrack, Disk.trackSize)
        mem.load(original, at: KA.hiscoreTrack)
        hsSavedOriginal = nil
        hsActiveMode = nil
    }

    /// Where the current table image is persisted (the mode file while a mode table is in RAM).
    var hiscoreSaveURL: URL? {
        if let mode = hsActiveMode { return hiscoreURL(forMode: mode) }
        return config.hiscoreURL
    }
}
