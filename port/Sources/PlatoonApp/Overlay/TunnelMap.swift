import AppKit
import PlatoonCore

// M3 tunnel automap with fog of war (owner: section1). Host-only and read-only: it samples the player position
// ($1a0b0/$1a0b1) and heading ($2a(a6)) from the F1 context every emulated frame, marks the maze cells the player
// could see (TunnelMaze.visibleCells, the view's own scan) and draws them in an overlay panel beside the game.
// Rooms are numbered when visited, with the items found there; "reveal all" (a spoiler) shows the whole maze and
// every room's contents and marks the run as assisted. Exploration knowledge belongs to the player: it survives a
// soldier's death and savestate loads/rewinds, and is cleared when section 1 starts (new game / continue).
//
// Prefs (Prefs/PrefsGameplaySection1.swift): section1.tunnelMap, .tunnelMapReveal, .tunnelMapItems,
// .tunnelMapSize, .tunnelMapPlace. Key M (tunnels only) shows/hides the panel while the option is on.

final class TunnelMapModel {
    static let n = TunnelMaze.size
    /// Cell values (maze) copied when section 1 is in memory.
    private(set) var maze = [UInt8](repeating: 0, count: n * n)
    private(set) var seen = [Bool](repeating: false, count: n * n)
    private(set) var visitedRooms = Set<Int>()
    private(set) var rooms: [TunnelMaze.Room] = []
    private(set) var player: (x: Int, y: Int, heading: Int)?
    private(set) var inRoom: Int?
    private(set) var generation = 0

    func reset() {
        seen = [Bool](repeating: false, count: TunnelMapModel.n * TunnelMapModel.n)
        visitedRooms = []; player = nil; inRoom = nil; generation += 1
    }

    /// Called every emulated frame while the tunnels run (game parked: RAM reads are safe).
    func sample(_ mem: Memory, _ t: GameContext.Tunnels) {
        var changed = false
        let n = TunnelMapModel.n
        if maze.allSatisfy({ $0 == 0 }) || player == nil {
            for i in 0..<(n * n) { maze[i] = mem.r8(TunnelMaze.mazeAddr + UInt32(i)) }
            changed = true
        }
        let p = (t.x, t.y, t.heading)
        if player == nil || player! != p {
            player = p; changed = true
            let cells = TunnelMaze.visibleCells(x: t.x, y: t.y, heading: t.heading) { [maze] cx, cy in
                guard cx >= 0, cy >= 0, cx < n, cy < n else { return 0 }
                return maze[cy * n + cx]
            }
            for c in cells where !seen[c] { seen[c] = true }
        }
        if t.inRoom != (inRoom != nil) || t.room != inRoom {
            inRoom = t.inRoom ? t.room : nil
            if let r = inRoom { visitedRooms.insert(r) }
            changed = true
        }
        let r = TunnelMaze.rooms(mem)
        if r != rooms { rooms = r; changed = true }
        if changed { generation += 1 }
    }
}

final class TunnelMapView: NSView {
    let model: TunnelMapModel
    var reveal = false
    var showItems = true
    var cell: CGFloat = 5
    private let legend = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    init(model: TunnelMapModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = OverlayStyle.background.cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = OverlayStyle.border.cgColor
        layer?.borderWidth = 1
        legend.font = OverlayStyle.font(10, .regular)
        legend.textColor = OverlayStyle.text
        legend.maximumNumberOfLines = 0
        legend.lineBreakMode = .byWordWrapping
        addSubview(legend)
    }
    required init?(coder: NSCoder) { fatalError() }

    static let pad: CGFloat = 8
    var mapSide: CGFloat { CGFloat(TunnelMapModel.n) * cell }

