import AppKit
import PlatoonCore

// M6 jungle & village mini-map (owner: section0). Host-only and read-only: the schematic comes from RAM
// (PlatoonCore JungleMapModel: map strips, trees at the player's height, paths, river/bridge, hut doors and search
// spots) and the player marker from $60c2a/$60c30 every emulated frame. Drawn in an overlay panel beside (or on) the
// game; never in the Amiga canvas or screenshots.
//
// Spoiler tiers (pref section0.mapSpoilers): 0 layout only; 1 + objectives (explosives on level 4, the bridge and
// the doom column, the village access); 2 + hut contents (torch, map + guard, booby traps - "sprung" once fired,
// trap door). Tier 2 marks the run assisted. Optional fog of war: only columns the player has seen are drawn
// (remembered across deaths and loads; cleared when section 0 starts).
//
// Prefs (Prefs/PrefsGameplaySection0.swift): section0.map, .mapSpoilers, .mapFog, .mapSize, .mapPlace. Key M
// (jungle & village only) shows/hides the panel while the option is on; also in the pause menu.

final class JungleMapState {
    private(set) var model: JungleMapModel?
    private(set) var signature: UInt64 = 0
    private(set) var player: JunglePlayer?
    /// Columns seen per level (fog of war).
    private(set) var seen = [[Bool]](repeating: [Bool](repeating: false, count: JungleMapModel.columns), count: 5)
    /// Search-table entries that were live booby traps when section 0 started (to show them as "sprung").
    private(set) var trapEntries = Set<Int>()
    private(set) var generation = 0

    func reset() {
        model = nil; signature = 0; player = nil; trapEntries = []
        seen = [[Bool]](repeating: [Bool](repeating: false, count: JungleMapModel.columns), count: 5)
        generation += 1
    }

    /// Every emulated frame while section 0 runs (game parked).
    func sample(_ mem: Memory) {
        let sig = JungleMapModel.signature(mem)
        if model == nil || sig != signature {
            let m = JungleMapModel.build(mem)
            if model == nil { trapEntries = Set(m.spots.filter { $0.kind == .boobyTrap }.map(\.entry)) }
            model = m; signature = sig; generation += 1
        }
        let p = JunglePlayer.read(mem)
        if p != player {
            player = p; generation += 1
            if (0...4).contains(p.level) {
                for c in max(0, p.column - 2)...min(JungleMapModel.columns - 1, p.column + 3) { seen[p.level][c] = true }
            } else if p.level == 5 {
                for c in max(0, p.column - 2)...min(JungleMapModel.columns - 1, p.column + 3) { seen[0][c] = true }
            }
        }
    }
}

final class JungleMapView: NSView {
    let state: JungleMapState
    var tier = 0
    var fog = false
    var colW: CGFloat = 4
    override var isFlipped: Bool { true }
    private let legend = NSTextField(labelWithString: "")

