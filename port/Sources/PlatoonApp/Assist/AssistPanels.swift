import AppKit
import SwiftUI
import PlatoonCore

// [assist] Overlay panels (F3) of the read-only assists: captions (S8), objectives / numeric HUD / briefing (M2),
// speedrun timer (M16) and the practice badge (M11). They are never drawn into the game picture or screenshots.

enum AssistLayout {
    /// A panel beside the game image (left or right bar, top- or bottom-aligned) when `beside` and there is room;
    /// otherwise on the picture in that corner.
    static func side(_ l: OverlayLayout, _ size: CGSize, left: Bool, top: Bool, beside: Bool, gap: CGFloat = 10,
                     pictureOffset: CGFloat = 0) -> CGRect {
        let g = l.gameRect
        let room = left ? g.minX - l.bounds.minX : l.bounds.maxX - g.maxX
        let y = top ? g.minY + 8 : g.maxY - 8 - size.height
        if beside && room >= size.width + gap + 4 {
            let x = left ? g.minX - gap - size.width : g.maxX + gap
            return CGRect(x: x.rounded(), y: max(l.bounds.minY + 4, y).rounded(), width: size.width, height: size.height)
        }
        let x = left ? g.minX + 8 : g.maxX - 8 - size.width
        return CGRect(x: x.rounded(), y: (y + (top ? pictureOffset : -pictureOffset)).rounded(), width: size.width, height: size.height)
    }

    static let accent = Color(red: 0.55, green: 0.85, blue: 0.45)
    static let warn = Color(red: 1, green: 0.55, blue: 0.4)
    static let box = Color(white: 0.04, opacity: 0.84)
}

/// Common base: a SwiftUI panel whose size follows its content.
class AssistHostingPanel<Content: View>: OverlayPanel {
    let hosting: NSHostingView<Content>
    init(id: String, zIndex: Int, root: Content) {
        hosting = NSHostingView(rootView: root)
        super.init(id: id, view: hosting, anchor: .game(.topLeft), zIndex: zIndex)
        hosting.isHidden = true
    }
    func contentChanged() { preferredSize = hosting.fittingSize; manager?.setNeedsLayout() }
}

// MARK: - S8 captions

final class CaptionPanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")
    private var shownText = ""
    private var shownAt: CFTimeInterval = 0
    private var cacheKey: UInt64 = .max
    private var cacheText = ""

    init() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 0.6).cgColor
        box.layer?.borderWidth = 1
        super.init(id: "assist.captions", view: box, anchor: .game(.bottom), zIndex: 110)
        label.textColor = NSColor(calibratedRed: 1, green: 0.93, blue: 0.35, alpha: 1)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        box.addSubview(label)
        box.isHidden = true
    }

    /// The HUD message the game shows now (queue head of the current table), nil if none.
    static func currentMessage(_ c: GameContext, memory: Memory, cache: inout (UInt64, String)) -> String? {
        guard c.inGame, c.section != nil, c.messageCount > 0, let idx = c.messageQueue.first else { return nil }
        let key = UInt64(c.messageTable) << 16 | UInt64(idx & 0xffff)
        if cache.0 != key {
            let a = memory.r32(c.messageTable &+ UInt32(idx & 0xff) << 2)
            cache = (key, PrintText.decode(memory, a))
        }
        return cache.1.isEmpty ? nil : cache.1
    }

    func refresh(_ c: GameContext, memory: Memory) {
        guard Prefs.bool(AssistPrefs.captions) else { if isVisible { isVisible = false }; return }
        var cache = (cacheKey, cacheText)
        let now = CACurrentMediaTime()
        let cur = CaptionPanel.currentMessage(c, memory: memory, cache: &cache)
        cacheKey = cache.0; cacheText = cache.1
        if let t = cur {
            if t != shownText { shownText = t; shownAt = now; setText(t) }
            if !isVisible { isVisible = true }
        } else if isVisible {
            let hold = Prefs.double(AssistPrefs.captionHold)
            if now - shownAt >= hold || c.section == nil { isVisible = false; shownText = "" }
        }
    }

    private func setText(_ t: String) {
        label.font = NSFont.monospacedSystemFont(ofSize: CGFloat(max(12, Prefs.double(AssistPrefs.captionSize))), weight: .bold)
        label.stringValue = t
        manager?.setNeedsLayout()
    }

    override func frame(in l: OverlayLayout) -> CGRect {
        let maxW = max(160, min(l.bounds.width - 16, max(l.gameRect.width - 16, 300)))
        let pad: CGFloat = 12
        label.preferredMaxLayoutWidth = maxW - 2 * pad
        let ts = label.sizeThatFits(NSSize(width: maxW - 2 * pad, height: 1000))
        let size = CGSize(width: min(maxW, ceil(ts.width) + 2 * pad), height: ceil(ts.height) + 12)
        label.frame = CGRect(x: pad, y: 6, width: size.width - 2 * pad, height: size.height - 12)
        let g = l.gameRect
        let x = (g.midX - size.width / 2).rounded()
        let y: CGFloat
        switch Prefs.int(AssistPrefs.captionPlace) {
        case 2: y = g.minY + 8
        case 1: y = g.maxY - 8 - size.height
        default: y = l.bounds.maxY - g.maxY >= size.height + 10 ? g.maxY + 6 : g.maxY - 8 - size.height
        }
        return CGRect(x: max(l.bounds.minX + 4, x), y: y.rounded(), width: size.width, height: size.height)
    }
}