    /// Legend lines: rooms visited (or all with reveal) and what was found / is there.
    func legendText() -> String {
        var lines: [String] = []
        for r in model.rooms {
            let known = reveal || model.visitedRooms.contains(r.index)
            guard known else { continue }
            var parts: [String] = []
            for it in r.items.dropLast() where TunnelMaze.isKeyItem(it.code) || (reveal && it.code == 0x0f) {
                let name = TunnelMaze.itemName(it.code)
                if it.taken { parts.append(name + " ✓") }
                else if reveal || showItems && it.code == 0x15 { parts.append(name) }
            }
            if !showItems && !reveal { parts = [] }
            lines.append("\(r.index)" + (parts.isEmpty ? "" : "  " + parts.joined(separator: ", ")))
        }
        let title = reveal ? "TUNNELS (all)" : "TUNNELS  \(model.visitedRooms.count)/10 rooms"
        return ([title] + lines).joined(separator: "\n")
    }

    func preferredSize() -> CGSize {
        let w = mapSide + 2 * TunnelMapView.pad
        legend.stringValue = legendText()
        legend.preferredMaxLayoutWidth = mapSide
        let ls = legend.sizeThatFits(NSSize(width: mapSide, height: 1000))
        return CGSize(width: w, height: mapSide + 2 * TunnelMapView.pad + 6 + ceil(ls.height))
    }

    override func layout() {
        super.layout()
        let p = TunnelMapView.pad
        legend.frame = CGRect(x: p, y: p + mapSide + 6, width: mapSide, height: bounds.height - mapSide - 2 * p - 6)
    }

    override func draw(_ dirty: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let n = TunnelMapModel.n, c = cell, o = TunnelMapView.pad
        let corridor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
        let wall = NSColor(calibratedRed: 0.22, green: 0.26, blue: 0.24, alpha: 1).cgColor
        let room = NSColor(calibratedRed: 0.85, green: 0.62, blue: 0.25, alpha: 1).cgColor
        let unknown = NSColor(calibratedWhite: 0, alpha: 0.35).cgColor
        g.setFillColor(unknown)
        g.fill(CGRect(x: o, y: o, width: mapSide, height: mapSide))
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                guard reveal || model.seen[i] else { continue }
                let v = model.maze[i]
                g.setFillColor(v == 2 || (0x21...0x24).contains(v) ? corridor : v == 3 ? room : wall)
                g.fill(CGRect(x: o + CGFloat(x) * c, y: o + CGFloat(y) * c, width: c, height: c))
            }
        }
        // start cell
        let start = CGRect(x: o + 21 * c, y: o + 3 * c, width: c, height: c).insetBy(dx: c * 0.25, dy: c * 0.25)
        g.setFillColor(NSColor.systemBlue.cgColor); g.fill(start)
        // room numbers
        let font = NSFont.monospacedSystemFont(ofSize: max(7, c * 1.8), weight: .bold)
        for r in model.rooms where reveal || model.visitedRooms.contains(r.index) {
            let flag = r.items.contains { $0.code == 0x15 } && reveal
            let s = NSAttributedString(string: "\(r.index)", attributes: [
                .font: font, .foregroundColor: flag ? NSColor.systemRed : NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0])
            let sz = s.size()
            s.draw(at: CGPoint(x: o + (CGFloat(r.entryX) + 0.5) * c - sz.width / 2, y: o + (CGFloat(r.entryY) + 0.5) * c - sz.height / 2))
        }
        // player arrow
        if let p = model.player {
            let cx = o + (CGFloat(p.x) + 0.5) * c, cy = o + (CGFloat(p.y) + 0.5) * c
            let s = max(c * 1.1, 4)
            let ang: [CGFloat] = [-.pi / 2, 0, .pi / 2, .pi]
            let a = ang[p.heading & 3]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx + cos(a) * s, y: cy + sin(a) * s))
            path.addLine(to: CGPoint(x: cx + cos(a + 2.5) * s, y: cy + sin(a + 2.5) * s))
            path.addLine(to: CGPoint(x: cx + cos(a - 2.5) * s, y: cy + sin(a - 2.5) * s))
            path.closeSubpath()
            g.addPath(path)
            g.setFillColor(OverlayStyle.accent.cgColor)
            g.setStrokeColor(NSColor.black.cgColor)
            g.setLineWidth(1)
            g.drawPath(using: .fillStroke)
        }
    }
}

