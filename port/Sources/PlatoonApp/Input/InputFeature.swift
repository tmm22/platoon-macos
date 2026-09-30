import AppKit
import GameController
import PlatoonCore

// OWNER: [input]. Launch-time glue of the input features: applies the Input preferences to the host's
// InputManager, runs its per-frame tick from AppServices.onFrame, the controller hint overlay (S2), rumble (S13),
// pointer tracking (L2a), assisted-run marking, and the self-test (PLATOON_INPUT_TEST=dir).

final class InputFeature {
    static let shared = InputFeature()
    private weak var host: GameHost?
    private let hints = ControllerHintPanel()

    func install(_ app: AppServices) {
        KeyLayout.start()
        if let dir = ProcessInfo.processInfo.environment["PLATOON_INPUT_TEST"] {
            DispatchQueue.main.async { InputSelfTest.run(outDir: dir) }
        }
        app.onHostReady { [weak self] h in
            guard let self else { return }
            self.host = h
            let im = h.inputManager
            im.aim.onFirstUse = { [weak h] in h?.markAssisted("Aim assist (L2)") }
            im.pipeline.onAutoFireUse = { [weak h] in h?.markAssisted("Auto-fire (M13)") }
            self.applyBindings()
            self.applyPrefs()
        }
        app.onReset { h in h.inputManager.aim.newRun(); h.inputManager.pipeline.newRun() }
        app.onFrame { ctx in
            let h = ctx.host, im = h.inputManager
            im.m14Enabled = h.runEnhancements.section0.explicitJumpCrouch
            im.frameTick(machine: ctx.machine, context: ctx.game, directAim: h.runEnhancements.section1.directAim)
        }
        app.onDisplay { [weak self] ctx in self?.hints.refresh(ctx) }
        Prefs.observeAll { [weak self] k in if k.hasPrefix("input.") { self?.applyPrefs() } }
        app.overlay.add(hints)
        hints.forceShow = ProcessInfo.processInfo.environment["PLATOON_INPUT_FORCE_HINTS"] != nil   // app tests without a pad
        app.addPauseMenuItem(PauseMenuItem(id: "input.controls", title: { "Controls & Bindings…" }, order: 405) {
            DispatchQueue.main.async { ControlsWindowController.shared.show() }
            return true
        })
        Rumble.shared.install(app)
    }

    /// Loads the persisted binding table into the running InputManager.
    func applyBindings() {
        host?.inputManager.bindings = InputSettings.load()
    }

    /// Applies every Input preference to the running InputManager.
    func applyPrefs() {
        guard let h = host else { return }
        InputFeature.configure(h.inputManager)
        Rumble.shared.enabled = Prefs.bool(InputSettings.rumbleKey)
        Rumble.shared.strength = Float(UserDefaults.standard.object(forKey: InputSettings.rumbleStrengthKey) == nil ? 1 : Prefs.double(InputSettings.rumbleStrengthKey))
        if h.inputManager.aim.enabled {
            h.inputManager.aim.installMonitor()
            AppServices.shared.window?.acceptsMouseMovedEvents = true
        }
    }

    /// Preferences -> InputManager (also used by the self-test with explicit values).
    static func configure(_ im: InputManager) {
        let d = UserDefaults.standard
        im.deadZone = Float(InputSettings.deadZone)
        im.padContext = d.object(forKey: InputSettings.padContextKey) == nil ? true : Prefs.bool(InputSettings.padContextKey)
        let p = im.pipeline
        let frames = d.object(forKey: InputSettings.tapStretchFramesKey) == nil ? 4 : Prefs.int(InputSettings.tapStretchFramesKey)
        p.stretchFrames = Prefs.bool(InputSettings.tapStretchKey) ? max(2, frames) : 0
        p.toggleFire = Prefs.bool(InputSettings.toggleFireKey)
        p.toggleDirections = Prefs.bool(InputSettings.toggleDirsKey)
        p.autoFireMode = Prefs.int(InputSettings.autoFireKey)
        p.autoFireRate = Prefs.int(InputSettings.autoFireRateKey)
        im.aim.enabled = Prefs.int(InputSettings.aimAssistKey) != 0
        im.aim.stickLead = d.object(forKey: InputSettings.aimSpeedKey) == nil ? 40 : Prefs.double(InputSettings.aimSpeedKey)
        im.refresh()
        im.configurationChanged()
    }
}