// MARK: - M2 objectives

final class ObjectivesModel: ObservableObject {
    @Published var sheet: ObjectiveSheet?
}

struct ObjectivesView: View {
    @ObservedObject var model: ObjectivesModel
    var body: some View {
        if let s = model.sheet {
            VStack(alignment: .leading, spacing: 5) {
                Text(s.title.uppercased()).font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                ForEach(Array(s.objectives.enumerated()), id: \.offset) { _, o in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(o.state == .done ? "☑" : "☐").font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(o.state == .done ? AssistLayout.accent : .white)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(o.title + (o.optional ? " (optional)" : "")).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(o.state == .done ? Color(white: 0.6) : .white)
                                    .strikethrough(o.state == .done, color: Color(white: 0.5))
                                if let p = o.progress, o.state != .done {
                                    Text(p).font(.system(size: 11, design: .monospaced)).foregroundStyle(AssistLayout.accent)
                                }
                            }
                            if let d = o.detail, o.state != .done {
                                Text(d).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.72))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                ForEach(s.advice, id: \.self) { a in
                    Text("▶ " + a).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(AssistLayout.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(width: 250, alignment: .leading)
            .background(AssistLayout.box, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
        }
    }
}

final class ObjectivesPanel: AssistHostingPanel<ObjectivesView> {
    let model = ObjectivesModel()
    private var markedSolution = false
    init() {
        let m = model
        super.init(id: "assist.objectives", zIndex: 60, root: ObjectivesView(model: m))
        anchor = .custom { [weak self] l, size in
            AssistLayout.side(l, self?.hosting.fittingSize ?? size, left: true, top: true, beside: Prefs.int(AssistPrefs.objectivesPlace) == 0)
        }
    }
    override func hostDidReset() { markedSolution = false }

    func refresh(_ c: GameContext) {
        guard Prefs.bool(AssistPrefs.objectives), c.inGame, c.section != nil,
              [.playing, .trapDoorPrompt, .manSelect].contains(c.screen) else {
            if isVisible { isVisible = false }
            return
        }
        let tier = ObjectiveTier(rawValue: max(1, min(3, Prefs.int(AssistPrefs.objectivesTier)))) ?? .goals
        let e = AssistCenter.shared.host?.runEnhancements
        let sheet = AssistCenter.shared.objectives.sheet(c, tier: tier, randomisedVillage: e?.section0.villageSeed != nil,
                                                         randomisedTunnels: (e?.section1.randomSeed ?? 0) != 0)
        if tier == .solution && !markedSolution { markedSolution = true; AppServices.shared.markAssisted("Objectives: full solution") }
        if sheet != model.sheet { model.sheet = sheet; contentChanged() }
        if !isVisible { isVisible = true; contentChanged() }
    }
}

// MARK: - M2 numeric HUD

final class HudModel: ObservableObject { @Published var lines: [HudReadout.Line] = [] }

struct HudView: View {
    @ObservedObject var model: HudModel
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(Array(model.lines.enumerated()), id: \.offset) { _, l in
                GridRow {
                    Text(l.label).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Color(white: 0.65))
                    Text(l.value).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(l.warn ? AssistLayout.warn : .white)
                }
            }
        }
        .padding(10)
        .background(AssistLayout.box, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
    }
}

final class HudReadoutPanel: AssistHostingPanel<HudView> {
    let model = HudModel()
    init() {
        let m = model
        super.init(id: "assist.hud", zIndex: 61, root: HudView(model: m))
        anchor = .custom { [weak self] l, size in
            AssistLayout.side(l, self?.hosting.fittingSize ?? size, left: false, top: false, beside: Prefs.int(AssistPrefs.hudPlace) == 0)
        }
    }
    func refresh(_ c: GameContext) {
        guard Prefs.bool(AssistPrefs.hud), c.inGame, c.section != nil, c.screen != .textScreen else {
            if isVisible { isVisible = false }; return
        }
        let lines = HudReadout.lines(c)
        if lines != model.lines { let resize = lines.count != model.lines.count; model.lines = lines; if resize { contentChanged() } }
        if !isVisible { isVisible = true; contentChanged() }
    }
}

// MARK: - M2 briefing card (over LOADING / ENTERING THE COMBAT ZONE)

final class BriefingModel: ObservableObject {
    @Published var card: Briefing.Card?
    @Published var footer: [String] = []
}

struct BriefingView: View {
    @ObservedObject var model: BriefingModel
    var body: some View {
        if let c = model.card {
            VStack(alignment: .leading, spacing: 8) {
                Text("BRIEFING").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(AssistLayout.accent)
                Text(c.title).font(.system(size: 18, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                ForEach(c.lines, id: \.self) { l in
                    Text("• " + l).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color(white: 0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.footer, id: \.self) { f in
                    Text(f).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.4))
                }
                Text("click to hide").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color(white: 0.5))
            }
            .padding(16)
            .frame(width: 420, alignment: .leading)
            .background(Color(white: 0.03, opacity: 0.9), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.2)))
            .onTapGesture { model.card = nil }
        }
    }
}