    init(state: JungleMapState) {
        self.state = state
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
    var stripH: CGFloat { max(6, colW * 2.2) }
    var gapH: CGFloat { max(6, colW * 2) }
    var titleH: CGFloat { 14 }
    var hutRowH: CGFloat { tier >= 2 ? max(10, colW * 3) : max(6, colW * 1.6) }
    var mapW: CGFloat { CGFloat(JungleMapModel.columns) * colW }
    /// Top of strip `l` (0..4) in view coordinates.
    func stripY(_ l: Int) -> CGFloat { JungleMapView.pad + titleH + hutRowH + CGFloat(l) * (stripH + gapH) }
    var mapH: CGFloat { stripY(4) + stripH - JungleMapView.pad }

    static let hutNames = ["0", "1", "2", "3", "4", "5"]

    func legendText() -> String {
        guard let m = state.model, tier >= 2 else {
            return tier >= 1 ? "E explosives · B bridge · ✕ no way back without them" : ""
        }
        var lines: [String] = []
        for h in 0..<6 {
            var parts: [String] = []
            if h == 1 { parts.append("trap door") }
            if h == 2 { parts.append((state.player?.guardKilled ?? false) ? "guard (dead)" : "guard") }
            for s in m.spots where s.hut == h {
                switch s.kind {
                case .torch: parts.append((state.player?.torch ?? false) ? "torch ✓" : "torch")
                case .map: parts.append((state.player?.map ?? false) ? "map ✓" : "map")
                case .boobyTrap: parts.append("booby trap")
                default: if state.trapEntries.contains(s.entry) { parts.append("booby trap (sprung)") }
                }
            }
            lines.append("hut \(h): " + (parts.isEmpty ? "—" : parts.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    func preferredSize() -> CGSize {
        let w = mapW + 2 * JungleMapView.pad
        legend.stringValue = legendText()
        legend.preferredMaxLayoutWidth = mapW
        let lh = legend.stringValue.isEmpty ? 0 : ceil(legend.sizeThatFits(NSSize(width: mapW, height: 1000)).height) + 6
        return CGSize(width: w, height: mapH + 2 * JungleMapView.pad + lh)
    }

    override func layout() {
        super.layout()
        let p = JungleMapView.pad
        legend.frame = CGRect(x: p, y: p + mapH + 6, width: mapW, height: max(0, bounds.height - mapH - 2 * p - 6))
    }

    private func colX(_ c: Int) -> CGFloat { JungleMapView.pad + CGFloat(c) * colW }
    private func worldX(_ wx: Int) -> CGFloat { JungleMapView.pad + CGFloat(wx) / 8 * colW }

    override func draw(_ dirty: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext, let m = state.model else { return }
        let o = JungleMapView.pad
        let title = NSAttributedString(string: "JUNGLE & VILLAGE" + (fog ? "  (explored)" : ""), attributes: [
            .font: OverlayStyle.font(10, .bold), .foregroundColor: OverlayStyle.dim])
        title.draw(at: CGPoint(x: o, y: o - 1))
        let ground = NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.36, alpha: 1).cgColor
        let street = NSColor(calibratedRed: 0.72, green: 0.62, blue: 0.42, alpha: 1).cgColor
        let tree = NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.12, alpha: 1).cgColor
        let water = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1).cgColor
        let plank = NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.15, alpha: 1).cgColor
        let unknown = NSColor(calibratedWhite: 0, alpha: 0.35).cgColor
        let path = NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.35, alpha: 1).cgColor
        let bridgeBlown = (state.player?.bridge ?? 0) == 2
        for l in 0...4 {
            let s = m.strips[l], y = stripY(l)
            for c in 0..<JungleMapModel.columns {
                let r = CGRect(x: colX(c), y: y, width: colW, height: stripH)
                if fog && !state.seen[l][c] { g.setFillColor(unknown); g.fill(r); continue }
                let isStreet = l == 0 && (0x30...0x54).contains(c)
                g.setFillColor(isStreet ? street : ground); g.fill(r)
                if s.water.contains(c) {
                    let planks = JungleMapModel.bridgeCols.contains(c)
                    g.setFillColor(planks && !bridgeBlown ? plank : water)
                    g.fill(CGRect(x: r.minX, y: r.minY + stripH * 0.35, width: colW, height: stripH * 0.65))
                }
                // trees: cells blocked at the player's height
                for x in 0..<8 where s.blocked[c * 8 + x] {
                    g.setFillColor(tree)
                    g.fill(CGRect(x: r.minX + CGFloat(x) * colW / 8, y: r.minY, width: max(1, colW / 8 + 0.5), height: stripH))
                }
            }
            // paths down (to l+1) as connectors in the gap below; up-paths of level 0 lead nowhere
            if l < 4 {
                g.setStrokeColor(path); g.setLineWidth(max(1, colW * 0.45))
                for c in s.down where !fog || state.seen[l][c] || state.seen[l + 1][c] {
                    let x = colX(c) + colW / 2
                    g.move(to: CGPoint(x: x, y: y + stripH)); g.addLine(to: CGPoint(x: x, y: y + stripH + gapH)); g.strokePath()
                }
            }
        }
        // hut doors above strip 0
        let hy = stripY(0) - hutRowH
        for (h, c) in m.hutDoors.enumerated() where !fog || state.seen[0][c] {
            let r = CGRect(x: colX(c) - colW * 0.5, y: hy + 1, width: colW * 2, height: hutRowH - 2)
            g.setFillColor(NSColor(calibratedRed: 0.6, green: 0.45, blue: 0.3, alpha: 1).cgColor); g.fill(r)
            if tier >= 2 {
                let t = NSAttributedString(string: JungleMapView.hutNames[h], attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: max(7, hutRowH - 3), weight: .bold), .foregroundColor: NSColor.white])
                let sz = t.size()
                t.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            }
        }
        if tier >= 1, let p = state.player {
            func mark(_ text: String, level: Int, col: CGFloat, color: NSColor) {
                let t = NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: max(7, stripH - 1), weight: .heavy), .foregroundColor: color,
                    .strokeColor: NSColor.black, .strokeWidth: -3.0])
                let sz = t.size()
                t.draw(at: CGPoint(x: JungleMapView.pad + col * colW - sz.width / 2, y: stripY(level) + stripH / 2 - sz.height / 2))
            }
            if !p.explosives && p.bridge == 0 {
                let c = CGFloat(JungleMapModel.explosivesCols.lowerBound + JungleMapModel.explosivesCols.upperBound + 1) / 2
                mark("E", level: JungleMapModel.explosivesLevel, col: c, color: .systemOrange)
            }
            if p.bridge != 2 {
                mark("B", level: JungleMapModel.bridgeLevel, col: CGFloat(JungleMapModel.bridgeCols.lowerBound) + 1, color: .systemOrange)
                if p.bridge == 0 { mark("✕", level: JungleMapModel.bridgeLevel, col: CGFloat(JungleMapModel.doomCol) + 0.5, color: .systemRed) }
            }
        }
        if tier >= 2 {
            // hut contents: small dots under the doors row, at the spot's world x
            for s in m.spots {
                let color: NSColor
                switch s.kind {
                case .torch: color = (state.player?.torch ?? false) ? .gray : .systemYellow
                case .map: color = (state.player?.map ?? false) ? .gray : .systemTeal
                case .boobyTrap: color = .systemRed
                default:
                    guard state.trapEntries.contains(s.entry) else { continue }
                    color = .darkGray
                }
                let x = worldX(s.worldX)
                g.setFillColor(color.cgColor)
                g.fillEllipse(in: CGRect(x: x - colW * 0.45, y: stripY(0) + stripH * 0.1, width: colW * 0.9, height: colW * 0.9))
            }
        }
        // player
        if let p = state.player {
            let l = p.level == 5 ? 0 : p.level
            guard (0...4).contains(l) else { return }
            let cx = worldX(p.worldX), cy = stripY(l) + stripH / 2
            let s = max(colW * 1.4, 5)
            let dir: CGFloat = p.facingLeft ? -1 : 1
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: cx + dir * s, y: cy))
            tri.addLine(to: CGPoint(x: cx - dir * s * 0.6, y: cy - s * 0.8))
            tri.addLine(to: CGPoint(x: cx - dir * s * 0.6, y: cy + s * 0.8))
            tri.closeSubpath()
            g.addPath(tri)
            g.setFillColor(p.level == 5 ? NSColor.white.cgColor : OverlayStyle.accent.cgColor)
            g.setStrokeColor(NSColor.black.cgColor); g.setLineWidth(1)
            g.drawPath(using: .fillStroke)
        }
    }
}

