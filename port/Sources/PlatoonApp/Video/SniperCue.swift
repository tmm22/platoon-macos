import AppKit
import PlatoonCore

// OWNER: [presentation]. S13 (optional part): directional "SNIPER" caption for the final jungle's idle shot, a
// visual cue for players who can't hear the shot's sound ($82). Read-only RAM access at the frame hook:
//   $57f60 (l) = slot address of the idle shot (0 = none; re/finaljungle/NOTES.md b.12);
//   slot +a = handler ($17414 first tick / $1741e in flight), slot +e = dx (+8 from the left edge x $18,
//   -7 from the right edge x $110).
// Display-only (the shot and its side are on screen anyway, the cue only makes them easier to notice), default off.

final class SniperCue {
    static let shared = SniperCue()
    static let key = "presentation.sniperCue"

    private static let idleSlot: UInt32 = 0x57f60
    private static let handlers: Set<UInt32> = [0x17414, 0x1741e]

    private let panel = TextOverlayPanel(id: "presentation.sniperCue", anchor: .game(.left, inset: 12), zIndex: 120, fontSize: 16)
    private var enabled = false
    /// Side of the last shot (-1 left, +1 right) and emulated frames the caption stays up after it ends.
    private var side = 0
    private var hold = 0
    /// Emulated frames to keep the caption after the shot is gone (so a quick shot is still readable).
    static let holdFrames = 30

    func install(_ app: AppServices) {
        panel.label.textColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1)
        app.overlay.add(panel)
        enabled = Prefs.bool(SniperCue.key)
        app.onFrame { [weak self] ctx in self?.frame(ctx) }
        app.onReset { [weak self] _ in self?.clear() }
    }

    /// The shot's side if one is flying: -1 = comes from the left, +1 = from the right, nil = none.
    static func shotSide(_ mem: Memory, _ g: GameContext) -> Int? {
        guard g.loadedSection == 2, g.inGame, g.screen == .playing, g.area == .finalJungle else { return nil }
        let slot = mem.r32(idleSlot)
        guard slot != 0, slot < 0x80000, handlers.contains(mem.r32(slot &+ 0xa)) else { return nil }
        return Int16(bitPattern: mem.r16(slot &+ 0xe)) < 0 ? 1 : -1
    }

    private func clear() { side = 0; hold = 0; panel.text = nil }

    private func frame(_ ctx: FrameContext) {
        enabled = Prefs.bool(SniperCue.key)
        guard enabled else { if panel.isVisible || side != 0 { clear() }; return }
        if let s = SniperCue.shotSide(ctx.memory, ctx.game) {
            if s != side || !panel.isVisible {
                side = s
                panel.anchor = .game(s < 0 ? .left : .right, inset: 12)
                panel.text = s < 0 ? "◀ SNIPER" : "SNIPER ▶"
                VideoFX.shared.note("sniper cue \(s < 0 ? "left" : "right")")
            }
            hold = SniperCue.holdFrames
        } else if hold > 0 {
            hold -= 1
            if hold == 0 { clear() }
        } else if panel.isVisible { clear() }
    }
}
