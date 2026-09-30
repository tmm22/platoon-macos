import AppKit
import MetalKit
import UniformTypeIdentifiers
import PlatoonCore

/// Window content: the Metal game view with the assist overlay (F3) stacked above it.
final class GameContainerView: NSView {
    override var isFlipped: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, MTKViewDelegate {
    var window: NSWindow!
    var view: GameView!
    var renderer: MetalRenderer!
    var host: GameHost?
    private(set) var pauseMenu: PauseMenuPanel!
    private let pauseBadge = PauseBadgePanel()
    private var debugScript: DebugScript?
    private var menusByTarget: [MenuTarget: NSMenu] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        let services = AppServices.shared
        services.app = self
        if ProcessInfo.processInfo.environment["PLATOON_DEBUG_FRESH_PREFS"] != nil, let dom = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName as String? {
            UserDefaults.standard.removePersistentDomain(forName: dom)      // tests: start from default settings
        }
        PrefsRegistry.registerDefaults()
        if let o = ProcessInfo.processInfo.environment["PLATOON_PREFS"] { Prefs.applyOverrides(o) }

        let frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Platoon"
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 320, height: 256)
        view = GameView(frame: frame, device: MTLCreateSystemDefaultDevice())
        // The game runs at 50 Hz (PAL). On variable-refresh (ProMotion) displays ask for 50 Hz so every Amiga
        // frame is shown exactly once (smooth scrolling); elsewhere present at the display rate.
        let maxFPS = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.preferredFramesPerSecond = maxFPS >= 100 ? 50 : 120
        view.framebufferOnly = false
        guard let r = MetalRenderer(view: view) else { fatalError("Metal is required") }
        renderer = r
        view.delegate = self

        let container = GameContainerView(frame: frame)
        view.frame = container.bounds; view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let overlay = services.overlay.view
        overlay.frame = container.bounds; overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        window.contentView = container
        view.registerForDraggedTypes([.fileURL])
        view.onDrop = { [weak self] urls in self?.importDisks(urls); return true }

        pauseMenu = PauseMenuPanel(app: self)
        services.overlay.add(pauseMenu)
        services.overlay.add(pauseBadge)

        buildMenu()
        FeatureHooks.installAll(services)

        window.center()
        window.setFrameAutosaveName("PlatoonMain")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        applyVideoSettings()
        installAutoPauseObservers()
        NSApp.activate(ignoringOtherApps: true)
        if let s = ProcessInfo.processInfo.environment["PLATOON_DEBUG_SCRIPT"] { debugScript = DebugScript(path: s, app: self) }
        loadDisk()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Files opened from the Finder / Dock / `open -a Platoon file.adf` (M23).
    func application(_ app: NSApplication, open urls: [URL]) {
        let adfs = urls.filter { $0.pathExtension.lowercased() == "adf" }
        if !adfs.isEmpty { importDisks(adfs) }
    }

    // MARK: focus / sleep / controller (S4)
    func windowDidResignKey(_ n: Notification) {
        host?.inputManager.releaseAll()
        host?.inputManager.forgetPhysicalKeys()
        host?.fastForwardHeld = false
        autoPauseForFocus()
    }
    func windowDidBecomeKey(_ n: Notification) {
        if Prefs.int(BuiltinPrefs.pauseOnFocus) == 1 { host?.resume(.focus) }
    }
    func windowDidMiniaturize(_ n: Notification) { autoPauseForFocus() }

    private func autoPauseForFocus() {
        guard let h = host else { return }
        switch Prefs.int(BuiltinPrefs.pauseOnFocus) {
        case 1: h.pause(.focus)
        case 2: h.pause(.focus); showPauseMenu()
        default: break
        }
    }

