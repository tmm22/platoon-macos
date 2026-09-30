import AppKit
import PlatoonCore

// L4 widescreen jungle (owner: section0): the jungle scenery continues into the letterbox bars left and right of the
// 304-px jungle window. Host-rendered from the section-0 map and tiles in RAM (PlatoonCore JungleWidescreen) for the
// scroll position of the buffer ON SCREEN (JungleWideLatch, latched by the section code when it swaps buffers, so
// the sides never tear by a tick). Background only: enemies, bullets and the player exist only in the centre, and
// the sides fade into the dark towards the outer edge. The HUD stays 320 px wide (the picture is T-shaped).
// Hidden during dissolves, man select, inside the huts (level 5) and in the other sections.
//
// Composited by the presentation owner's renderer (Video/SideColumns.swift, SideColumnCompositor): the columns are
// drawn inside the Metal drawable beside the game image with the game's scale and screen shake, over the backdrop
// (S14) or the black bars. They are never part of the Amiga canvas or ⌘S screenshots.
//
// Presentational, but it shows a little more of the jungle ahead (a small navigation advantage): off by default,
// pref section0.wide (Video tab). Optional section0.wideReserve makes room in a 4:3 window too (smaller picture).

final class JungleWideController {
    static let shared = JungleWideController()
    static let kEnabled = "section0.wide"
    static let kWidth = "section0.wideWidth"
    static let kFade = "section0.wideFade"
    static let kReserve = "section0.wideReserve"

    private var latch: JungleWideLatch?
    private weak var latchedMachine: Machine?
    private var submittedKey = ""
    private var showing = false

    var enabled: Bool { Prefs.bool(JungleWideController.kEnabled) }
    var cols: SideColumnCompositor { SideColumnCompositor.shared }

    /// (Re)attaches the latch to the current Machine (a reset or a loaded game creates a new one).
    func attach(_ host: GameHost) {
        if let m = latchedMachine, m !== host.machine { JungleWideLatch.detach(m) }
        applyReserve()
        guard enabled else {
            if let m = latchedMachine { JungleWideLatch.detach(m) }
            latch = nil; latchedMachine = nil
            hide()
            return
        }
        latch = JungleWideLatch.attach(host.machine)
        latchedMachine = host.machine
    }

    /// Lowres px the layout reserves on each side even in a narrow window (0 = original layout).
    func applyReserve() {
        cols.reservedWidth = enabled ? max(0, min(256, Prefs.int(JungleWideController.kReserve))) : 0
    }

    /// Every emulated frame (game thread parked).
    func frame(_ ctx: FrameContext) {
        guard enabled else { return }
        if latchedMachine !== ctx.machine { attach(ctx.host) }
        latch?.frameStart(ctx.machine)
    }

    private func hide() {
        if showing { cols.clear(); showing = false; submittedKey = "" }
    }

    /// Every displayed frame.
    func display(_ ctx: FrameContext?) {
        applyReserve()                                   // cheap; the compositor relayouts only on a change
        guard enabled, let ctx = ctx, let latch = latch, latchedMachine === ctx.machine,
              let s = latch.displayed, s.valid, s.palette == 0x19ff8, s.level != 5,
              ctx.game.loadedSection == 0, ctx.game.screen == .playing || ctx.game.screen == .trapDoorPrompt
        else { hide(); return }
        let maxPx = Int(max(16, min(256, Prefs.double(JungleWideController.kWidth))))
        let L = JungleWidescreen.canvasLeftEdge, R = JungleWidescreen.canvasRightEdge
        let room = cols.room(leftEdge: L, rightEdge: R)
        let wl = min(maxPx, room.left), wr = min(maxPx, room.right)
        guard wl > 0 || wr > 0 else { hide(); return }
        let mem = ctx.memory
        let pal = JungleWidescreen.topPalette(mem)
        let fade = Prefs.bool(JungleWideController.kFade)
        // the bridge patch ($1b209/$1b20a) changes the map without a scroll change
        let key = "\(s.level) \(s.T) \(s.c34) \(s.hscroll) \(wl) \(wr) \(fade) \(pal.hashValue) \(mem.r8(0x1b209)) \(mem.r8(0x1b20a))"
        guard key != submittedKey else { return }
        submittedKey = key
        let left = JungleWidescreen.render(mem, s, fromX: -wl, width: wl, palette: pal)
        let right = JungleWidescreen.render(mem, s, fromX: JungleWidescreen.windowWidth, width: wr, palette: pal)
        cols.submit(SideColumnFrame(width: wl, rightWidth: wr, firstLine: JungleWidescreen.canvasFirstLine,
                                    lines: JungleWidescreen.rows, leftEdge: L, rightEdge: R,
                                    left: left, right: right, fog: fade ? 0.8 : 0))
        showing = true
    }

    /// Test helper: the pixels that would be submitted for the current state (nil = hidden).
    var lastSubmitted: SideColumnFrame? { showing ? cols.current : nil }
}