final class BriefingPanel: AssistHostingPanel<BriefingView> {
    let model = BriefingModel()
    private var shownFor: Int?
    private var playingSince: CFTimeInterval?
    init() {
        let m = model
        super.init(id: "assist.briefing", zIndex: 300, root: BriefingView(model: m))
        anchor = .game(.center, inset: 0)
        isInteractive = true
    }
    override func hostDidReset() { shownFor = nil; model.card = nil; isVisible = false }

    func event(_ e: GameEvent) {
        if case .newGame = e { shownFor = nil }
    }

    func refresh(_ c: GameContext, memory: Memory) {
        guard Prefs.bool(AssistPrefs.briefings) else { if isVisible { isVisible = false }; return }
        let now = CACurrentMediaTime()
        // while a section loads, $6e(a6) is the section being loaded (the loaded one is still the previous)
        let s = Int(memory.r16(Platoon.a6 + 0x6e))
        if c.inGame, (c.screen == .loading || c.screen == .entering), (0...2).contains(s), shownFor != s {
            shownFor = s; playingSince = nil
            let tier = ObjectiveTier(rawValue: max(1, min(3, Prefs.int(AssistPrefs.objectivesTier)))) ?? .goals
            model.card = Briefing.card(section: s, tier: tier == .goals ? .goals : .hints)
            var f: [String] = []
            if c.difficulty != .original { f.append("Difficulty: \(c.difficulty.title)") }
            if let h = AssistCenter.shared.host, h.isAssisted { f.append("Assisted game — kept out of the original high scores") }
            model.footer = f
            contentChanged()
        }
        if model.card != nil, c.screen == .playing {
            if playingSince == nil { playingSince = now }
            if now - (playingSince ?? now) > 4 { model.card = nil }
        }
        let show = model.card != nil
        if show != isVisible { isVisible = show; if show { contentChanged() } }
    }
}

// MARK: - M16 timer

final class TimerModel: ObservableObject {
    @Published var time = "0:00.00"
    @Published var rows: [(name: String, time: String, delta: String?, ahead: Bool?)] = []
    @Published var status = ""
    @Published var showSplits = true
}

struct TimerView: View {
    @ObservedObject var model: TimerModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if model.showSplits {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 8) {
                        Text(r.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.8))
                        Spacer(minLength: 4)
                        if let d = r.delta {
                            Text(d).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(r.ahead == true ? AssistLayout.accent : r.ahead == false ? AssistLayout.warn : .white)
                        }
                        Text(r.time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                    }
                }
            }
            Text(model.time).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(.white).monospacedDigit()
            if !model.status.isEmpty {
                Text(model.status).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.6))
            }
        }
        .padding(10)
        .frame(width: 210, alignment: .trailing)
        .background(AssistLayout.box, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
    }
}

