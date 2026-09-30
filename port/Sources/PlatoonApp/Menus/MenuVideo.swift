import AppKit
import PlatoonCore

// presentation: [presentation] agent — renderer, shaders, framing looks (S13 incl. the sniper cue, S14, S16, S17, M19, M20, M21, M24).
// Only the owner edits this file.
//  - `videoMenus`: View-menu items (CRT preset, backdrop, accessibility looks) and the M24 recording commands.
//  - `videoInstall`: starts VideoFX (per-frame effect state), the REC badge and the pause-menu recording item.

extension MenuRegistry {
    static func videoMenus(_ app: AppServices) -> [MenuContribution] {
        func choiceMenu(_ title: String, _ key: String, _ options: [(Int, String)]) -> NSMenuItem {
            ClosureMenuItem.submenu(title, options.map { v, t in
                ClosureMenuItem(t, state: { Prefs.int(key) == v }) { Prefs.set(key, v); PrefsModel.shared.bump() }
            })
        }
        func toggle(_ title: String, _ key: String, onValue: Int? = nil) -> NSMenuItem {
            if let v = onValue {
                return ClosureMenuItem(title, state: { Prefs.int(key) == v }) { Prefs.set(key, Prefs.int(key) == v ? 0 : v); PrefsModel.shared.bump() }
            }
            return ClosureMenuItem(title, state: { Prefs.bool(key) }) { Prefs.set(key, !Prefs.bool(key)); PrefsModel.shared.bump() }
        }
        let rec = ClosureMenuItem("Record Video", key: "r", mods: [.command, .option],
                                  state: { VideoRecorder.shared.kind == .movie },
                                  enabled: { app.host != nil && VideoRecorder.shared.kind != .gif },
                                  dynamicTitle: { VideoRecorder.shared.kind == .movie ? "Stop Recording Video" : "Record Video" }) {
            VideoCommands.toggle(.movie)
        }
        let gif = ClosureMenuItem("Record GIF", key: "g", mods: [.command, .option],
                                  state: { VideoRecorder.shared.kind == .gif },
                                  enabled: { app.host != nil && VideoRecorder.shared.kind != .movie },
                                  dynamicTitle: { VideoRecorder.shared.kind == .gif ? "Stop Recording GIF" : "Record GIF" }) {
            VideoCommands.toggle(.gif)
        }
        let copy = ClosureMenuItem("Copy Screenshot", key: "c", mods: [.command, .option], enabled: { app.host != nil }) {
            VideoCommands.copyScreenshot()
        }
        let reveal = ClosureMenuItem("Show Recordings in Finder") { VideoCommands.revealFolder() }
        return [
            MenuContribution(menu: .view, order: 50, items: [
                choiceMenu("CRT Look", VideoKeys.crtPreset, CRTPreset.allCases.map { ($0.rawValue, $0.shortTitle) }),
                toggle("Ambient Glow in the Side Bars", VideoKeys.backdrop, onValue: 1),
                choiceMenu("Screen Shake", VideoKeys.shake, [(0, "Off"), (1, "Subtle"), (2, "Strong")]),
            ]),
            MenuContribution(menu: .view, order: 51, items: [
                toggle("Brighten Night Scenes", VideoKeys.nightLift),
                toggle("Reduce Flashing", VideoKeys.reduceFlashing),
                toggle("Show Sniper Side (Final Jungle)", SniperCue.key),
                choiceMenu("Colour Vision", VideoKeys.colourVision, ColourVision.allCases.map { ($0.rawValue, $0.title) }),
                toggle("HUD Magnifier", VideoKeys.hudMagnifier, onValue: 1),
            ]),
            MenuContribution(menu: .view, order: 52, items: [rec, gif, copy, reveal]),
        ]
    }
}

extension FeatureHooks {
    static func videoInstall(_ app: AppServices) {
        VideoFX.shared.install(app)
        SniperCue.shared.install(app)
        // M24: the app's Game ▸ Save Screenshot (⌘S) goes through VideoCommands.saveScreenshot (same PNG and file
        // name as before; folder / clipboard from the prefs). No AppDelegate edit: the menu item is retargeted.
        if VideoMenuTarget.retargetScreenshotItems() == 0 {
            DispatchQueue.main.async { VideoMenuTarget.retargetScreenshotItems() }
        }
        let badge = RecordingBadgePanel()
        app.overlay.add(badge)
        app.addPauseMenuItem(PauseMenuItem(id: "presentation.record", title: {
            VideoRecorder.shared.isRecording ? "Stop Recording (\(VideoRecorder.shared.kind!.title))" : "Record Video"
        }, order: 250, isEnabled: { app.host != nil }, action: {
            VideoCommands.toggle(VideoRecorder.shared.kind ?? .movie)
            return true                                   // close the menu: recording starts with the game
        }))
    }
}

