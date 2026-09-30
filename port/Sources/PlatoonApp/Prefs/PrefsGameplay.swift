import Foundation
import PlatoonCore

// Shared Gameplay page (owner: [assist], wave 2; schema by [core]): M10 difficulty presets and M15 full platoon /
// extra lives. The preset and knob VALUES come from the core registry (Enhance/Difficulty.swift and each section's
// <Group>Difficulty: preset() + help texts written by the section owners); this file only presents them.
// Only the owner edits this file.
//
//  - "Difficulty": the preset popup (enhancement key `difficulty`) and a live summary of what the chosen preset
//    changes, computed with Enhancements.resolved() so it always matches what the game will use.
//  - "Custom difficulty": every `*.diff.*` knob of the catalogue, grouped by section. These rows replace the
//    automatic ones (same UserDefaults keys "enh.<key>", so existing settings are kept). A knob set here overrides
//    the preset's value; with the Custom preset only these knobs apply.
//  - "Platoon": game.lives / game.fullPlatoon.
// All of them are gameplay options: the game is marked assisted and ranks in its own hiscore table (per preset
// when only the preset / knobs are changed, see Enhance/Hiscores.swift).

enum GameplayPrefs {
    static let difficulty = "gameplay.difficulty"
    static let lives = "gameplay.lives"
    static let fullPlatoon = "gameplay.fullPlatoon"

    static var preset: DifficultyPreset {
        let all = DifficultyPreset.allCases
        let i = Prefs.int(difficulty)
        return all.indices.contains(i) ? all[i] : .original
    }

    /// Short, player-facing names of the difficulty knobs (the catalogue's help text is shown below each).
    static let knobTitles: [String: String] = [
        "kernel.diff.startMorale": "Morale at the start",
        "s0.diff.shootMask": "Jungle: how often soldiers shoot",
        "s0.diff.hitMorale": "Jungle: morale lost per hit",
        "s0.diff.villagerMorale": "Morale lost for a villager",
        "s0.diff.grenades": "Jungle: grenades per soldier",
        "s0.diff.ammo": "Jungle: rounds per soldier",
        "s0.diff.spawnFloor": "Jungle: minimum enemy spawn chance",
        "s0.diff.rifleKillsSpider": "Rifle kills the spider-hole VC",
        "s0.diff.trapsWound": "Booby traps only wound",
        "s0.diff.bridgeFailsafe": "Bridge failsafe",
        "s0.diff.noMap": "No tunnel map in the village",
        "s1.diff.hitMorale": "Tunnels: morale lost per wound",
        "s1.diff.spawnDelay": "Tunnels: time between enemies",
        "s1.diff.enemyAim": "Tunnels: enemy aiming time",
        "s1.diff.itemMorale": "Tunnels: morale per useful item",
        "s1.diff.flareSpawnBase": "Flare night: enemy spawn interval",
        "s1.diff.flareShotSlack": "Flare night: how fast enemies hit",
        "s2.diff.timer": "Final jungle: airstrike timer (seconds)",
        "s2.diff.maxSoldiers": "Final jungle: soldiers per room (max)",
        "s2.diff.spawnDelay": "Final jungle: time between soldiers",
        "s2.diff.fireCooldown": "Final jungle: time between soldier shots",
        "s2.diff.sniperDelay": "Final jungle: sniper patience",
        "s2.diff.hitMorale": "Final jungle: morale lost per hit",
        "s2.diff.barnesHits": "Grenade hits to kill Barnes",
        "s2.diff.barnesCooldown": "Barnes: time between shots",
        "s2.diff.grenades": "Final jungle: grenades per soldier",
    ]

    static func knobTitle(_ key: String) -> String {
        knobTitles[key] ?? key.split(separator: ".").last.map(String.init) ?? key
    }

    /// One line per knob the preset changes: "Jungle: morale lost per hit: $400 (original $800)".
    static func presetSummary(_ p: DifficultyPreset) -> [String] {
        guard p != .original, p != .custom else { return [] }
        var e = Enhancements(); e.difficulty = p
        let r = e.resolved()
        return r.changed.filter { !$0.hasPrefix("difficulty=") }.compactMap { kv in
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return "\(knobTitle(parts[0])): \(pretty(parts[0], parts[1]))\(originalText(parts[0]))"
        }
    }