final class TimerPanel: AssistHostingPanel<TimerView> {
    let model = TimerModel()
    private var lastKey = ""
    init() {
        let m = model
        super.init(id: "assist.timer", zIndex: 62, root: TimerView(model: m))
        anchor = .custom { [weak self] l, size in AssistLayout.side(l, self?.hosting.fittingSize ?? size, left: false, top: true, beside: true, pictureOffset: 36) }   // below the PAUSED badge
    }
    func refresh(_ t: RunTimer, records: SpeedrunRecords) {
        guard Prefs.bool(AssistPrefs.timer), t.status != .idle else { if isVisible { isVisible = false }; return }
        let time = RunSplits.clock(t.frames)
        if time != model.time { model.time = time }
        let showSplits = Prefs.bool(AssistPrefs.timerSplits)
        let key = "\(t.splits.count)|\(t.status)|\(showSplits)|\(t.category)"
        if key != lastKey {
            lastKey = key
            let cat = t.category
            var rows: [(name: String, time: String, delta: String?, ahead: Bool?)] = t.splits.suffix(5).map { s in
                let pb = records.pbSplit(cat, s.id)
                return (s.name, RunSplits.clock(s.frames, hundredths: false), pb.map { RunSplits.delta(s.frames - $0) }, pb.map { s.frames <= $0 })
            }
            // the next split of the PB run
            if let b = records.best[cat], let nx = b.splits.first(where: { s in !t.splits.contains { $0.id == s.id } }) {
                rows.append((nx.name, "PB " + RunSplits.clock(nx.frames, hundredths: false), nil, nil))
            }
            model.rows = rows
            model.showSplits = showSplits
            model.status = (t.status == .won ? "FINISHED · " : t.status == .ended ? "ENDED · " : "") + cat
            contentChanged()
        }
        if !isVisible { isVisible = true; contentChanged() }
    }
}

// MARK: - M11 practice badge

final class PracticeBadgePanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")
    init() {
        let box = OverlayStyle.box()
        super.init(id: "assist.practiceBadge", view: box, anchor: .game(.top, inset: 8), zIndex: 390)
        label.font = OverlayStyle.font(12, .bold); label.textColor = OverlayStyle.text
        box.addSubview(label)
        box.isHidden = true
    }
    override func frame(in l: OverlayLayout) -> CGRect {
        let s = label.fittingSize
        preferredSize = CGSize(width: s.width + 20, height: s.height + 10)
        label.frame = CGRect(x: 10, y: 5, width: s.width, height: s.height)
        return super.frame(in: l)
    }
    func refresh(_ p: PracticeController) {
        guard Prefs.bool(AssistPrefs.practiceBadge), let t = p.badgeText else { if isVisible { isVisible = false }; return }
        if label.stringValue != t { label.stringValue = t; manager?.setNeedsLayout() }
        if !isVisible { isVisible = true }
    }
}

// MARK: - M10 difficulty on the ENTERING THE COMBAT ZONE screen

/// Shows the difficulty preset of the game (and "ASSISTED") while a section is entered, when it isn't Original.
final class DifficultyBadgePanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")
    init() {
        let box = OverlayStyle.box()
        super.init(id: "assist.difficultyBadge", view: box, anchor: .game(.bottom, inset: 24), zIndex: 380)
        label.font = OverlayStyle.font(15, .heavy); label.textColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0.35, alpha: 1)
        box.addSubview(label)
        box.isHidden = true
    }
    override func frame(in l: OverlayLayout) -> CGRect {
        let s = label.fittingSize
        preferredSize = CGSize(width: s.width + 24, height: s.height + 12)
        label.frame = CGRect(x: 12, y: 6, width: s.width, height: s.height)
        return super.frame(in: l)
    }
    func refresh(_ c: GameContext) {
        let show = c.inGame && (c.screen == .entering || c.screen == .loading) && c.difficulty != .original
        if show {
            let t = "DIFFICULTY: \(c.difficulty.title.uppercased())"
            if label.stringValue != t { label.stringValue = t; manager?.setNeedsLayout() }
        }
        if show != isVisible { isVisible = show }
    }
}
