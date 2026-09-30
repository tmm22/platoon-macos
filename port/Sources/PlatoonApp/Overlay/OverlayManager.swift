import AppKit
import SwiftUI

// F3 assist overlay layer: an AppKit view stacked above the MTKView. It is never drawn into the Amiga canvas,
// the ⌘S screenshot (ImageIO.canvasPNG) or the renderer's drawable, so the game's picture stays exactly the
// original. Feature owners add panels (maps, subtitles, timers, objectives, prompts) with
//
//     AppServices.shared.overlay.add(panel)
//
// where `panel` is an OverlayPanel subclass (or one of the ready-made ones below: TextOverlayPanel,
// HostingOverlayPanel for SwiftUI). Panels are laid out from an anchor relative to the GAME IMAGE rect (which
// moves with window size, aspect correction, integer scaling and overscan) or to the window, and get
// `update(_:)` once per displayed frame with a FrameContext (game thread parked: RAM reads are safe).
//
// Coordinates: the overlay view is flipped (origin top-left, points). `OverlayLayout.point(x:y:)` converts
// visible-screen lowres coordinates (0..319 x 0..255 = DIW h $71.., line $2c..) to overlay points.

enum OverlayEdge { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight }

enum OverlayAnchor {
    /// Positioned at an edge/corner of the game image, `inset` points inside it.
    case game(OverlayEdge, inset: CGFloat = 8)
    /// Positioned at an edge/corner of the window content.
    case window(OverlayEdge, inset: CGFloat = 8)
    /// Placed OUTSIDE the game image in the letterbox bars (left/right/top/bottom), centred on that side.
    case outsideGame(OverlayEdge, gap: CGFloat = 8)
    case fillGame
    case fillWindow
    case custom((OverlayLayout, CGSize) -> CGRect)
}

/// Geometry handed to panels.
struct OverlayLayout {
    /// Overlay bounds (window content, points, flipped).
    var bounds: CGRect
    /// The game image rect in overlay points.
    var gameRect: CGRect
    /// Crop of the canvas that is visible, in canvas coordinates (hires x, canvas lines) — see MetalRenderer.crop.
    var crop: (x: Int, y: Int, w: Int, h: Int)
    /// Points per lowres pixel (horizontal) and per line (vertical).
    var scaleX: CGFloat { gameRect.width / CGFloat(crop.w / 2) }
    var scaleY: CGFloat { gameRect.height / CGFloat(crop.h) }

    /// Visible-screen lowres coordinates (x 0..319 from DIW h $71, y 0..255 from line $2c) -> overlay point.
    func point(x: Double, y: Double) -> CGPoint {
        let cx = x + Double(0x71 - 0x60) - Double(crop.x) / 2      // canvas lowres x relative to the crop
        let cy = y + Double(0x2c - 0x18) - Double(crop.y)
        return CGPoint(x: gameRect.minX + CGFloat(cx) * scaleX, y: gameRect.minY + CGFloat(cy) * scaleY)
    }
    /// Amiga beam coordinates (DIW horizontal lowres position, beam line) -> overlay point.
    func point(hpos: Double, vline: Double) -> CGPoint { point(x: hpos - 0x71, y: vline - 0x2c) }
}

/// Base class of every overlay panel. Subclass it or use a ready-made subclass.
class OverlayPanel: NSObject {
    let id: String
    let view: NSView
    var anchor: OverlayAnchor { didSet { manager?.setNeedsLayout() } }
    /// Stacking order (higher is in front). Suggested: HUD-like info 0-99, captions 100, toasts 500, menus 1000.
    var zIndex: Int
    /// Receives mouse clicks (otherwise clicks pass through to the game view).
    var isInteractive = false
    /// While visible, receives ALL keyboard and controller-button input (e.g. the pause menu) — the game
    /// gets none of it.
    var isModal = false
    /// Keeps clear of other information panels (integration: maps, timer, HUD, captions, badges from different
    /// features share the side bars and corners). Panels are placed in zIndex order; a panel whose frame would
    /// overlap an already placed one is moved below it (or above it when there is no room below). Modal panels
    /// and panels filling the game image / window never take part.
    var avoidsOverlap = true
    /// Fixed size in points; nil = the view's fittingSize.
    var preferredSize: CGSize? { didSet { manager?.setNeedsLayout() } }
    fileprivate(set) weak var manager: OverlayManager?