    /// The original literal of a knob, taken from its help text ("(original $800)").
    static func originalText(_ key: String) -> String {
        guard let info = Enhancements.catalog.first(where: { $0.key == key }),
              let r = info.help.range(of: "original") else { return "" }
        var tail = info.help[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        if let end = tail.firstIndex(where: { $0 == ")" || $0 == ";" }) { tail = String(tail[..<end]) }
        if tail.hasSuffix(".") { tail.removeLast() }
        return tail.isEmpty ? "" : " (original \(tail))"
    }

    static func pretty(_ key: String, _ v: String) -> String {
        guard let n = Int(v) else { return v }
        if key.hasSuffix("Morale") || key.hasSuffix("startMorale") || key.hasSuffix("shootMask") { return String(format: "$%X", n) }
        if key.hasSuffix("rifleKillsSpider") || key.hasSuffix("trapsWound") || key.hasSuffix("bridgeFailsafe") || key.hasSuffix("noMap") {
            return n != 0 ? "on" : "off"
        }
        if key == "s2.diff.timer" { return String(format: "%d:%02d", n / 60, n % 60) }
        return String(n)
    }
}

extension PrefsRegistry {
    static var gameplayCoreSections: [PrefSection] {
        let preset = GameplayPrefs.preset
        let summary = GameplayPrefs.presetSummary(preset)
        let presetNote: String
        switch preset {
        case .original: presetNote = "Original: the 1988 game, unchanged (knobs below still apply if you set any)."
        case .custom: presetNote = "Custom: only the knobs you set below change the game."
        default: presetNote = "\(preset.title) changes:\n" + summary.map { "• " + $0 }.joined(separator: "\n")
        }
        var difficulty = PrefItem.choice(GameplayPrefs.difficulty, "Difficulty", default: 0,
                                         DifficultyPreset.allCases.enumerated().map { ($0.offset, $0.element.title) },
                                         help: "Recruit: fewer and slower enemies, more morale, fairer traps. Veteran: more enemies, "
                                            + "fewer supplies, a shorter airstrike timer. Applied when a new game starts; shown on the "
                                            + "ENTERING THE COMBAT ZONE screen. Scores go to a separate table per preset.")
            .gameplay(enhancement: "difficulty")
        difficulty.onChange = { PrefsModel.shared.bump() }

        // M10 knobs: the catalogue's own rows (automatic item builder), with friendlier titles, grouped by section
        var knobSections: [PrefSection] = []
        let groups: [(prefix: String, title: String)] = [("kernel", "All sections"), ("s0", "Jungle & village"),
                                                         ("s1", "Tunnels & flare night"), ("s2", "Final jungle & bunker")]
        for (n, g) in groups.enumerated() {
            let infos = Enhancements.catalog.filter { $0.key.hasPrefix(g.prefix + ".diff.") }
            guard !infos.isEmpty else { continue }
            var items: [PrefItem] = []
            for info in infos {
                var its = PrefsRegistry.autoItems(info)
                guard !its.isEmpty else { continue }
                its[0].title = GameplayPrefs.knobTitle(info.key)
                its[0] = its[0].covers(info.key)
                items += its
            }
            knobSections.append(PrefSection(tab: .gameplay, title: "Custom difficulty: \(g.title) (M10)",
                                            footer: n == groups.count - 1 ? "A knob set here overrides the preset's value. "
                                                + "Left at \"Original\" / off, the preset (or the 1988 game) decides." : nil,
                                            order: 60 + n, items: items))
        }

        return [
            PrefSection(tab: .gameplay, title: "Difficulty (M10)", footer:
                "Every preset except Original changes the game: such games rank in their own high-score table "
                + "(hiscores-recruit / -veteran / -custom) and never in the original one.", order: 50, items: [
                difficulty,
                .note("gameplay.difficulty.summary", presetNote),
            ]),
        ] + knobSections + [
            PrefSection(tab: .gameplay, title: "Platoon (M15)", footer:
                "In the original, the tunnels and the final jungle start again with fresh men and use only two of them. "
                + "These make the later sections much easier, so such games are kept out of the original high scores.",
                        order: 70, items: [
                .choice(GameplayPrefs.lives, "Soldiers in the tunnels and the final jungle", default: 2,
                        [(2, "2 (original)"), (3, "3"), (4, "4"), (5, "All 5")],
                        help: "How many of your men can take over when one falls in sections 2 and 3.")
                    .gameplay(enhancement: "game.lives"),
                .toggle(GameplayPrefs.fullPlatoon, "Full platoon: carry the jungle platoon over", default: false,
                        help: "Wounds, ammunition and fallen men carry over from the jungle into the tunnels and the final "
                            + "jungle; the first living soldier leads.")
                    .gameplay(enhancement: "game.fullPlatoon"),
            ]),
        ]
    }
}