final class JungleMapPanel: OverlayPanel {
    static let shared = JungleMapPanel()
    let state = JungleMapState()
    let mapView: JungleMapView
    /// Toggled with M (or the pause menu) while the option is on.
    var userHidden = false
    private var drawnGeneration = -1
    private var drawnKey = ""
    private var markedSpoiler = false

    static let kEnabled = "section0.map"
    static let kSpoilers = "section0.mapSpoilers"
    static let kFog = "section0.mapFog"
    static let kSize = "section0.mapSize"
    static let kPlace = "section0.mapPlace"

    private init() {
        mapView = JungleMapView(state: state)
        super.init(id: "section0.jungleMap", view: mapView, anchor: .outsideGame(.bottom, gap: 8), zIndex: 20)
        isVisible = false
    }

    var enabled: Bool { Prefs.bool(JungleMapPanel.kEnabled) }

    func applyPlacement() {
        switch Prefs.int(JungleMapPanel.kPlace) {
        case 1: anchor = .game(.top, inset: 6)
        case 2: anchor = .outsideGame(.top, gap: 8)
        default: anchor = .outsideGame(.bottom, gap: 8)
        }
    }

    /// Outside the game only if the letterbox has room; otherwise at the top of the game image.
    override func frame(in l: OverlayLayout) -> CGRect {
        var f = super.frame(in: l)
        if f.minY < l.bounds.minY || f.maxY > l.bounds.maxY {
            let size = preferredSize ?? view.fittingSize
            f = CGRect(x: (l.gameRect.midX - size.width / 2).rounded(), y: l.gameRect.minY + 6, width: size.width, height: size.height)
        }
        if f.minX < l.bounds.minX { f.origin.x = l.bounds.minX + 4 }
        return f
    }

    /// Section 0 in memory and a jungle/village/hut screen of the main loop (or man select / trap door).
    static func inJungle(_ ctx: FrameContext?) -> Bool {
        guard let c = ctx?.game, c.section == 0 || c.loadedSection == 0 else { return false }
        switch c.screen {
        case .playing, .manSelect, .trapDoorPrompt: return c.jungle != nil
        default: return false
        }
    }

    /// Every emulated frame (AppServices.onFrame).
    func sample(_ ctx: FrameContext) {
        guard enabled, JungleMapPanel.inJungle(ctx) else { return }
        state.sample(ctx.memory)
    }

    override func update(_ ctx: FrameContext?) { refresh(ctx) }

    func refresh(_ ctx: FrameContext?) {
        let show = enabled && !userHidden && JungleMapPanel.inJungle(ctx) && state.model != nil
        if isVisible != show { isVisible = show }
        guard show else { return }
        let tier = max(0, min(2, Prefs.int(JungleMapPanel.kSpoilers)))
        if tier >= 2 && !markedSpoiler { markedSpoiler = true; AppServices.shared.markAssisted("Jungle map: hut contents") }
        let size = CGFloat(max(2, min(8, Prefs.double(JungleMapPanel.kSize))))
        let key = "\(tier) \(Prefs.bool(JungleMapPanel.kFog)) \(size) \(Prefs.int(JungleMapPanel.kPlace))"
        guard state.generation != drawnGeneration || key != drawnKey else { return }
        drawnGeneration = state.generation; drawnKey = key
        mapView.tier = tier
        mapView.fog = Prefs.bool(JungleMapPanel.kFog)
        mapView.colW = size
        applyPlacement()
        preferredSize = mapView.preferredSize()
        mapView.needsLayout = true
        mapView.needsDisplay = true
    }

    /// Section 0 (re)started: a new run of the jungle.
    func sectionStarted() { state.reset(); markedSpoiler = false; userHidden = false; drawnGeneration = -1 }
}