    init(id: String, view: NSView, anchor: OverlayAnchor, zIndex: Int = 0) {
        self.id = id; self.view = view; self.anchor = anchor; self.zIndex = zIndex
        super.init()
    }

    var isVisible: Bool {
        get { !view.isHidden }
        set { if view.isHidden == newValue { view.isHidden = !newValue; manager?.panelVisibilityChanged(self) } }
    }

    /// Frame for the panel in overlay points; override for custom layout.
    func frame(in l: OverlayLayout) -> CGRect {
        let size = preferredSize ?? view.fittingSize
        func place(_ r: CGRect, _ e: OverlayEdge, _ inset: CGFloat) -> CGRect {
            let x: CGFloat, y: CGFloat
            switch e {
            case .topLeft, .left, .bottomLeft: x = r.minX + inset
            case .top, .center, .bottom: x = r.midX - size.width / 2
            case .topRight, .right, .bottomRight: x = r.maxX - inset - size.width
            }
            switch e {
            case .topLeft, .top, .topRight: y = r.minY + inset
            case .left, .center, .right: y = r.midY - size.height / 2
            case .bottomLeft, .bottom, .bottomRight: y = r.maxY - inset - size.height
            }
            return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
        switch anchor {
        case .game(let e, let i): return place(l.gameRect, e, i)
        case .window(let e, let i): return place(l.bounds, e, i)
        case .fillGame: return l.gameRect
        case .fillWindow: return l.bounds
        case .custom(let f): return f(l, size)
        case .outsideGame(let e, let gap):
            let g = l.gameRect
            switch e {
            case .left, .topLeft, .bottomLeft: return CGRect(x: g.minX - gap - size.width, y: g.midY - size.height / 2, width: size.width, height: size.height)
            case .right, .topRight, .bottomRight: return CGRect(x: g.maxX + gap, y: g.midY - size.height / 2, width: size.width, height: size.height)
            case .top: return CGRect(x: g.midX - size.width / 2, y: g.minY - gap - size.height, width: size.width, height: size.height)
            default: return CGRect(x: g.midX - size.width / 2, y: g.maxY + gap, width: size.width, height: size.height)
            }
        }
    }

    /// Once per displayed frame (also while paused). `ctx` is nil before a game is running.
    func update(_ ctx: FrameContext?) {}
    /// The game was reset (new Machine): drop per-run state.
    func hostDidReset() {}
    /// Keyboard (Mac virtual keycode) — only called for modal panels. Return true if consumed.
    func handleKey(_ code: UInt16, down: Bool, event: NSEvent?) -> Bool { false }
    /// Controller button — only called for modal panels. Return true if consumed.
    func handlePad(_ b: PadButton, down: Bool) -> Bool { false }
}

/// Flipped, transparent container; lets clicks through except on interactive panels.
final class OverlayView: NSView {
    weak var manager: OverlayManager?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let m = manager else { return nil }
        let local = convert(p, from: superview)
        for panel in m.panels.reversed() where panel.isVisible && panel.isInteractive && panel.view.frame.contains(local) {
            return panel.view.hitTest(convert(local, to: panel.view.superview)) ?? panel.view
        }
        return nil
    }
    override func layout() { super.layout(); manager?.layoutPanels() }
}

final class OverlayManager {
    let view = OverlayView(frame: .zero)
    private(set) var panels: [OverlayPanel] = []
    /// Updated by the app from the renderer each frame.
    private(set) var layoutInfo = OverlayLayout(bounds: .zero, gameRect: .zero, crop: (x: 34, y: 20, w: 640, h: 256))
    private let toasts = ToastStack()

    init() {
        view.manager = self
        add(toasts.panel)
    }

