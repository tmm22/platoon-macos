import AppKit
import PlatoonCore

// M25 tunnel turn slide (owner: section1). Presentation only, default off (pref section1.turnSlide, Video tab).
// When the heading changes in a tunnel corridor, the old view slides out and the new one slides in over a few
// displayed frames, drawn by an overlay panel exactly over the view window (the game itself, its canvas and ⌘S
// screenshots are unchanged). Pixels come from the displayed canvas: the view is bitplane columns $3b3f8*8..+160,
// lines 0..143 (canvas x = ($71 - $60 + px) * 2, canvas y = $3c - $18 + py). Forward steps already animate in the
// original (walk-phase frames), so only turns slide.

final class TunnelTurnSlide: OverlayPanel {
    static let shared = TunnelTurnSlide()
    static let kEnabled = "section1.turnSlide"
    static let viewW = 160, viewH = 144
    /// Displayed frames of the slide, and how long to wait for the new view to appear after the heading changed.
    static let slideFrames = 6, maxWait = 10

    private let imageLayer = CALayer()
    private var lastHeading: Int?
    private var lastPos: (Int, Int)?
    private var column = 10
    private var current: [UInt32]?           // view pixels of the last displayed frame (while not animating)
    private var old: [UInt32]?, new: [UInt32]?
    private var dir = 1                      // +1 turn right (new view enters from the right), -1 left
    private var waitFrames = 0, step = 0
    private var animating: Bool { old != nil }

    private init() {
        let v = NSView()
        v.wantsLayer = true
        super.init(id: "section1.turnSlide", view: v, anchor: .fillGame, zIndex: 5)
        imageLayer.magnificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        v.layer?.addSublayer(imageLayer)
        isVisible = false
    }

    override func frame(in l: OverlayLayout) -> CGRect {
        let a = l.point(x: Double(column * 8), y: 16)
        let b = l.point(x: Double(column * 8 + TunnelTurnSlide.viewW), y: Double(16 + TunnelTurnSlide.viewH))
        let r = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(origin: .zero, size: r.size)
        CATransaction.commit()
        return r
    }

    private func grab(_ chip: Chipset) -> [UInt32] {
        let w = TunnelTurnSlide.viewW, h = TunnelTurnSlide.viewH
        var px = [UInt32](repeating: 0, count: w * h)
        let x0 = (0x71 - Chipset.canvasH0 + column * 8) * 2, y0 = 0x3c - Chipset.canvasV0
        for y in 0..<h {
            let row = (y0 + y) * Chipset.canvasWidth + x0
            for x in 0..<w { px[y * w + x] = chip.canvas[row + 2 * x] }
        }
        return px
    }

    private func cancel() { old = nil; new = nil; step = 0; waitFrames = 0; isVisible = false }

    /// Every displayed frame (AppServices.onDisplay).
    func displayed(_ ctx: FrameContext) {
        guard Prefs.bool(TunnelTurnSlide.kEnabled), ctx.game.area == .tunnels, ctx.game.screen == .playing,
              let t = ctx.game.tunnels, !t.inRoom else {
            cancel(); lastHeading = nil; lastPos = nil; current = nil; return
        }
        let col = Int(ctx.memory.r32(0x3b3f8) & 0xff)
        if col != column { column = col; manager?.setNeedsLayout(); current = nil }
        let chip = ctx.machine.chip
        defer { lastHeading = t.heading; lastPos = (t.x, t.y) }
        if let h = lastHeading, let p = lastPos, h != t.heading, p == (t.x, t.y), let cur = current {
            let d = (t.heading - h + 4) & 3
            if d == 1 || d == 3 {
                if animating, let n = new { old = n } else { old = cur }
                new = nil; dir = d == 1 ? 1 : -1; waitFrames = 0; step = 0
                show(old!)
                return
            }
        }
        guard animating else { current = grab(chip); return }
        if new == nil {
            let g = grab(chip)
            waitFrames += 1
            if g != old! || waitFrames >= TunnelTurnSlide.maxWait { new = g } else { return }
        }
        step += 1
        if step >= TunnelTurnSlide.slideFrames { current = grab(chip); cancel(); return }
        compose(Double(step) / Double(TunnelTurnSlide.slideFrames))
    }

    /// Old view shifted out by `f` of the width, new view entering from the turn side.
    private func compose(_ f: Double) {
        guard let o = old, let n = new else { return }
        let w = TunnelTurnSlide.viewW, h = TunnelTurnSlide.viewH
        let s = Int((Double(w) * (1 - cos(f * .pi)) / 2).rounded())
        var px = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                // dir +1: the picture moves left; source x in the concatenation [old | new]
                let sx = dir > 0 ? x + s : x - s
                px[y * w + x] = sx >= 0 && sx < w ? o[y * w + sx] : sx >= w ? n[y * w + sx - w] : n[y * w + sx + w]
            }
        }
        show(px)
    }

    private func show(_ px: [UInt32]) {
        let w = TunnelTurnSlide.viewW, h = TunnelTurnSlide.viewH
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let prov = CGDataProvider(data: data),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = cg
        CATransaction.commit()
        if !isVisible { isVisible = true }
    }

    override func hostDidReset() { cancel(); lastHeading = nil; lastPos = nil; current = nil }
}