/// Target of the retargeted Save Screenshot menu item.
final class VideoMenuTarget: NSObject {
    static let shared = VideoMenuTarget()
    @objc func saveScreenshotM24(_ s: Any?) {
        guard let h = AppServices.shared.host else { return }
        VideoCommands.saveScreenshot(h.machine.chip)
    }
    /// Points every main-menu item whose action is `saveScreenshot:` at VideoCommands.saveScreenshot.
    @discardableResult
    static func retargetScreenshotItems(_ menu: NSMenu? = NSApp.mainMenu) -> Int {
        guard let menu else { return 0 }
        var n = 0
        for item in menu.items {
            if item.action == NSSelectorFromString("saveScreenshot:") {
                item.target = shared
                item.action = #selector(saveScreenshotM24(_:))
                n += 1
            }
            if let sub = item.submenu { n += retargetScreenshotItems(sub) }
        }
        return n
    }
}

/// M24 commands shared by the menus, the pause menu and tests (PLATOON_VIDEO_TEST).
enum VideoCommands {
    static func toggle(_ k: VideoRecorder.Kind) {
        let r = VideoRecorder.shared
        if r.isRecording {
            let secs = Int(r.seconds)
            r.stop { u, err in
                if let u { AppServices.shared.toast("\(k.title) saved: \(u.lastPathComponent) (\(secs) s)", seconds: 3) }
                else { AppServices.shared.toast("Recording failed: \(err ?? "?")", seconds: 4) }
            }
            return
        }
        guard let host = AppServices.shared.host, let renderer = AppServices.shared.app?.renderer else { return }
        VideoRecorder.shared.tapAudio(host.machine)
        if let err = r.start(k, crop: renderer.crop, sampleRate: host.machine.chip.paula.sampleRate) {
            AppServices.shared.toast(err, seconds: 4)
        } else {
            AppServices.shared.toast(k == .movie ? "Recording video (⌥⌘R to stop)" : "Recording GIF (⌥⌘G to stop)")
        }
    }

    /// The plain game picture (visible crop, lowres, PAL aspect not applied) as PNG.
    static func screenshotPNG(_ chip: Chipset, crop c: (x: Int, y: Int, w: Int, h: Int)) -> Data {
        ImageIO.png(width: c.w / 2, height: c.h) { x, y in chip.canvas[(c.y + y) * Chipset.canvasWidth + c.x + x * 2] }
    }

    /// ⌥⌘C: the plain game picture to the clipboard.
    static func copyScreenshot() {
        guard let host = AppServices.shared.host, let renderer = AppServices.shared.app?.renderer else { return }
        let png = screenshotPNG(host.machine.chip, crop: renderer.crop)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        AppServices.shared.toast("Screenshot copied")
    }

    /// M24: where ⌘S screenshots go (pref presentation.screenshot.folder; default the Desktop, as before).
    static var screenshotFolder: URL {
        if let d = ProcessInfo.processInfo.environment["PLATOON_SCREENSHOT_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let fm = FileManager.default
        switch Prefs.int(VideoKeys.screenshotFolder) {
        case 1: return VideoRecorder.folder
        case 2: return fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Platoon", isDirectory: true)
        default: return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }

    /// M24 ⌘S (for the app's Save Screenshot command): the full canvas PNG exactly as before (ImageIO.canvasPNG),
    /// saved to `screenshotFolder`, and also copied to the clipboard when presentation.screenshot.clipboard is on.
    /// Returns the file written.
    @discardableResult static func saveScreenshot(_ chip: Chipset) -> URL? {
        let png = ImageIO.canvasPNG(chip)
        let dir = screenshotFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(VideoRecorder.fileName("png"))
        do { try png.write(to: url) } catch { AppServices.shared.toast("Screenshot failed: \(error.localizedDescription)", seconds: 3); return nil }
        if Prefs.bool(VideoKeys.screenshotClipboard) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
        }
        return url
    }

    static func revealFolder() {
        let d = VideoRecorder.folder
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([d])
    }
}

/// "● REC 0:12" while recording (overlay: never in the recording itself).
final class RecordingBadgePanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")
    init() {
        let box = OverlayStyle.box()
        super.init(id: "presentation.recBadge", view: box, anchor: .game(.topLeft, inset: 10), zIndex: 400)
        label.font = OverlayStyle.font(13, .bold); label.textColor = NSColor(calibratedRed: 1, green: 0.35, blue: 0.3, alpha: 1)
        box.addSubview(label)
        box.isHidden = true
    }
    override func frame(in l: OverlayLayout) -> CGRect {
        let s = label.fittingSize
        preferredSize = CGSize(width: s.width + 20, height: s.height + 10)
        label.frame = CGRect(x: 10, y: 5, width: s.width, height: s.height)
        return super.frame(in: l)
    }
    override func update(_ ctx: FrameContext?) {
        let r = VideoRecorder.shared
        guard r.isRecording, Prefs.bool(VideoKeys.recordBadge) else { if isVisible { isVisible = false }; return }
        let s = Int(r.seconds)
        let t = "● REC \(r.kind == .gif ? "GIF " : "")\(s / 60):\(String(format: "%02d", s % 60))"
        if label.stringValue != t { label.stringValue = t; manager?.setNeedsLayout() }
        if !isVisible { isVisible = true }
    }
}