    func add(_ p: OverlayPanel) {
        remove(id: p.id)
        p.manager = self
        panels.append(p)
        panels.sort { $0.zIndex < $1.zIndex }
        view.subviews = panels.map(\.view)
        setNeedsLayout()
    }
    func remove(id: String) {
        guard let i = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[i].view.removeFromSuperview(); panels[i].manager = nil; panels.remove(at: i)
    }
    func panel(id: String) -> OverlayPanel? { panels.first { $0.id == id } }
    /// Debug: every panel with z, visibility and frame (visible ones), game rect first.
    var debugPanels: String {
        func r(_ f: CGRect) -> String { "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }
        return "game=\(r(layoutInfo.gameRect)) bounds=\(r(layoutInfo.bounds)) | " + panels.map { p in
            "\(p.id)[z\(p.zIndex)\(p.isModal ? ",modal" : "")]" + (p.isVisible ? "=" + r(p.view.frame) : "(hidden)")
        }.joined(separator: " ")
    }

    /// Topmost visible modal panel (receives all input).
    var modalPanel: OverlayPanel? { panels.last { $0.isModal && $0.isVisible } }

    private var layoutDirty = true
    /// Panels call this when their size/content changed; layout happens once at the next displayed frame.
    func setNeedsLayout() { layoutDirty = true }
    func panelVisibilityChanged(_ p: OverlayPanel) { setNeedsLayout() }

    /// Called by the app every displayed frame with the renderer's current geometry.
    func setGeometry(gameRect: CGRect, crop: (x: Int, y: Int, w: Int, h: Int)) {
        let b = view.bounds
        if b != layoutInfo.bounds || gameRect != layoutInfo.gameRect || crop != layoutInfo.crop {
            layoutInfo = OverlayLayout(bounds: b, gameRect: gameRect, crop: crop)
            layoutPanels()
        }
    }
    func layoutPanels() {
        layoutDirty = false
        layoutInfo.bounds = view.bounds
        var placed: [CGRect] = []
        for p in panels where p.isVisible {
            var f = p.frame(in: layoutInfo)
            if participatesInStacking(p) {
                f = OverlayManager.clear(of: placed, f, bounds: layoutInfo.bounds)
                placed.append(f)
            }
            p.view.frame = f
        }
    }

    private func participatesInStacking(_ p: OverlayPanel) -> Bool {
        guard p.avoidsOverlap, !p.isModal else { return false }
        switch p.anchor {
        case .fillGame, .fillWindow: return false
        default: return true
        }
    }

    /// Moves `f` vertically until it no longer overlaps any of `placed` (below first, then above), staying inside
    /// `bounds`; returns `f` unchanged if no free spot is found.
    static func clear(of placed: [CGRect], _ f: CGRect, bounds: CGRect, gap: CGFloat = 6) -> CGRect {
        func hit(_ r: CGRect) -> CGRect? { placed.first { $0.insetBy(dx: 1, dy: 1).intersects(r) } }
        guard hit(f) != nil else { return f }
        // candidate positions: just below / above each placed frame that shares the column
        var ys: [CGFloat] = []
        for q in placed where q.minX < f.maxX && q.maxX > f.minX {
            ys.append(q.maxY + gap); ys.append(q.minY - gap - f.height)
        }
        let cands = ys.filter { $0 >= bounds.minY && $0 + f.height <= bounds.maxY }
            .sorted { abs($0 - f.minY) < abs($1 - f.minY) }
        for y in cands {
            let r = CGRect(x: f.minX, y: y.rounded(), width: f.width, height: f.height)
            if hit(r) == nil { return r }
        }
        return f
    }
    func update(_ ctx: FrameContext?) {
        for p in panels where p.isVisible { p.update(ctx) }
        toasts.tick()
        if layoutDirty || view.bounds != layoutInfo.bounds { layoutPanels() }
    }
    func hostDidReset() { panels.forEach { $0.hostDidReset() } }

    func handleKey(_ code: UInt16, down: Bool, event: NSEvent?) -> Bool {
        guard let m = modalPanel else { return false }
        _ = m.handleKey(code, down: down, event: event)
        return true
    }
    func handlePad(_ b: PadButton, down: Bool) -> Bool {
        guard let m = modalPanel else { return false }
        _ = m.handlePad(b, down: down)
        return true
    }

    func toast(_ text: String, seconds: Double) { toasts.show(text, seconds: seconds); setNeedsLayout() }

    /// Renders the overlay (without the game) into an image of the overlay's size in pixels (for tests / debug
    /// captures; the game's own screenshots never contain it).
    func snapshot() -> NSBitmapImageRep? {
        layoutPanels()
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

// MARK: - ready-made panels

/// Visual style shared by the built-in panels.
enum OverlayStyle {
    static let background = NSColor(calibratedWhite: 0.05, alpha: 0.82)
    static let border = NSColor(calibratedWhite: 1, alpha: 0.18)
    static let text = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.45, alpha: 1)
    static let dim = NSColor(calibratedWhite: 0.7, alpha: 1)
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

    /// A rounded translucent box view.
    static func box() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = background.cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderColor = border.cgColor
        v.layer?.borderWidth = 1
        return v
    }
}

/// A text box (captions, prompts, timers). `text = nil` hides it. Optional auto-hide after `show(_:seconds:)`.
final class TextOverlayPanel: OverlayPanel {
    let label = NSTextField(labelWithString: "")
    private var hideAt: CFTimeInterval = 0
    var padding = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12) { didSet { manager?.setNeedsLayout() } }
    /// Maximum width in points (text wraps); nil = single line.
    var maxWidth: CGFloat? = nil

