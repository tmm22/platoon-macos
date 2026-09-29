import AppKit
import MetalKit
import UniformTypeIdentifiers
import PlatoonCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, MTKViewDelegate {
    var window: NSWindow!
    var view: GameView!
    var renderer: MetalRenderer!
    var host: GameHost?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Platoon"
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 320, height: 256)
        view = GameView(frame: frame, device: MTLCreateSystemDefaultDevice())
        view.preferredFramesPerSecond = 120
        guard let r = MetalRenderer(view: view) else { fatalError("Metal is required") }
        renderer = r
        view.delegate = self
        window.contentView = view
        window.center()
        window.setFrameAutosaveName("PlatoonMain")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        applyVideoSettings()
        NSApp.activate(ignoringOtherApps: true)
        loadDisk()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func windowDidResignKey(_ n: Notification) { host?.inputManager.releaseAll() }

    // MARK: disk
    func loadDisk() {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "Platoon", withExtension: "adf") { candidates.append(u) }
        if let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(sup.appendingPathComponent("Platoon/Platoon.adf"))
        }
        if let bm = Settings.shared.adfBookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, options: .withSecurityScope, bookmarkDataIsStale: &stale) { _ = u.startAccessingSecurityScopedResource(); candidates.append(u) }
        }
        for u in candidates { if let d = try? Disk(contentsOf: u), (try? d.validate()) != nil { start(d); return } }
        let alert = NSAlert()
        alert.messageText = "Locate your Platoon disk image"
        alert.informativeText = "Platoon needs the original Amiga disk (an .adf file) to run. Please select it."
        alert.addButton(withTitle: "Choose…"); alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "adf") ?? .data]
        guard panel.runModal() == .OK, let u = panel.url else { NSApp.terminate(nil); return }
        do {
            let d = try Disk(contentsOf: u); try d.validate()
            Settings.shared.adfBookmark = try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            start(d)
        } catch {
            let a = NSAlert(); a.messageText = "That is not a supported Platoon disk image."; a.runModal(); loadDisk()
        }
    }

    func start(_ d: Disk) {
        let h = GameHost(disk: d)
        host = h
        view.onKeyDown = { [weak self] c, rep in self?.handleKey(c, rep) }
        view.onKeyUp = { [weak h] c in h?.inputManager.keyUp(c) }
    }

    func handleKey(_ code: UInt16, _ rep: Bool) {
        guard let h = host else { return }
        h.inputManager.keyDown(code, isRepeat: rep)
    }

    // MARK: MTKViewDelegate
    func mtkView(_ v: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in v: MTKView) {
        if let h = host, h.tick() { renderer.upload(h.machine.chip) }
        renderer.draw(in: v)
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
        appMenu.addItem(NSMenuItem(title: "Hide Platoon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Platoon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let gameItem = NSMenuItem(); main.addItem(gameItem)
        let game = NSMenu(title: "Game")
        game.addItem(item("Pause", #selector(togglePause(_:)), "p"))
        game.addItem(item("Reset", #selector(resetGame(_:)), "r"))
        game.addItem(item("Turbo Speed", #selector(toggleTurbo(_:)), "t"))
        game.addItem(.separator())
        game.addItem(item("In-game Pause (TAB)", #selector(sendAmigaKey(_:)), tag: 0x42))
        game.addItem(item("Cycle Music / Sound FX (F10)", #selector(sendAmigaKey(_:)), tag: 0x59))
        game.addItem(item("Abort to Title (DEL)", #selector(sendAmigaKey(_:)), tag: 0x46))
        game.addItem(.separator())
        game.addItem(item("Save Screenshot", #selector(saveScreenshot(_:)), "s"))
        game.addItem(.separator())
        game.addItem(item("Controls…", #selector(showControls(_:)), "/"))
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
        NSApp.mainMenu = main
    }

    func applyVideoSettings() {
        let s = Settings.shared
        renderer.filter = MetalRenderer.Filter(rawValue: s.filter) ?? .sharp
        renderer.aspectCorrect = s.aspect; renderer.integerScale = s.integerScale
        renderer.showOverscan = s.overscan; renderer.curvature = s.curvature
        renderer.scanlineStrength = Float(s.scanlines)
    }

    @objc func togglePause(_ s: Any?) { host?.paused.toggle(); window.title = host?.paused == true ? "Platoon — Paused" : "Platoon" }
    @objc func resetGame(_ s: Any?) { host?.reset() }
    @objc func toggleTurbo(_ s: Any?) { host?.turbo.toggle() }
    @objc func sendAmigaKey(_ s: NSMenuItem) { host?.tapKey(UInt8(s.tag)) }
    @objc func saveScreenshot(_ s: Any?) {
        guard let h = host else { return }
        let png = ImageIO.canvasPNG(h.machine.chip)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        try? png.write(to: dir.appendingPathComponent("Platoon \(f.string(from: Date())).png"))
    }
    @objc func showControls(_ s: Any?) {
        let a = NSAlert()
        a.messageText = "Platoon Controls"
        a.informativeText = """
        Joystick: arrow keys (or a game controller's d-pad / left stick)
        Fire: Space or Z (controller A / B / right trigger)

        TAB — pause the game (press again to resume)
        F10 — cycle music / sound effects
        DEL — abort to the title screen
        Letters/Return — name entry on the high-score table

        ⌘P pause emulation · ⌘T turbo speed · ⌘R reset · ⌘S screenshot
        ⌘1/⌘2/⌘3 sharp / smooth / CRT display · ⌃⌘F full screen
        """
        a.runModal()
    }
    @objc func setFilter(_ s: NSMenuItem) { Settings.shared.filter = s.tag; applyVideoSettings() }
    @objc func toggleAspect(_ s: Any?) { Settings.shared.aspect.toggle(); applyVideoSettings() }
    @objc func toggleInteger(_ s: Any?) { Settings.shared.integerScale.toggle(); applyVideoSettings() }
    @objc func toggleOverscan(_ s: Any?) { Settings.shared.overscan.toggle(); applyVideoSettings() }
    @objc func toggleCurvature(_ s: Any?) { Settings.shared.curvature.toggle(); applyVideoSettings() }
    @objc func toggleFilter(_ s: Any?) { Settings.shared.a500Filter.toggle(); host?.applyAudioSettings() }
    @objc func toggleInterp(_ s: Any?) { Settings.shared.interpolate.toggle(); host?.applyAudioSettings() }
    @objc func setSeparation(_ s: NSMenuItem) { Settings.shared.separation = s.representedObject as? Double ?? 0.7; host?.applyAudioSettings() }
    @objc func setVolume(_ s: NSMenuItem) { Settings.shared.volume = s.representedObject as? Double ?? 1; host?.applyAudioSettings() }

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
        default: break
        }
        return true
    }
}