    private func installAutoPauseObservers() {
        let nc = NotificationCenter.default, wc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.autoPauseForFocus()
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.systemWillSleep() })
        }
    }
    func systemWillSleep() {
        guard let h = host, Prefs.int(BuiltinPrefs.pauseOnSleep) != 0 else { return }
        h.pause(.sleep); showPauseMenu()
    }
    func controllerChanged(connected: Bool) {
        guard let h = host else { return }
        if !connected {
            AppServices.shared.toast("Controller disconnected")
            if Prefs.int(BuiltinPrefs.pauseOnController) != 0 { h.pause(.controller); showPauseMenu() }
        } else {
            AppServices.shared.toast("Controller connected")
        }
    }

    /// Runs a modal alert, pausing the game meanwhile if "Pause while a dialog is open" is on.
    /// Tests (debug script `answer N`): modal alerts are not shown; they are logged and answered with button N.
    var debugAlertAnswer: Int?
    var debugLog: ((String) -> Void)?

    @discardableResult func runModal(_ a: NSAlert) -> NSApplication.ModalResponse {
        if let n = debugAlertAnswer {
            debugLog?("ALERT: \(a.messageText) | \(a.informativeText.replacingOccurrences(of: "\n", with: " / ")) | buttons=\(a.buttons.map(\.title)) -> \(n)")
            return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + n)
        }
        let p = Prefs.bool(BuiltinPrefs.pauseForDialogs)
        if p { host?.pause(.dialog) }
        defer { if p { host?.resume(.dialog) } }
        return a.runModal()
    }
    func runModal(_ panel: NSOpenPanel) -> NSApplication.ModalResponse {
        let p = Prefs.bool(BuiltinPrefs.pauseForDialogs)
        if p { host?.pause(.dialog) }
        defer { if p { host?.resume(.dialog) } }
        return panel.runModal()
    }

    // MARK: disk
    static var supportDiskURL: URL? {
        if let d = ProcessInfo.processInfo.environment["PLATOON_SUPPORT_DIR"] { return URL(fileURLWithPath: d).appendingPathComponent("Platoon.adf") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Platoon/Platoon.adf")
    }
    /// URL of the disk image in use.
    private(set) var diskURL: URL?

    func loadDisk() {
        var candidates: [URL] = []
        // an imported disk (M23) takes precedence over the bundled one
        if let u = AppDelegate.supportDiskURL { candidates.append(u) }
        if let u = Bundle.main.url(forResource: "Platoon", withExtension: "adf") { candidates.append(u) }
        if let bm = Settings.shared.adfBookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, options: .withSecurityScope, bookmarkDataIsStale: &stale) { _ = u.startAccessingSecurityScopedResource(); candidates.append(u) }
        }
        if let e = ProcessInfo.processInfo.environment["PLATOON_ADF"] { candidates.insert(URL(fileURLWithPath: e), at: 0) }
        for u in candidates {
            if let d = try? Disk(contentsOf: u), (try? d.validate()) != nil, DiskHealth.check(d.data).runnable { diskURL = u; start(d); return }
        }
        let alert = NSAlert()
        alert.messageText = "Locate your Platoon disk image"
        alert.informativeText = "Platoon needs the original Amiga disk (an .adf file) to run. Please select it. "
            + "You can select two dumps at once (for example the [cr 68 Darc] crack and the original [b] dump): damaged tracks of one are repaired from the other."
        alert.addButton(withTitle: "Choose…"); alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        guard let urls = chooseDisks() else { NSApp.terminate(nil); return }
        if !importDisks(urls) { loadDisk() }
    }

    private func chooseDisks() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "adf") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one Platoon .adf, or several dumps to combine their good tracks."
        guard runModal(panel) == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    func importDiskInteractively() {
        guard let urls = chooseDisks() else { return }
        importDisks(urls)
    }

    /// M23: health-checks the dump(s), repairs from the others where possible, asks, then installs the result in
    /// Application Support and restarts the game with it. Returns true if a disk was installed.
    @discardableResult func importDisks(_ urls: [URL]) -> Bool {
        let images = urls.compactMap { try? [UInt8](Data(contentsOf: $0)) }
        guard let rep = DiskHealth.repair(images) else {
            let a = NSAlert(); a.messageText = "That is not an Amiga disk image."; runModal(a); return false
        }
        let reports = images.map(DiskHealth.check)
        let a = NSAlert()
        var info: [String] = []
        for (u, r) in zip(urls, reports) { info.append("\(u.lastPathComponent): \(r.name ?? "unknown dump") — \(r.verified ? "verified" : r.runnable ? "has damaged tracks" : "not usable on its own")") }
        if !rep.fixed.isEmpty {
            let parts = rep.fixed.keys.sorted().map { t -> String in
                let src = rep.fixed[t]!
                return "track \(t) from " + (src < 0 ? "the built-in default high-score table" : urls[src].lastPathComponent)
            }
            info.append("Repaired: " + parts.joined(separator: "; ") + ".")
        }
        info.append(contentsOf: rep.report.details.dropFirst())
        let r = rep.report
        if r.verified {
            a.messageText = rep.fixed.isEmpty ? "Disk verified" : "Disk repaired and verified"
        } else if r.runnable {
            a.messageText = "This disk has problems"
            info.append("To repair it, import it together with another dump (for example the original [b] or the [t +5 LFC] image) that has good copies of these tracks.")
        } else {
            a.messageText = "This disk can't be used"
            info.append(r.summary)
            info.append("The port runs the [cr 68 Darc] crack's main program. Import the Darc image (optionally together with the original [b] dump to repair tracks 77 and 127).")
            a.informativeText = info.joined(separator: "\n\n")
            a.addButton(withTitle: "OK")
            runModal(a); return false
        }
        a.informativeText = info.joined(separator: "\n\n")
        a.addButton(withTitle: r.verified ? "Use This Disk" : "Use Anyway")
        a.addButton(withTitle: "Cancel")
        guard runModal(a) == .alertFirstButtonReturn else { return false }
        guard let dest = AppDelegate.supportDiskURL else { return false }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(rep.data).write(to: dest, options: .atomic)
            let d = try Disk(data: rep.data); try d.validate()
            diskURL = dest
            start(d)
            AppServices.shared.toast("Disk installed")
            return true
        } catch {
            let e = NSAlert(); e.messageText = "Could not install the disk: \(error.localizedDescription)"; runModal(e); return false
        }
    }

    func showDiskHealth() {
        guard let u = diskURL, let d = try? [UInt8](Data(contentsOf: u)) else { return }
        let r = DiskHealth.check(d)
        let a = NSAlert()
        a.messageText = r.verified ? "Disk verified" : r.runnable ? "The disk has problems" : "The disk can't be used"
        a.informativeText = ([u.path, r.summary] + r.details).joined(separator: "\n\n")
        runModal(a)
    }

    func start(_ d: Disk) {
        host?.machine.stop()
        let h = GameHost(disk: d)
        host = h
        view.onKeyDown = { [weak self] c, rep, e in self?.handleKey(c, down: true, isRepeat: rep, event: e) }
        view.onKeyUp = { [weak self] c, e in self?.handleKey(c, down: false, isRepeat: false, event: e) }
        view.onFlags = { [weak h] c, f in h?.inputManager.modifierChanged(c, flags: f) }
        h.inputManager.padButtonSink = { [weak self] b, down in self?.handlePad(b, down: down) ?? false }
        h.inputManager.onControllerChange = { [weak self] connected, _ in self?.controllerChanged(connected: connected) }
        h.inputManager.hostPadButtons = Prefs.bool(BuiltinPrefs.ffPad) ? [.l3] : []
        Prefs.observe(BuiltinPrefs.ffPad) { [weak h] in h?.inputManager.hostPadButtons = Prefs.bool(BuiltinPrefs.ffPad) ? [.l3] : [] }
        AppServices.shared.dispatchHostReady(h)
    }

    // MARK: input routing
    private static let escKey: UInt16 = 0x35, backquoteKey: UInt16 = 0x32

    /// Every key event of the game view: modal overlay first, then host hotkeys, then the game.
    func handleKey(_ code: UInt16, down: Bool, isRepeat: Bool, event: NSEvent?) {
        guard let h = host else { return }
        if AppServices.shared.overlay.modalPanel != nil {
            if !isRepeat || [0x7e, 0x7d].contains(code) { _ = AppServices.shared.overlay.handleKey(code, down: down, event: event) }
            if !down { h.inputManager.keyUp(code, event: event) }   // keep physical key state right
            return
        }
        if code == AppDelegate.escKey && Prefs.bool(BuiltinPrefs.escPauseMenu) {
            if down && !isRepeat { showPauseMenu() }
            return
        }
        if code == AppDelegate.backquoteKey && Prefs.bool(BuiltinPrefs.ffKey) {
            if !isRepeat { h.fastForwardHeld = down }
            return
        }
        for f in AppServices.shared.keyHooks where f(code, down, isRepeat) {
            if !down { h.inputManager.keyUp(code, event: event) }   // keep physical key state right
            return
        }
        if down { h.inputManager.keyDown(code, isRepeat: isRepeat, event: event) } else { h.inputManager.keyUp(code, event: event) }
    }

    /// Menu long-press timing (pause-menu mode).
    private var padMenuDownAt: CFTimeInterval?
    private var padMenuOpenedMenu = false

    /// Host-level controller buttons: modal overlay, fast-forward (L3), Menu long press. True = consumed.
    func handlePad(_ b: PadButton, down: Bool) -> Bool {
        guard let h = host else { return false }
        if b == .menu && !down, let t = padMenuDownAt {   // release of a press we took for long-press timing
            padMenuDownAt = nil
            if !padMenuOpenedMenu && CACurrentMediaTime() - t < 0.5 && AppServices.shared.overlay.modalPanel == nil { h.inputManager.tapPadMenu() }
            padMenuOpenedMenu = false
            return true
        }
        if AppServices.shared.overlay.handlePad(b, down: down) { return true }
        if b == .l3 && Prefs.bool(BuiltinPrefs.ffPad) { h.fastForwardHeld = down; return true }
        for f in AppServices.shared.padHooks where f(b, down) { return true }
        if b == .menu && down && Prefs.bool(BuiltinPrefs.padMenuHold) && !h.paused {
            padMenuDownAt = CACurrentMediaTime(); padMenuOpenedMenu = false
            return true
        }
        return false
    }

    private func checkPadMenuHold() {
        if let t = padMenuDownAt, !padMenuOpenedMenu, CACurrentMediaTime() - t >= 0.5 {
            padMenuOpenedMenu = true
            showPauseMenu()
        }
    }

    func showPauseMenu() {
        guard host != nil else { return }
        host?.fastForwardHeld = false
        pauseMenu.open()
    }
    func openPreferences(tab: PrefTab?) { PreferencesWindowController.shared.show(tab: tab) }

    // MARK: MTKViewDelegate
    func mtkView(_ v: MTKView, drawableSizeWillChange size: CGSize) {}
    var debugFrames = 0
    func draw(in v: MTKView) {
        debugScript?.step()
        if let h = host, h.tick() { renderer.upload(h.machine.chip); debugFrames += 1 }
        if debugScript == nil, let dir = ProcessInfo.processInfo.environment["PLATOON_DEBUG_CAPTURE"] {
            // debug: capture each filter mode once the title is up, then quit
            let marks = [(400, 0), (430, 1), (460, 2)]
            for (f, mode) in marks where debugFrames == f {
                renderer.filter = MetalRenderer.Filter(rawValue: mode)!; renderer.capturePath = "\(dir)/app_mode\(mode).png"; debugFrames += 1
            }
            if debugFrames > 500 { NSApp.terminate(nil) }
        }
        renderer.draw(in: v)
        updateOverlay()
    }

    private func updateOverlay() {
        let services = AppServices.shared
        let scale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 1
        let r = renderer.lastContentRect
        let pts = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
        services.overlay.setGeometry(gameRect: pts, crop: renderer.crop)
        checkPadMenuHold()
        pauseBadge.refresh(host: host, menuOpen: pauseMenu.isVisible)
        if let h = host {
            services.dispatchDisplay(h)
            services.overlay.update(FrameContext(host: h))
            let t = h.paused && !pauseMenu.isVisible ? "Platoon — Paused" : "Platoon"
            if window.title != t { window.title = t }
        } else {
            services.overlay.update(nil)
        }
    }

    // MARK: menus
    func buildMenu() {
        let main = NSMenu()
        func item(_ t: String, _ s: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = self; i.tag = tag; return i
        }
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Platoon", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Preferences…", #selector(showPreferences(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Platoon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Platoon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let gameItem = NSMenuItem(); main.addItem(gameItem)
        let game = NSMenu(title: "Game")
        game.addItem(item("Pause Menu (Esc)", #selector(openPauseMenu(_:))))
        game.addItem(item("Pause", #selector(togglePause(_:)), "p"))
        game.addItem(item("Reset", #selector(resetGame(_:)), "r"))
        game.addItem(item("Continue from Last Section", #selector(continueGame(_:)), "k"))
        game.addItem(item("Turbo (hold ` to fast-forward)", #selector(toggleTurbo(_:)), "t"))
        let startItem = NSMenuItem(title: "Start New Game At", action: nil, keyEquivalent: "")
        let startMenu = NSMenu()
        for (i, t) in ["The Jungle & Village", "The Tunnels & Flare", "The Jungle & Foxhole"].enumerated() {
            startMenu.addItem(item(t, #selector(startAtSection(_:)), tag: i))
        }
        startItem.submenu = startMenu
        game.addItem(startItem)
        let cheatItem = NSMenuItem(title: "Trainer", action: nil, keyEquivalent: "")
        let cheatMenu = NSMenu()
        cheatMenu.addItem(item("Infinite Ammo & Grenades", #selector(toggleCheat(_:)), tag: 0))
        cheatMenu.addItem(item("Infinite Morale", #selector(toggleCheat(_:)), tag: 1))
        cheatMenu.addItem(item("No Wounds (a hit costs nothing)", #selector(toggleCheat(_:)), tag: 2))
        cheatItem.submenu = cheatMenu
        game.addItem(cheatItem)
        game.addItem(.separator())
        game.addItem(item("In-game Pause (TAB)", #selector(sendAmigaKey(_:)), tag: 0x42))
        game.addItem(item("Cycle Music / Sound FX (F10)", #selector(sendAmigaKey(_:)), tag: 0x59))
        game.addItem(item("Abort to Title (DEL)", #selector(sendAmigaKey(_:)), tag: 0x46))
        game.addItem(.separator())
        game.addItem(item("Save Screenshot", #selector(saveScreenshot(_:)), "s"))
        game.addItem(.separator())
        game.addItem(item("Import Disk Image…", #selector(importDiskMenu(_:)), "o"))
        game.addItem(item("Check Disk…", #selector(checkDiskMenu(_:))))
        game.addItem(.separator())
        game.addItem(item("Controls & Bindings…", #selector(showControls(_:)), "/"))
        gameItem.submenu = game

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let vm = NSMenu(title: "View")
        for f in MetalRenderer.Filter.allCases { vm.addItem(item(f.title, #selector(setFilter(_:)), "\(f.rawValue + 1)", tag: f.rawValue)) }
        vm.addItem(.separator())
        vm.addItem(item("Correct Aspect Ratio", #selector(toggleAspect(_:))))
        vm.addItem(item("Integer Scaling", #selector(toggleInteger(_:))))
        vm.addItem(item("Show Overscan", #selector(toggleOverscan(_:))))
        vm.addItem(item("CRT Curvature", #selector(toggleCurvature(_:))))
        vm.addItem(.separator())
        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]; vm.addItem(fs)
        viewItem.submenu = vm

        let soundItem = NSMenuItem(); main.addItem(soundItem)
        let sm = NSMenu(title: "Sound")
        sm.addItem(item("A500 Low-pass Filter", #selector(toggleFilter(_:))))
        sm.addItem(item("Smooth Sample Interpolation", #selector(toggleInterp(_:))))
        sm.addItem(.separator())
        for (i, (t, v)) in [("Stereo: Amiga (hard)", 1.0), ("Stereo: Wide", 0.7), ("Stereo: Narrow", 0.4), ("Mono", 0.0)].enumerated() {
            let it = item(t, #selector(setSeparation(_:)), tag: i); it.representedObject = v; sm.addItem(it)
        }
        sm.addItem(.separator())
        for (i, v) in [1.0, 0.75, 0.5, 0.25, 0.0].enumerated() {
            let it = item(v == 0 ? "Mute" : "Volume \(Int(v * 100))%", #selector(setVolume(_:)), tag: i); it.representedObject = v; sm.addItem(it)
        }
        soundItem.submenu = sm

        let winItem = NSMenuItem(); main.addItem(winItem)
        let wm = NSMenu(title: "Window")
        wm.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        winItem.submenu = wm
        NSApp.windowsMenu = wm
        menusByTarget = [.app: appMenu, .game: game, .view: vm, .sound: sm, .window: wm]
        MenuRegistry.merge(MenuRegistry.all(AppServices.shared), into: main, menus: menusByTarget)
        NSApp.mainMenu = main
    }

    func applyVideoSettings() {
        let s = Settings.shared
        renderer.filter = MetalRenderer.Filter(rawValue: s.filter) ?? .sharp
        renderer.aspectCorrect = s.aspect; renderer.integerScale = s.integerScale
        renderer.showOverscan = s.overscan; renderer.curvature = s.curvature
        renderer.scanlineStrength = Float(s.scanlines)
        AppServices.shared.overlay.setNeedsLayout()
    }

    @objc func showPreferences(_ s: Any?) { openPreferences(tab: nil) }
    @objc func openPauseMenu(_ s: Any?) { showPauseMenu() }
    @objc func importDiskMenu(_ s: Any?) { importDiskInteractively() }
    @objc func checkDiskMenu(_ s: Any?) { showDiskHealth() }
    @objc func togglePause(_ s: Any?) {
        guard let h = host else { return }
        if h.paused { if pauseMenu.isVisible { pauseMenu.close() }; h.resumeAll() } else { h.pause(.user) }
    }
    @objc func resetGame(_ s: Any?) { host?.resumeAll(); pauseMenu.isVisible = false; host?.reset() }
    @objc func toggleTurbo(_ s: Any?) { host?.turbo.toggle() }
    @objc func toggleCheat(_ s: NSMenuItem) {
        let st = Settings.shared
        switch s.tag { case 0: st.cheatAmmo.toggle(); case 1: st.cheatMorale.toggle(); default: st.cheatInvulnerable.toggle() }
        PrefsModel.shared.bump()
    }
    @objc func startAtSection(_ s: NSMenuItem) { host?.resumeAll(); pauseMenu.isVisible = false; host?.reset(startSection: s.tag) }
    @objc func continueGame(_ s: Any?) {
        let st = Settings.shared
        guard st.continueSection > 0, let c = st.continueCarry else { return }
        host?.resumeAll(); pauseMenu.isVisible = false
        host?.reset(startSection: st.continueSection, carry: [UInt8](c))
    }
    @objc func sendAmigaKey(_ s: NSMenuItem) { host?.tapKey(UInt8(s.tag)) }
    @objc func saveScreenshot(_ s: Any?) {
        guard let h = host else { return }
        VideoCommands.saveScreenshot(h.machine.chip)     // M24: same PNG + file name; folder / clipboard prefs
    }
    /// Game ▸ Controls & Bindings… (⌘/) and the pause menu: the M7 window (Input/ControlsWindow.swift).
    @objc func showControls(_ s: Any?) { ControlsWindowController.shared.show() }
    @objc func setFilter(_ s: NSMenuItem) { Settings.shared.filter = s.tag; applyVideoSettings(); PrefsModel.shared.bump() }
    @objc func toggleAspect(_ s: Any?) { Settings.shared.aspect.toggle(); applyVideoSettings(); PrefsModel.shared.bump() }
    @objc func toggleInteger(_ s: Any?) { Settings.shared.integerScale.toggle(); applyVideoSettings(); PrefsModel.shared.bump() }
    @objc func toggleOverscan(_ s: Any?) { Settings.shared.overscan.toggle(); applyVideoSettings(); PrefsModel.shared.bump() }
    @objc func toggleCurvature(_ s: Any?) { Settings.shared.curvature.toggle(); applyVideoSettings(); PrefsModel.shared.bump() }
    @objc func toggleFilter(_ s: Any?) { Settings.shared.a500Filter.toggle(); host?.applyAudioSettings(); PrefsModel.shared.bump() }
    @objc func toggleInterp(_ s: Any?) { Settings.shared.interpolate.toggle(); host?.applyAudioSettings(); PrefsModel.shared.bump() }
    @objc func setSeparation(_ s: NSMenuItem) { Settings.shared.separation = s.representedObject as? Double ?? 0.7; host?.applyAudioSettings(); PrefsModel.shared.bump() }
    @objc func setVolume(_ s: NSMenuItem) { Settings.shared.volume = s.representedObject as? Double ?? 1; host?.applyAudioSettings(); PrefsModel.shared.bump() }

    @objc func validateMenuItem(_ m: NSMenuItem) -> Bool {
        let s = Settings.shared
        switch m.action {
        case #selector(setFilter(_:)): m.state = s.filter == m.tag ? .on : .off
        case #selector(toggleAspect(_:)): m.state = s.aspect ? .on : .off
        case #selector(toggleInteger(_:)): m.state = s.integerScale ? .on : .off
        case #selector(toggleOverscan(_:)): m.state = s.overscan ? .on : .off
        case #selector(toggleCurvature(_:)): m.state = s.curvature ? .on : .off
        case #selector(toggleFilter(_:)): m.state = s.a500Filter ? .on : .off
        case #selector(toggleInterp(_:)): m.state = s.interpolate ? .on : .off
        case #selector(setSeparation(_:)): m.state = abs(s.separation - (m.representedObject as? Double ?? -1)) < 0.01 ? .on : .off
        case #selector(setVolume(_:)): m.state = abs(s.volume - (m.representedObject as? Double ?? -1)) < 0.01 ? .on : .off
        case #selector(togglePause(_:)): m.state = host?.paused == true ? .on : .off
        case #selector(toggleTurbo(_:)): m.state = host?.turbo == true ? .on : .off
        case #selector(openPauseMenu(_:)): return host != nil
        case #selector(checkDiskMenu(_:)): return diskURL != nil
        case #selector(toggleCheat(_:)):
            let st = Settings.shared
            m.state = [st.cheatAmmo, st.cheatMorale, st.cheatInvulnerable][m.tag] ? .on : .off
        case #selector(continueGame(_:)):
            let n = Settings.shared.continueSection
            m.title = n == 1 ? "Continue from The Tunnels" : n == 2 ? "Continue from The Final Jungle" : "Continue from Last Section"
            return n > 0 && Settings.shared.continueCarry != nil
        default: break
        }
        return true
    }
}