    init(id: String, anchor: OverlayAnchor, zIndex: Int = 100, fontSize: CGFloat = 15) {
        let box = OverlayStyle.box()
        super.init(id: id, view: box, anchor: anchor, zIndex: zIndex)
        label.font = OverlayStyle.font(fontSize)
        label.textColor = OverlayStyle.text
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        box.addSubview(label)
        box.isHidden = true
    }

    var text: String? {
        get { view.isHidden ? nil : label.stringValue }
        set {
            if let t = newValue { label.stringValue = t; isVisible = true } else { isVisible = false }
            manager?.setNeedsLayout()
        }
    }
    var attributedText: NSAttributedString? {
        didSet { if let a = attributedText { label.attributedStringValue = a; isVisible = true } else { isVisible = false } }
    }
    var fontSize: CGFloat { get { label.font?.pointSize ?? 15 } set { label.font = OverlayStyle.font(newValue); manager?.setNeedsLayout() } }

    func show(_ t: String, seconds: Double) { text = t; hideAt = CACurrentMediaTime() + seconds }

    override func frame(in l: OverlayLayout) -> CGRect {
        let mw = maxWidth.map { min($0, l.bounds.width - 16) } ?? 10000
        label.preferredMaxLayoutWidth = mw - padding.left - padding.right
        let ts = label.sizeThatFits(NSSize(width: mw - padding.left - padding.right, height: 10000))
        preferredSize = CGSize(width: ceil(ts.width) + padding.left + padding.right, height: ceil(ts.height) + padding.top + padding.bottom)
        let f = super.frame(in: l)
        label.frame = CGRect(x: padding.left, y: padding.bottom, width: f.width - padding.left - padding.right, height: f.height - padding.top - padding.bottom)
        return f
    }

    override func update(_ ctx: FrameContext?) {
        if hideAt > 0 && CACurrentMediaTime() >= hideAt { hideAt = 0; text = nil }
    }
}

/// Hosts a SwiftUI view as a panel.
final class HostingOverlayPanel<Content: View>: OverlayPanel {
    let hosting: NSHostingView<Content>
    init(id: String, anchor: OverlayAnchor, zIndex: Int = 0, interactive: Bool = false, @ViewBuilder content: () -> Content) {
        hosting = NSHostingView(rootView: content())
        super.init(id: id, view: hosting, anchor: anchor, zIndex: zIndex)
        isInteractive = interactive
    }
    var rootView: Content { get { hosting.rootView } set { hosting.rootView = newValue; manager?.setNeedsLayout() } }
}

/// Transient messages stacked at the top centre of the window ("Paused — window inactive", "Saved to slot 1").
private final class ToastStack {
    let stack = NSStackView()
    lazy var panel: OverlayPanel = {
        stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .centerX
        let p = OverlayPanel(id: "app.toasts", view: stack, anchor: .window(.top, inset: 14), zIndex: 500)
        p.avoidsOverlap = false          // transient; may cover anything for a moment
        return p
    }()
    private var items: [(view: NSView, until: CFTimeInterval)] = []

    func show(_ text: String, seconds: Double) {
        // same text again: extend instead of stacking duplicates
        if let i = items.firstIndex(where: { (($0.view.subviews.first as? NSTextField)?.stringValue) == text }) {
            items[i].until = CACurrentMediaTime() + seconds; return
        }
        let box = OverlayStyle.box()
        let l = NSTextField(labelWithString: text)
        l.font = OverlayStyle.font(13); l.textColor = OverlayStyle.text
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        stack.addArrangedSubview(box)
        items.append((box, CACurrentMediaTime() + seconds))
        if items.count > 4 { items.removeFirst().view.removeFromSuperview() }
        panel.isVisible = true
    }
    func tick() {
        let now = CACurrentMediaTime()
        var changed = false
        items.removeAll { if $0.until <= now { $0.view.removeFromSuperview(); changed = true; return true }; return false }
        if changed || items.isEmpty { panel.isVisible = !items.isEmpty }
    }
}
