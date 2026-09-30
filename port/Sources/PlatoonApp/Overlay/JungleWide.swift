import AppKit
import PlatoonCore

// L4 widescreen jungle (owner: section0): the jungle scenery continues into the letterbox bars left and right of the
// 320-px jungle window. Host-rendered from the section-0 map and tiles in RAM (PlatoonCore JungleWidescreen) for the
// scroll position of the buffer ON SCREEN (JungleWideLatch, latched by the section code when it swaps buffers, so
// the sides never tear by a tick). Background only: enemies, bullets and the player exist only in the centre, and
// the sides fade into the dark towards the outer edge. The HUD stays 320 px wide (the picture is T-shaped).
// Hidden during dissolves, man select, inside the huts (level 5) and in the other sections.
//
// Presentational, but it shows a little more of the jungle ahead (a small navigation advantage): off by default,
// pref section0.wide (Video tab). Composited as overlay panels (never in screenshots / the Metal drawable, and not
// processed by the CRT shader); see port/STATUS.md for the MetalRenderer API offered to the presentation owner.

final class JungleWideView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .linear
        layer?.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }
    func setImage(_ img: CGImage?) { layer?.contents = img }
}

final class JungleWidePanel: OverlayPanel {
    enum Side { case left, right }
    let side: Side
    let wideView = JungleWideView(frame: .zero)
    /// Width in lowres pixels of the last layout (0 = no room).
    private(set) var widthPx = 0
    private var drawnKey = ""

    init(side: Side) {
        self.side = side
        super.init(id: side == .left ? "section0.wideLeft" : "section0.wideRight", view: wideView, anchor: .fillGame, zIndex: 1)
        isVisible = false
    }

    /// Right beside the jungle window: visible lowres x 16..336 (DIW $81..$1c1), rows y 16..160 (lines $3c..$cb).
    override func frame(in l: OverlayLayout) -> CGRect {
        let maxPx = Int(max(16, min(256, Prefs.double(JungleWideController.kWidth))))
        let top = l.point(x: 16, y: 16), bottom = l.point(x: 16, y: 16 + 144)
        let edgeL = l.point(x: 16, y: 0).x, edgeR = l.point(x: 336, y: 0).x
        var px: Int
        switch side {
        case .left: px = Int(((edgeL - l.bounds.minX) / l.scaleX).rounded(.down))
        case .right: px = Int(((l.bounds.maxX - edgeR) / l.scaleX).rounded(.down))
        }
        px = max(0, min(maxPx, px))
        widthPx = px
        let w = CGFloat(px) * l.scaleX
        let x = side == .left ? edgeL - w : edgeR
        return CGRect(x: x, y: top.y, width: w, height: bottom.y - top.y)
    }

    func show(_ img: CGImage?, key: String) {
        guard key != drawnKey else { return }
        drawnKey = key
        wideView.setImage(img)
    }
    func clear() { drawnKey = ""; wideView.setImage(nil) }
}

/// Owns the latch and the two side panels.
final class JungleWideController {
    static let shared = JungleWideController()
    static let kEnabled = "section0.wide"
    static let kWidth = "section0.wideWidth"
    static let kFade = "section0.wideFade"

    let left = JungleWidePanel(side: .left), right = JungleWidePanel(side: .right)
    private var latch: JungleWideLatch?
    private weak var latchedMachine: Machine?

    var enabled: Bool { Prefs.bool(JungleWideController.kEnabled) }

    /// (Re)attaches the latch to the current Machine (a reset creates a new one).
    func attach(_ host: GameHost) {
        if let m = latchedMachine, m !== host.machine { JungleWideLatch.detach(m) }
        guard enabled else {
            if let m = latchedMachine { JungleWideLatch.detach(m) }
            latch = nil; latchedMachine = nil
            return
        }
        latch = JungleWideLatch.attach(host.machine)
        latchedMachine = host.machine
    }

    /// Every emulated frame.
    func frame(_ ctx: FrameContext) {
        guard enabled else { return }
        if latchedMachine !== ctx.machine { attach(ctx.host) }
        latch?.frameStart(ctx.machine)
    }

    /// Every displayed frame.
    func display(_ ctx: FrameContext?) {
        guard enabled, let ctx = ctx, let latch = latch, latchedMachine === ctx.machine,
              let s = latch.displayed, s.valid, s.palette == 0x19ff8, s.level != 5,
              ctx.game.loadedSection == 0, ctx.game.screen == .playing || ctx.game.screen == .trapDoorPrompt
        else {
            for p in [left, right] where p.isVisible { p.isVisible = false; p.clear() }
            return
        }
        let mem = ctx.memory
        let pal = JungleWidescreen.topPalette(mem)
        let fade = Prefs.bool(JungleWideController.kFade)
        for p in [left, right] {
            if !p.isVisible { p.isVisible = true; AppServices.shared.overlay.setNeedsLayout() }
            let w = p.widthPx
            guard w > 0 else { p.clear(); continue }
            let key = "\(s.level) \(s.T) \(s.c34) \(s.hscroll) \(w) \(fade) \(pal.hashValue) \(mem.r8(0x1b209)) \(mem.r8(0x1b20a))"
            let from = p.side == .left ? -w : 320
            p.show(JungleWideController.image(mem, s, from: from, width: w, palette: pal, fade: fade, fadeLeft: p.side == .left), key: key)
        }
    }

    static func image(_ mem: Memory, _ s: JungleWideLatch.State, from: Int, width: Int, palette: [UInt32], fade: Bool, fadeLeft: Bool) -> CGImage? {
        var px = JungleWidescreen.render(mem, s, fromX: from, width: width, palette: palette)
        let rows = JungleWidescreen.rows
        if fade {
            for x in 0..<width {
                // 1.0 at the seam -> 0.2 at the outer edge
                let d = Double(fadeLeft ? width - 1 - x : x) / Double(max(1, width - 1))
                let f = UInt32((1.0 - 0.8 * d) * 256)
                for y in 0..<rows {
                    let c = px[y * width + x]
                    let r = ((c >> 16) & 255) * f >> 8, g = ((c >> 8) & 255) * f >> 8, b = (c & 255) * f >> 8
                    px[y * width + x] = 0xff00_0000 | r << 16 | g << 8 | b
                }
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
