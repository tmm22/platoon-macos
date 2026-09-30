import AppKit
import PlatoonCore

// S7 hint (owner: section0): "suspicious spot" warning inside a hut when the player stands on a search spot that is
// still a live booby trap (search table $1aafa entry whose message byte is still $0f; it becomes a flavour entry once
// it has gone off). Host-only and read-only; the search itself is not changed. It reveals hidden information, so a
// run that shows the warning is marked assisted. Pref section0.trapHint (Assist tab).

final class JungleHintPanel {
    static let shared = JungleHintPanel()
    static let kEnabled = "section0.trapHint"

    let panel = TextOverlayPanel(id: "section0.trapHint", anchor: .game(.top, inset: 26), zIndex: 110, fontSize: 14)
    private var marked = false
    private var shownText: String?

    private init() { panel.maxWidth = 420 }

    var enabled: Bool { Prefs.bool(JungleHintPanel.kEnabled) }

    /// Every displayed frame.
    func update(_ ctx: FrameContext?) {
        var text: String? = nil
        if enabled, let ctx = ctx, ctx.game.loadedSection == 0, ctx.game.screen == .playing,
           let j = ctx.game.jungle, j.level == 5, j.playerState == 5 {
            let spots = JungleMapModel.spots(ctx.memory)
            if spots.contains(where: { $0.kind == .boobyTrap && $0.worldX == j.worldX }) {
                text = "⚠  Something doesn't feel right here…"
            }
        }
        if text != nil && !marked { marked = true; AppServices.shared.markAssisted("Booby-trap warning") }
        if text != shownText { shownText = text; panel.text = text }
    }

    func reset() { marked = false; shownText = nil; panel.text = nil }
}
