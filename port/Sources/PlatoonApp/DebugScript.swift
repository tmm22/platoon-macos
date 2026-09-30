import AppKit
import PlatoonCore

/// App-level test driver (PLATOON_DEBUG_SCRIPT=file, output dir PLATOON_DEBUG_CAPTURE, default /tmp/platoon-debug).
/// Commands run in order, one per line (# comments):
///   wait N               wait N displayed frames
///   frame N              wait until the emulated frame counter reaches N
///   key HEX down|up|tap  Mac virtual keycode through the app's key routing (tap = down now, up next frame)
///   pad BUTTON down|up|tap  virtual controller button (up down left right a b x y lb rb lt rt l3 r3 menu options)
///   disconnect           virtual controller disconnect (+ the app's disconnect handling)
///   resign / activate    simulate the window losing / regaining focus
///   sleep                simulate system sleep
///   pausemenu            open the pause menu; menu ID = choose the row with that id; menurows = log the row ids
///   prefs TAB            open the Preferences window on a tab; closeprefs
///   pref key=value,...   set preferences
///   reset [SECTION]      reset (optionally start at a section)
///   capture NAME         window capture: game drawable + overlay composited -> NAME.png (+ NAME_game.png, NAME_overlay.png)
///   shot NAME            the game's own screenshot (⌘S path, canvas only) -> NAME.png
///   prefshot NAME        Preferences window content -> NAME.png
///   log TEXT             append host state to log.txt
///   toast TEXT           show a toast
///   resize W H           window content size
///   answer N             answer modal alerts with button N (0 = first) without showing them (logged); "answer" = show again
///   import FILE...       M23 import (%20 = space in paths); checkdisk = the Check Disk report
///   menudump            log the whole main menu tree (titles, shortcuts, state, enabled) to menus.txt
///   panels              log the overlay panels (id, z, visible, modal)
///   windows / assisted  log the visible windows / the current run's assisted reasons
///   quit
final class DebugScript {
    private var lines: [[String]]
    private var pc = 0
    private var waitFrames = 0
    private var waitUntilFrame: UInt64?
    private weak var app: AppDelegate?
    private let dir: String
    private var pendingKeyUps: [UInt16] = []
    private var pendingPadUps: [PadButton] = []
    private var logFile: FileHandle?
    private var pendingCaptures = 0
    private var quitRequested = false
    private var quitWaitFrames = 0

