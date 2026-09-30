import AppKit
import PlatoonCore

// M5 final-jungle navigator (owner: section2). Host-only and read-only: an overlay panel (F3) fed from RAM in
// onFrame (game thread parked). Levels (pref "section2.navigator", Assist tab / Assist menu):
//   1 Heading      - the heading (N/E/S/W) and which side exits the room has, even without the compass
//   2 + map        - breadcrumb map of the 10x12 room grid: rooms visited this game, where you are, facing where
//   3 + guide      - "take the LEFT exit" towards the nearest bunker (BFS over (room, heading), exact
//                    trans_left/trans_right rules, validated against re/finaljungle/assets/maze_graph.json), the
//                    number of rooms left, "walk to the far end first", Barnes' remaining hits in the bunker.
//                    Level 3 marks the run as assisted (F4/S5); levels 1-2 only show what the player has seen.
// Model: PlatoonCore FinalJungleMaze / FinalJungleLive (Game/Section2/FinalNavigator.swift).

/// Per-run navigator state (host side), updated every emulated frame.
final class FinalNavigatorModel {
    static let shared = FinalNavigatorModel()

    enum Level: Int { case off = 0, heading = 1, map = 2, guide = 3 }
    var level: Level { Level(rawValue: Prefs.int("section2.navigator")) ?? .off }

    /// Section 2 main loop is running (incl. room transitions).
    private(set) var active = false
    private(set) var live: FinalJungleLive?
    private(set) var maze: FinalJungleMaze?
    /// Rooms entered this game (in order) and the bunker rooms seen.
    private(set) var visited: [Int] = []
    private(set) var visitedSet = Set<Int>()
    /// Shortest route from the current state (nil = none / unknown).
    private(set) var route: [FinalJungleMaze.Exit]?
    /// Bumped whenever something the panel shows changed.
    private(set) var version = 0
    private var lastRoom: Int?
    private var lastDirs: UInt32 = 0
    private var lastDepthZone = false
    private var lastBarnes = -1
    private var markedGuide = false

    func reset() {
        active = false; live = nil; maze = nil; visited = []; visitedSet = []; route = nil; lastRoom = nil
        markedGuide = false; version += 1
    }

    /// Called in onFrame (every emulated frame).
    func frame(_ ctx: FrameContext) {
        let g = ctx.game
        let inS2 = g.inGame && g.loadedSection == 2 && g.section == 2 && g.screen == .playing
        if !g.inGame && (!visited.isEmpty || active) { reset(); return }   // title / game over: forget the run
        if inS2 != active { active = inS2; version += 1 }
        guard inS2 else { return }
        let l = FinalJungleLive.read(ctx.memory)
        live = l
        if l.room != lastRoom || l.dirs != lastDirs {
            lastRoom = l.room; lastDirs = l.dirs
            let mz = FinalJungleMaze(memory: ctx.memory)
            maze = mz
            if !visitedSet.contains(l.room) { visitedSet.insert(l.room); visited.append(l.room) }
            route = mz.route(from: l.state)
            version += 1
        }
        let zone = l.atFarEnd
        if zone != lastDepthZone || l.barnesHP != lastBarnes { lastDepthZone = zone; lastBarnes = l.barnesHP; version += 1 }
        if level == .guide && !markedGuide {
            markedGuide = true
            AppServices.shared.markAssisted("Final-jungle route guide")
        }
        if level != .guide { markedGuide = false }
    }
}

/// The navigator overlay panel.
final class FinalNavigatorPanel: OverlayPanel {
    private let nav = NavView()
    private var shownVersion = -1
    private var shownLevel = -1

    init() {
        super.init(id: "section2.navigator", view: nav, anchor: .game(.topRight, inset: 6), zIndex: 20)
        anchor = .custom { [weak self] l, size in self?.place(l, size) ?? .zero }
        view.isHidden = true
    }

    private func place(_ l: OverlayLayout, _ size: CGSize) -> CGRect {
        let g = l.gameRect
        let inside = Prefs.int("section2.navigatorPlace") == 1
        if !inside && l.bounds.maxX - g.maxX >= size.width + 16 {
            return CGRect(x: (g.maxX + 10).rounded(), y: (g.minY + 10).rounded(), width: size.width, height: size.height)
        }
        if !inside && g.minX - l.bounds.minX >= size.width + 16 {
            return CGRect(x: (g.minX - 10 - size.width).rounded(), y: (g.minY + 10).rounded(), width: size.width, height: size.height)
        }
        // inside the picture, top-right corner of the playfield (scaled down on small windows)
        return CGRect(x: (g.maxX - 6 - size.width).rounded(), y: (g.minY + 6).rounded(), width: size.width, height: size.height)
    }

    override func update(_ ctx: FrameContext?) {
        let m = FinalNavigatorModel.shared
        let lvl = m.level
        let show = ctx != nil && m.active && lvl != .off && m.live != nil
        if !show { if isVisible { isVisible = false }; return }
        if m.version != shownVersion || lvl.rawValue != shownLevel {
            shownVersion = m.version; shownLevel = lvl.rawValue
            nav.content = NavView.Content(level: lvl, live: m.live!, maze: m.maze, visited: m.visitedSet, trail: m.visited, route: m.route)
            let s = nav.contentSize
            if preferredSize != s { preferredSize = s }
            nav.needsDisplay = true
        }
        if !isVisible { isVisible = true }
    }

    override func hostDidReset() { FinalNavigatorModel.shared.reset(); isVisible = false }