final class TunnelMapPanel: OverlayPanel {
    static let shared = TunnelMapPanel()
    let model = TunnelMapModel()
    let mapView: TunnelMapView
    /// Toggled with M while the option is on.
    var userHidden = false
    private var drawnGeneration = -1
    private var drawnKey = ""
    private var markedReveal = false

    static let kEnabled = "section1.tunnelMap"
    static let kReveal = "section1.tunnelMapReveal"
    static let kItems = "section1.tunnelMapItems"
    static let kSize = "section1.tunnelMapSize"
    static let kPlace = "section1.tunnelMapPlace"

    private init() {
        mapView = TunnelMapView(model: model)
        super.init(id: "section1.tunnelMap", view: mapView, anchor: .outsideGame(.right, gap: 10), zIndex: 20)
        isVisible = false
    }

    var enabled: Bool { Prefs.bool(TunnelMapPanel.kEnabled) }

    func applyPlacement(_ l: OverlayLayout? = nil) {
        switch Prefs.int(TunnelMapPanel.kPlace) {
        case 1: anchor = .game(.topRight, inset: 8)
        case 2: anchor = .outsideGame(.left, gap: 10)
        default: anchor = .outsideGame(.right, gap: 10)
        }
    }

    /// Beside the game only when the letterbox bar is wide enough; otherwise inside the top-right corner.
    override func frame(in l: OverlayLayout) -> CGRect {
        var f = super.frame(in: l)
        if f.minX < l.bounds.minX || f.maxX > l.bounds.maxX {
            let size = preferredSize ?? view.fittingSize
            f = CGRect(x: l.gameRect.maxX - 8 - size.width, y: l.gameRect.minY + 8, width: size.width, height: size.height)
        }
        if f.minY < l.bounds.minY { f.origin.y = l.bounds.minY + 4 }
        return f
    }

    /// Every emulated frame (AppServices.onFrame).
    func sample(_ ctx: FrameContext) {
        guard enabled, let t = ctx.game.tunnels, ctx.game.area == .tunnels, ctx.game.section == 1 else { return }
        model.sample(ctx.memory, t)
    }

    override func update(_ ctx: FrameContext?) { refresh(ctx) }

    /// Visibility and redraw (every displayed frame, AppServices.onDisplay; also runs while hidden).
    func refresh(_ ctx: FrameContext?) {
        let show = enabled && !userHidden && ctx?.game.area == .tunnels && ctx?.game.section == 1 && ctx?.game.screen == .playing
        if isVisible != show { isVisible = show }
        guard show else { return }
        let reveal = Prefs.bool(TunnelMapPanel.kReveal)
        if reveal && !markedReveal { markedReveal = true; AppServices.shared.markAssisted("Tunnel map: reveal all") }
        let size = CGFloat(max(3, min(10, Prefs.double(TunnelMapPanel.kSize))))
        let key = "\(reveal) \(Prefs.bool(TunnelMapPanel.kItems)) \(size) \(Prefs.int(TunnelMapPanel.kPlace))"
        guard model.generation != drawnGeneration || key != drawnKey else { return }
        drawnGeneration = model.generation; drawnKey = key
        mapView.reveal = reveal
        mapView.showItems = Prefs.bool(TunnelMapPanel.kItems)
        mapView.cell = size
        applyPlacement()
        preferredSize = mapView.preferredSize()
        mapView.needsLayout = true
        mapView.needsDisplay = true
    }

    /// A new section-1 run: forget what was explored (and the reveal mark, which belongs to the run).
    func sectionStarted() { model.reset(); markedReveal = false; userHidden = false }
}