/// S2: on-screen controller hints with the controller's own button glyphs (SF Symbols) at the prompts a
/// pad player could not answer before: trap door, man select, high-score name entry. Presentational; shown only
/// while a controller is connected.
final class ControllerHintPanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")
    private var lastKey = ""

    init() {
        let box = OverlayStyle.box()
        super.init(id: "input.hints", view: box, anchor: .game(.bottom, inset: 6), zIndex: 120)
        label.font = OverlayStyle.font(13); label.textColor = OverlayStyle.text
        label.lineBreakMode = .byClipping; label.maximumNumberOfLines = 1; label.cell?.wraps = false
        box.addSubview(label)
        box.isHidden = true
    }

    override func frame(in l: OverlayLayout) -> CGRect {
        // the label's own fitting size counts the symbol attachments (the attributed string's size() doesn't)
        let a = label.attributedStringValue.size(), f = label.fittingSize
        let w = ceil(max(a.width, f.width)) + 6, h = ceil(max(a.height, f.height))
        preferredSize = CGSize(width: w + 20, height: h + 10)
        label.frame = CGRect(x: 10, y: 5, width: w, height: h)
        return super.frame(in: l)
    }

    /// The text for a context (nil = no hint). `forceController` for tests without a pad.
    static func hint(_ c: GameContext, bindings b: BindingSet, forceController: Bool = false) -> [(glyph: PadButton?, text: String)]? {
        func first(_ a: InputAction) -> PadButton? { b[a].pad.first }
        switch c.screen {
        case .trapDoorPrompt:
            var parts: [(PadButton?, String)] = [(.a, "Yes"), (.b, "No")]
            if let y = first(.yes), y != .a { parts.append((y, "Yes")) }
            if let n = first(.no), n != .b { parts.append((n, "No")) }
            return [(nil, "Trap door:")] + parts
        case .manSelect:
            return [(.left, ""), (.right, "choose"), (first(.fire) ?? .a, "select")]
        case .nameEntry:
            return [(.left, ""), (.right, "letter"), (first(.fire) ?? .a, "accept")]
        default:
            return nil
        }
    }

    private static func symbolName(_ b: PadButton, _ g: GCExtendedGamepad?) -> String? {
        if let g {
            let e: GCControllerElement?
            switch b {
            case .a: e = g.buttonA; case .b: e = g.buttonB; case .x: e = g.buttonX; case .y: e = g.buttonY
            case .lb: e = g.leftShoulder; case .rb: e = g.rightShoulder; case .lt: e = g.leftTrigger; case .rt: e = g.rightTrigger
            case .menu: e = g.buttonMenu; case .options: e = g.buttonOptions
            case .left, .right, .up, .down: e = g.dpad
            default: e = nil
            }
            if let n = e?.sfSymbolsName, b != .left && b != .right && b != .up && b != .down { return n }
        }
        switch b {
        case .a: return "a.circle"; case .b: return "b.circle"; case .x: return "x.circle"; case .y: return "y.circle"
        case .lb: return "lb.rectangle.roundedbottom"; case .rb: return "rb.rectangle.roundedbottom"
        case .lt: return "lt.rectangle.roundedtop"; case .rt: return "rt.rectangle.roundedtop"
        case .left: return "dpad.left.filled"; case .right: return "dpad.right.filled"
        case .up: return "dpad.up.filled"; case .down: return "dpad.down.filled"
        case .menu: return "line.3.horizontal.circle"
        default: return nil
        }
    }

    static func attributed(_ parts: [(glyph: PadButton?, text: String)], pad g: GCExtendedGamepad?) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [.font: OverlayStyle.font(13), .foregroundColor: OverlayStyle.text]
        for (i, p) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: p.glyph == nil || parts[i - 1].text.isEmpty ? " " : "   ", attributes: attrs)) }
            if let b = p.glyph {
                if let n = symbolName(b, g), let img = NSImage(systemSymbolName: n, accessibilityDescription: b.title)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
                    let tinted = img.copy() as! NSImage
                    tinted.isTemplate = false
                    let a = NSTextAttachment(); a.image = tint(img, OverlayStyle.accent)
                    a.bounds = CGRect(x: 0, y: -3, width: tinted.size.width, height: tinted.size.height)
                    s.append(NSAttributedString(attachment: a))
                } else {
                    s.append(NSAttributedString(string: "[\(b.title)]", attributes: attrs))
                }
                if !p.text.isEmpty { s.append(NSAttributedString(string: " ", attributes: attrs)) }
            }
            s.append(NSAttributedString(string: p.text, attributes: attrs))
        }
        return s
    }

    private static func tint(_ img: NSImage, _ c: NSColor) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(in: CGRect(origin: .zero, size: img.size))
        c.set()
        CGRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    func refresh(_ ctx: FrameContext) {
        let im = ctx.host.inputManager
        let on = (UserDefaults.standard.object(forKey: InputSettings.padHintsKey) == nil || Prefs.bool(InputSettings.padHintsKey))
            && (im.controllerCount > 0 || forceShow)
        guard on, let parts = ControllerHintPanel.hint(ctx.game, bindings: im.bindings) else { if isVisible { isVisible = false }; lastKey = ""; return }
        let key = parts.map { "\($0.glyph?.rawValue ?? "-")\($0.text)" }.joined()
        if key != lastKey {
            lastKey = key
            label.attributedStringValue = ControllerHintPanel.attributed(parts, pad: im.controllers.first?.extendedGamepad)
            manager?.setNeedsLayout()
        }
        if !isVisible { isVisible = true }
    }
    /// Tests: show hints without a controller.
    var forceShow = false
    func show(_ parts: [(glyph: PadButton?, text: String)]) {
        label.attributedStringValue = ControllerHintPanel.attributed(parts, pad: nil)
        isVisible = true; manager?.setNeedsLayout()
    }
}