    init?(path: String, app: AppDelegate) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { NSLog("debug script not found: \(path)"); return nil }
        lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { $0.split(separator: " ").map(String.init) }
        self.app = app
        dir = ProcessInfo.processInfo.environment["PLATOON_DEBUG_CAPTURE"] ?? "/tmp/platoon-debug"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/log.txt", contents: nil)
        logFile = FileHandle(forWritingAtPath: dir + "/log.txt")
    }

    private func log(_ s: String) {
        logFile?.write((s + "\n").data(using: .utf8)!)
        print("[debug] " + s)
    }

    private func state(_ label: String) -> String {
        guard let app, let h = app.host else { return "\(label): no host" }
        let i = h.machine.input
        let reasons = h.pauseReasons.map { "\($0)" }.sorted().joined(separator: ",")
        return "\(label): frame=\(h.machine.frameCount) paused=\(h.paused) reasons=[\(reasons)] menu=\(app.pauseMenu.isVisible) "
            + "ff=\(h.isFastForwarding) section=\(h.currentSection.map(String.init) ?? "-") assisted=\(h.isAssisted) "
            + "joy=\(i.up ? "U" : "")\(i.down ? "D" : "")\(i.left ? "L" : "")\(i.right ? "R" : "")\(i.fire ? "F" : "") "
            + "suspended=\(h.inputManager.suspended) modal=\(AppServices.shared.overlay.modalPanel?.id ?? "-")"
    }

    /// Called at the start of every displayed frame.
    func step() {
        guard let app else { return }
        for k in pendingKeyUps { app.handleKey(k, down: false, isRepeat: false, event: nil) }
        pendingKeyUps.removeAll()
        for b in pendingPadUps { app.host?.inputManager.injectPad(b, down: false) }
        pendingPadUps.removeAll()
        if quitRequested {
            // wait for outstanding window captures, but not forever (a capture whose drawable never came, e.g. an
            // occluded window, used to keep the app running until the harness killed it)
            quitWaitFrames += 1
            if pendingCaptures == 0 || quitWaitFrames > 150 {
                if pendingCaptures > 0 { log("quit: \(pendingCaptures) capture(s) never completed") }
                logFile?.closeFile()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }   // if termination is held up
                NSApp.terminate(nil)
            }
            return
        }
        if waitFrames > 0 { waitFrames -= 1; return }
        if let f = waitUntilFrame { if (app.host?.machine.frameCount ?? 0) < f { return }; waitUntilFrame = nil }
        while pc < lines.count {
            let l = lines[pc]; pc += 1
            let a = Array(l.dropFirst())
            switch l[0] {
            case "wait": waitFrames = Int(a.first ?? "1") ?? 1; return
            case "frame": waitUntilFrame = UInt64(a.first ?? "0") ?? 0; return
            case "key":
                guard let c = UInt16(a.first ?? "", radix: 16) else { continue }
                let mode = a.count > 1 ? a[1] : "tap"
                if mode == "up" { app.handleKey(c, down: false, isRepeat: false, event: nil) }
                else { app.handleKey(c, down: true, isRepeat: false, event: nil); if mode == "tap" { pendingKeyUps.append(c) } }
                return
            case "pad":
                guard let b = PadButton(rawValue: a.first ?? "") else { log("bad pad button \(a)"); continue }
                let mode = a.count > 1 ? a[1] : "tap"
                app.host?.inputManager.injectPad(b, down: mode != "up")
                if mode == "tap" { pendingPadUps.append(b) }
                return
            case "disconnect": app.host?.inputManager.injectDisconnect(); app.controllerChanged(connected: false)
            case "resign": app.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            case "activate": app.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            case "sleep": app.systemWillSleep()
            case "answer": app.debugAlertAnswer = a.first.flatMap { Int($0) }; app.debugLog = { [weak self] in self?.log($0) }
            case "import": app.importDisks(a.map { URL(fileURLWithPath: $0.replacingOccurrences(of: "%20", with: " ")) }); waitFrames = 5; return
            case "checkdisk": app.showDiskHealth()
            case "overlaytest":
                if a.first == "off" { AppServices.shared.overlay.remove(id: "debug.frame"); AppServices.shared.overlay.remove(id: "debug.caption") }
                else {
                    AppServices.shared.overlay.add(DebugFramePanel())
                    let t = TextOverlayPanel(id: "debug.caption", anchor: .game(.bottom, inset: 12)); t.text = "Caption panel anchored to the game image"
                    AppServices.shared.overlay.add(t)
                }
            case "pausemenu": app.showPauseMenu()
            case "menu":
                if !app.pauseMenu.debugChoose(a.first ?? "") { log("menu: no row \(a.first ?? "") in \(app.pauseMenu.debugRowIDs)") }
                waitFrames = 2; return
            case "menurows": log("menu rows: \(app.pauseMenu.debugRowIDs)")
            case "menudump": dumpMenus(a.first ?? "menus")
            case "panels": log("panels: " + AppServices.shared.overlay.debugPanels)
            case "windows": log("windows: " + NSApp.windows.filter(\.isVisible).map { "'\($0.title)'" }.joined(separator: ", "))
            case "assisted": log("assisted: \(app.host?.assistedReasons ?? [])")
            case "prefs": app.openPreferences(tab: PrefTab(rawValue: a.first ?? "general")); waitFrames = 10; return
            case "closeprefs": PreferencesWindowController.shared.window?.orderOut(nil); app.window.makeKeyAndOrderFront(nil)
            case "pref":
                let spec = a.joined(separator: " ")
                Prefs.applyOverrides(spec)
                for kv in spec.split(separator: ",") {        // live-apply hooks, as when the value is changed in the window
                    if let k = kv.split(separator: "=").first.map(String.init) { Prefs.notifyChanged(k) }
                }
                PrefsModel.shared.bump(); app.applyVideoSettings(); app.host?.applyAudioSettings()
            case "reset": app.host?.resumeAll(); app.pauseMenu.isVisible = false; app.host?.reset(startSection: a.first.flatMap { Int($0) })
            case "toast": AppServices.shared.toast(a.joined(separator: " "))
            case "resize":
                if a.count == 2, let w = Double(a[0]), let h = Double(a[1]) { app.window.setContentSize(NSSize(width: w, height: h)) }
                waitFrames = 5; return
            case "shot":
                if let h = app.host { try? ImageIO.canvasPNG(h.machine.chip).write(to: URL(fileURLWithPath: "\(dir)/\(a.first ?? "shot").png")) }
            case "capture": capture(a.first ?? "capture"); return
            case "prefshot": prefShot(a.first ?? "prefs")
            case "log": log(state(a.joined(separator: " ")))
            case "quit": quitRequested = true; return
            default: log("unknown command \(l)")
            }
        }
    }

    /// Writes the main menu tree (as the user would see it after validation) to NAME.txt.
    private func dumpMenus(_ name: String) {
        guard let main = NSApp.mainMenu else { return }
        var out = ""
        func walk(_ m: NSMenu, _ depth: Int) {
            m.update()
            for i in m.items {
                let pad = String(repeating: "  ", count: depth)
                if i.isHidden { continue }        // e.g. AppKit's hidden ⌃⌘F alternate of Enter Full Screen
                if i.isSeparatorItem { out += pad + "----\n"; continue }
                if let t = i.target as? NSMenuItemValidation { _ = t.validateMenuItem(i) }
                else if let t = i.target as? AppDelegate { _ = t.validateMenuItem(i) }
                var key = ""
                if !i.keyEquivalent.isEmpty {
                    let f = i.keyEquivalentModifierMask
                    key = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
                    key += i.keyEquivalent == " " ? "Space" : i.keyEquivalent.uppercased()
                }
                if ProcessInfo.processInfo.environment["PLATOON_DEBUG_MENU_ACTIONS"] != nil, let sel = i.action { key += " " + NSStringFromSelector(sel) + " tag=\(i.tag)" }
                out += pad + i.title + (key.isEmpty ? "" : "   [\(key)]") + (i.state == .on ? "   ✓" : "") + (i.isEnabled ? "" : "   (disabled)") + "\n"
                if let s = i.submenu { walk(s, depth + 1) }
            }
        }
        walk(main, 0)
        try? out.write(toFile: "\(dir)/\(name).txt", atomically: true, encoding: .utf8)
        log("menus written to \(name).txt")
    }

    private func prefShot(_ name: String) {
        guard let v = PreferencesWindowController.shared.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    /// Captures the next presented drawable and composites the overlay (as the user sees the window).
    private func capture(_ name: String) {
        guard let app else { return }
        let overlay = AppServices.shared.overlay.snapshot()
        if let o = overlay { try? o.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)_overlay.png")) }
        let path = "\(dir)/\(name)"
        pendingCaptures += 1
        app.renderer.captureHandler = { [weak self] buf, w, h in
            let gamePNG = ImageIO.png(width: w, height: h) { x, y in buf[y * w + x] }
            try? gamePNG.write(to: URL(fileURLWithPath: path + "_game.png"))
            DispatchQueue.main.async {
                defer { self?.pendingCaptures -= 1 }
                guard let game = NSImage(data: gamePNG), let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
                let r = NSRect(x: 0, y: 0, width: w, height: h)
                game.draw(in: r)
                if let o = overlay { o.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil) }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
            }
        }
        waitFrames = 2
    }
}

/// Test panel: outlines visible-screen lowres rect (0,0)-(320,256) and a marker at x=16..19, y=160..170.
final class DebugFramePanel: OverlayPanel {
    final class V: NSView {
        var l: OverlayLayout?
        override var isFlipped: Bool { true }
        override func draw(_ r: NSRect) {
            guard let l else { return }
            let o = frame.origin
            func p(_ x: Double, _ y: Double) -> CGPoint { let q = l.point(x: x, y: y); return CGPoint(x: q.x - o.x, y: q.y - o.y) }
            NSColor.magenta.setStroke()
            let a = p(0, 0), b = p(320, 256)
            let path = NSBezierPath(rect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)); path.lineWidth = 2; path.stroke()
            NSColor.yellow.setStroke()
            let c = p(16, 160), d = p(20, 170)
            NSBezierPath(rect: CGRect(x: c.x, y: c.y, width: d.x - c.x, height: d.y - c.y)).stroke()
        }
    }
    init() { super.init(id: "debug.frame", view: V(), anchor: .fillWindow, zIndex: 50) }
    override func frame(in l: OverlayLayout) -> CGRect { (view as? V)?.l = l; view.needsDisplay = true; return l.bounds }
}