    /// Custom-drawn panel content.
    final class NavView: NSView {
        struct Content {
            var level: FinalNavigatorModel.Level
            var live: FinalJungleLive
            var maze: FinalJungleMaze?
            var visited: Set<Int>
            var trail: [Int]
            var route: [FinalJungleMaze.Exit]?
        }
        var content: Content?
        override var isFlipped: Bool { true }
        static let cell: CGFloat = 12, pad: CGFloat = 10, width: CGFloat = 10 * cell + 2 * pad + 20

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = OverlayStyle.background.cgColor
            layer?.cornerRadius = 8
            layer?.borderColor = OverlayStyle.border.cgColor
            layer?.borderWidth = 1
        }
        required init?(coder: NSCoder) { fatalError() }

        private var lines: [(String, NSColor, CGFloat)] {
            guard let c = content else { return [] }
            var out: [(String, NSColor, CGFloat)] = []
            let h = c.live.heading
            let arrow = ["\u{2191}", "\u{2192}", "\u{2193}", "\u{2190}"][h?.rawValue ?? 0]
            out.append(("\(arrow)  Heading \(h?.name.uppercased() ?? "?")", OverlayStyle.text, 14))
            let e = c.live.exits
            let exits = e == 0 ? "Bunker room" : e == 1 ? "Exit: \u{25C0} left" : e == 2 ? "Exit: right \u{25B6}" : "Exits: \u{25C0} left \u{00B7} right \u{25B6}"
            out.append((exits, OverlayStyle.dim, 12))
            if c.level == .guide {
                if e == 0 {
                    let hits = (c.live.barnesHP + 9) / 10
                    if c.live.barnesHP > 0 {
                        out.append(("Barnes: \(hits) grenade hit\(hits == 1 ? "" : "s") left", OverlayStyle.accent, 12))
                        out.append(("Throw from near the entry", OverlayStyle.dim, 11))
                    } else {
                        out.append(("Barnes is down:", OverlayStyle.accent, 12))
                        out.append(("walk into the bunker door", OverlayStyle.accent, 12))
                    }
                } else if let r = c.route, let first = r.first {
                    let side = first == .left ? "\u{25C0} LEFT" : "RIGHT \u{25B6}"
                    out.append(("Go \(side)", OverlayStyle.accent, 14))
                    out.append(("\(r.count) room\(r.count == 1 ? "" : "s") to the bunker", OverlayStyle.dim, 11))
                    if !c.live.atFarEnd { out.append(("Walk up to the far end first", OverlayStyle.dim, 11)) }
                } else {
                    out.append(("No route known", OverlayStyle.dim, 11))
                }
            }
            return out
        }

        var contentSize: CGSize {
            let textH = lines.reduce(CGFloat(0)) { $0 + $1.2 + 5 }
            let mapH: CGFloat = (content?.level.rawValue ?? 0) >= 2 ? 12 * NavView.cell + 8 : 0
            return CGSize(width: NavView.width, height: (NavView.pad * 2 + textH + mapH).rounded(.up))
        }

        override func draw(_ dirty: NSRect) {
            guard let c = content else { return }
            var y = NavView.pad
            for (t, col, size) in lines {
                let a: [NSAttributedString.Key: Any] = [.font: OverlayStyle.font(size, size >= 14 ? .bold : .semibold), .foregroundColor: col]
                (t as NSString).draw(at: CGPoint(x: NavView.pad, y: y), withAttributes: a)
                y += size + 5
            }
            guard c.level.rawValue >= 2 else { return }
            y += 4
            let cs = NavView.cell
            let x0 = ((bounds.width - 10 * cs) / 2).rounded()
            for row in 0..<12 {
                for col in 0..<10 {
                    let room = row * 10 + col
                    let r = CGRect(x: x0 + CGFloat(col) * cs, y: y + CGFloat(row) * cs, width: cs - 1, height: cs - 1)
                    if c.visited.contains(room) {          // only rooms you have been in (no spoiler of the layout)
                        let bunker = c.maze?.isBunker(room) ?? false
                        (bunker ? NSColor(calibratedRed: 0.75, green: 0.3, blue: 0.2, alpha: 1)
                                : NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.2, alpha: 1)).setFill()
                    } else {
                        NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
                    }
                    r.fill()
                    if room == FinalJungleMaze.startRoom {
                        NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
                        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
                    }
                }
            }
            // current room + heading arrow
            let room = c.live.room, row = room / 10, col = room % 10
            guard row < 12 else { return }
            let r = CGRect(x: x0 + CGFloat(col) * cs, y: y + CGFloat(row) * cs, width: cs - 1, height: cs - 1)
            OverlayStyle.accent.setFill(); r.fill()
            let h = c.live.heading ?? .north
            let (dx, dy) = h.delta
            let cx = r.midX, cy = r.midY, k = cs * 0.38
            let tip = CGPoint(x: cx + CGFloat(dx) * k, y: cy + CGFloat(dy) * k)
            let l = CGPoint(x: cx - CGFloat(dx) * k * 0.6 - CGFloat(dy) * k * 0.7, y: cy - CGFloat(dy) * k * 0.6 + CGFloat(dx) * k * 0.7)
            let rr = CGPoint(x: cx - CGFloat(dx) * k * 0.6 + CGFloat(dy) * k * 0.7, y: cy - CGFloat(dy) * k * 0.6 - CGFloat(dx) * k * 0.7)
            let p = NSBezierPath(); p.move(to: tip); p.line(to: l); p.line(to: rr); p.close()
            NSColor.black.setFill(); p.fill()
        }
    }
}
