import Metal
import PlatoonCore

// OWNER: [presentation]. L4 widescreen compositing API. The section0 agent (or any feature) renders the side
// columns; the renderer only composites them beside the game window.
//
// Usage (main thread, e.g. from an AppServices.onFrame / onDisplay observer):
//
//   let cols = SideColumnCompositor.shared            // (= AppServices.shared.app?.renderer.columns)
//   let room = cols.room(leftEdge: 33, rightEdge: 337)   // lowres px free between the window edges and the drawable
//                                                        // edges in the last displayed layout (0 = no bars)
//   let w = min(256, room.left)                          // your own maximum
//   cols.submit(SideColumnFrame(width: w, rightWidth: min(256, room.right), firstLine: 36, lines: 144,
//                               leftEdge: 33, rightEdge: 337, left: leftPixels, right: rightPixels, fog: 0.35))
//   cols.clear()                     // nothing to show right now (dissolves, other sections): bars stay backdrop/black
//
// Optional: `cols.reservedWidth = 96` makes the layout leave that many lowres px beside the crop on each side even
// in a 4:3 window (the game picture gets smaller). Keep it constant while your option is on; 0 = original layout.
//
// Coordinates are CANVAS coordinates (the same as ImageIO.canvasPNG / platoon-headless screenshots): lowres x
// 0..383 (x = DIW hpos - $60) and canvas lines 0..289 (line = beam line - $18). The visible crop is lowres x
// 17..337, lines 20..275. The left column occupies x ∈ [leftEdge - width, leftEdge), the right one
// [rightEdge, rightEdge + width), both on lines [firstLine, firstLine + lines). A column may overlap the crop's
// black border (the jungle window starts at x 33, 16 px inside the crop) — it is blended over it.
// The HUD rows are not part of the columns (the result is T-shaped).
//
// Pixels: 0xAARRGGBB (like Chipset.canvas), row-major, `width * lines` per side, left-to-right. Alpha is
// honoured (0 = show the backdrop). `fog` fades each column towards its OUTER edge (0 = none, 1 = whole width).
// The columns are drawn with sharp-pixel sampling (not through the CRT / MMPX filters) and are moved with the
// screen shake. Submitting a frame costs one texture upload; submit only when the content changed.

struct SideColumnFrame {
    /// Width of the left column (and of the right one unless `rightWidth` is set), lowres px.
    var width: Int
    var rightWidth: Int? = nil
    var firstLine: Int
    var lines: Int
    var leftEdge: Int
    var rightEdge: Int
    var left: [UInt32]
    var right: [UInt32]
    var fog: Float = 0.3
    var alpha: Float = 1
}

final class SideColumnCompositor {
    static let shared = SideColumnCompositor()
    /// Lowres pixels reserved on each side of the 320-px crop (0 = off: the layout is the original one).
    var reservedWidth = 0 { didSet { if reservedWidth != oldValue { AppServices.shared.overlay.setNeedsLayout() } } }
    /// The frame being shown (nil = nothing).
    private(set) var current: SideColumnFrame?
    private var dirty = false
    private var textures: [MTLTexture] = []

    func submit(_ f: SideColumnFrame) {
        precondition(f.left.count >= f.width * f.lines && f.right.count >= (f.rightWidth ?? f.width) * f.lines, "SideColumnFrame: pixel arrays too small")
        current = f; dirty = true
    }
    func clear() { current = nil }

    /// Geometry of the last displayed frame (set by the renderer).
    struct Geometry { var gameMinX: Double, drawableWidth: Double, scaleX: Double, cropLeftLow: Double }
    var geometry: Geometry?
    /// Free lowres pixels between a window edge (canvas lowres x) and the drawable edge, per side, in the last
    /// displayed layout.
    func room(leftEdge: Int, rightEdge: Int) -> (left: Int, right: Int) {
        guard let g = geometry, g.scaleX > 0 else { return (0, 0) }
        let lx = g.gameMinX + (Double(leftEdge) - g.cropLeftLow) * g.scaleX
        let rx = g.gameMinX + (Double(rightEdge) - g.cropLeftLow) * g.scaleX
        return (max(0, Int((lx / g.scaleX).rounded(.down))), max(0, Int(((g.drawableWidth - rx) / g.scaleX).rounded(.down))))
    }

    /// Metal textures for the current frame (renderer only).
    func texture(device: MTLDevice) -> [MTLTexture]? {
        guard let f = current, f.lines > 0 else { return nil }
        let widths = [max(1, f.width), max(1, f.rightWidth ?? f.width)]     // (a side of width 0 isn't drawn)
        if textures.count != 2 || textures[0].width != widths[0] || textures[1].width != widths[1] || textures[0].height != f.lines {
            var t: [MTLTexture] = []
            for w in widths {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: f.lines, mipmapped: false)
                td.usage = .shaderRead
                guard let x = device.makeTexture(descriptor: td) else { return nil }
                t.append(x)
            }
            textures = t; dirty = true
        }
        if dirty {
            for (i, px) in [f.left, f.right].enumerated() {
                let w = widths[i]
                guard px.count >= w * f.lines else { continue }
                px.withUnsafeBytes { textures[i].replace(region: MTLRegionMake2D(0, 0, w, f.lines), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
            }
            dirty = false
        }
        return textures
    }
}
