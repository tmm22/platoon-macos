import AppKit
import AVFoundation
import ImageIO
import MetalKit
import PlatoonCore

// OWNER: [presentation]. Tests of the presentation features, run inside the app (they need Metal / AVFoundation).
//
//   PLATOON_VIDEO_TEST=DIR  offscreen renderer tests + recorder tests, results in DIR/report.txt (PASS/FAIL lines)
//                           and DIR/*.png, then the app quits. Input pictures: PLATOON_VIDEO_TEST_INPUT = a
//                           directory of canvas PNGs (384x290, the platoon-headless --shot-every / ⌘S format) or a
//                           comma list of files; `name=file` entries name them. Without it the title screen is used.
//   PLATOON_VIDEO_SCRIPT=FILE  app-level script ("WHEN command args", WHEN = emulated frame or +N displayed frames):
//                           record movie|gif, stop, copyshot, log TEXT, look k=v,... (Prefs overrides). The recorder
//                           checks every finished file (frames, size, audio, first frame against the canvas) and logs
//                           to $PLATOON_DEBUG_CAPTURE/video.log. Use with PLATOON_DEBUG_SCRIPT for resets / quitting.

enum VideoSelfTest {
    final class Report {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
            print("[videotest] \(lines.last!)")
        }
        func note(_ s: String) { lines.append("     \(s)"); print("[videotest] \(s)") }
    }

    /// A canvas-sized picture (0xAARRGGBB, Chipset.canvasWidth x canvasHeight).
    struct Canvas { var name: String; var px: [UInt32] }

    static func loadCanvas(_ path: String, name: String) -> Canvas? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var raw = [UInt32](repeating: 0, count: w * h)
        let ok: Bool = raw.withUnsafeMutableBytes { b in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var c = [UInt32](repeating: 0xff00_0000, count: Chipset.canvasWidth * Chipset.canvasHeight)
        let lowres = w * 2 <= Chipset.canvasWidth + 1
        for y in 0..<min(h, Chipset.canvasHeight) {
            for x in 0..<Chipset.canvasWidth {
                let sx = lowres ? x / 2 : x
                if sx < w { c[y * Chipset.canvasWidth + x] = raw[y * w + sx] | 0xff00_0000 }
            }
        }
        return Canvas(name: name, px: c)
    }

    static func inputs() -> [Canvas] {
        var out: [Canvas] = []
        let env = ProcessInfo.processInfo.environment["PLATOON_VIDEO_TEST_INPUT"] ?? ""
        var isDir: ObjCBool = false
        if !env.isEmpty, FileManager.default.fileExists(atPath: env, isDirectory: &isDir), isDir.boolValue {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: env)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
            for f in files { if let c = loadCanvas(env + "/" + f, name: String(f.dropLast(4))) { out.append(c) } }
        } else {
            for e in env.split(separator: ",") {
                let parts = e.split(separator: "=", maxSplits: 1).map(String.init)
                let path = parts.count == 2 ? parts[1] : parts[0]
                let name = parts.count == 2 ? parts[0] : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if let c = loadCanvas(path, name: name) { out.append(c) }
            }
        }
        if out.isEmpty, let chip = AppServices.shared.host?.machine.chip {
            out.append(Canvas(name: "live", px: Array(UnsafeBufferPointer(start: chip.canvas, count: Chipset.canvasWidth * Chipset.canvasHeight))))
        }
        return out
    }

    static func writePNG(_ px: [UInt32], _ w: Int, _ h: Int, _ path: String) {
        try? ImageIO.png(width: w, height: h) { x, y in px[y * w + x] }.write(to: URL(fileURLWithPath: path))
    }

    // MARK: runner

    static func run(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let r = Report()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: MTLCreateSystemDefaultDevice())
        guard let renderer = MetalRenderer(view: view) else {
            r.check("Metal renderer", false, "could not create"); finish(r, outDir); return
        }
        let pics = inputs()
        r.note("inputs: \(pics.map(\.name).joined(separator: ", "))")
        rendererTests(r, renderer, pics, outDir)
        recorderTests(r, pics, outDir) { finish(r, outDir) }
    }

    private static func finish(_ r: Report, _ dir: String) {
        r.lines.append(r.failures == 0 ? "ALL PASS" : "\(r.failures) FAILED")
        try? (r.lines.joined(separator: "\n") + "\n").write(toFile: dir + "/report.txt", atomically: true, encoding: .utf8)
        print("[videotest] done: \(r.failures) failures")
        if ProcessInfo.processInfo.environment["PLATOON_VIDEO_TEST_STAY"] == nil { NSApp.terminate(nil) }
    }

    // MARK: renderer

    struct Config {
        var name: String
        var filter: MetalRenderer.Filter = .sharp
        var look = VideoLook()
        var fx = VideoFrameState()
        var aspect = true, integer = false, overscan = false
        var scanlines: Float = 0.35, curvature = true
    }

    static func apply(_ c: Config, _ r: MetalRenderer) {
        r.filter = c.filter; r.look = c.look; r.fx = c.fx
        r.aspectCorrect = c.aspect; r.integerScale = c.integer; r.showOverscan = c.overscan
        r.scanlineStrength = c.scanlines; r.curvature = c.curvature
    }

    static func render(_ r: MetalRenderer, _ pic: Canvas, _ c: Config, _ w: Int, _ h: Int, frames: Int = 1) -> [UInt32] {
        apply(c, r)
        pic.px.withUnsafeBufferPointer { r.upload(pixels: $0.baseAddress!) }
        return r.renderOffscreen(width: w, height: h, frames: frames) ?? []
    }

    static func look(_ f: (inout VideoLook) -> Void) -> VideoLook { var l = VideoLook(); f(&l); return l }
    static func crt(_ p: CRTPreset) -> VideoLook { look { $0.crtPreset = p; $0.crt = CRTParams.preset(p, scanline: 0.35) } }

    /// Lowres crop pixels of a canvas (320 x 256 visible area).
    static func cropPixels(_ pic: Canvas, _ r: MetalRenderer) -> (px: [UInt32], w: Int, h: Int) {
        let c = r.crop, w = c.w / 2, h = c.h
        var o = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { o[y * w + x] = pic.px[(c.y + y) * Chipset.canvasWidth + c.x + x * 2] & 0xffffff } }
        return (o, w, h)
    }

    static func rendererTests(_ r: Report, _ rd: MetalRenderer, _ pics: [Canvas], _ dir: String) {
        guard let pic = pics.first else { r.check("renderer inputs", false, "no pictures"); return }
        let src = cropPixels(pic, rd)
        let palette = Set(src.px)

        // 1. sharp at an exact integer scale (aspect off, 4x -> 1280x1024) = nearest-neighbour upscale
        do {
            let out = render(rd, pic, Config(name: "sharp4x", aspect: false, integer: true), 1280, 1024)
            var bad = 0
            for y in 0..<1024 { for x in 0..<1280 where out[y * 1280 + x] & 0xffffff != src.px[(y / 4) * src.w + x / 4] { bad += 1 } }
            r.check("sharp 4x integer = nearest neighbour", bad == 0, "\(bad) differing pixels")
        }
        // 2. sharp at a non-integer scale (aspect on, 1920x1080): only pixels at cell edges may be blended
        do {
            let out = render(rd, pic, Config(name: "sharp1080"), 1920, 1080)
            let lay = rd.layout(drawableSize: CGSize(width: 1920, height: 1080)).game
            var inPal = 0, total = 0
            for y in Int(lay.minY)..<Int(lay.maxY) { for x in Int(lay.minX)..<Int(lay.maxX) {
                total += 1; if palette.contains(out[y * 1920 + x] & 0xffffff) { inPal += 1 } } }
            let frac = Double(inPal) / Double(max(1, total))
            // 4.22 x 4.22 output px per lowres px: blended fringe <= 1 px per edge -> >= ~(1-1/4.2)^2 = 58% exact even
            // for a picture made only of 1-px details; real pictures are far above
            r.check("sharp 1080p: exact Amiga colours", frac > 0.75, String(format: "%.1f%% of the game image", frac * 100))
            writePNG(out, 1920, 1080, dir + "/\(pic.name)_sharp_1080.png")
        }
        // 3. MMPX at an integer scale: only source colours (MMPX never invents colours), and it does change edges
        do {
            let c = Config(name: "mmpx", filter: .mmpx, aspect: false, integer: true)
            let out = render(rd, pic, c, 1280, 1024)
            var foreign = 0, differs = 0
            for y in 0..<1024 { for x in 0..<1280 {
                let p = out[y * 1280 + x] & 0xffffff
                if !palette.contains(p) { foreign += 1 }
                if p != src.px[(y / 4) * src.w + x / 4] { differs += 1 }
            } }
            r.check("MMPX: only source colours", foreign == 0, "\(foreign) pixels with other colours")
            r.check("MMPX: smooths edges", differs > 0, "\(differs) pixels differ from nearest neighbour")
            writePNG(out, 1280, 1024, dir + "/\(pic.name)_mmpx_4x.png")
        }
        // 4. colour vision
        do {
            let base = render(rd, pic, Config(name: "base", aspect: false, integer: true), 640, 512)
            var diffs: [String] = []
            for m in ColourVision.allCases where m != .off {
                let out = render(rd, pic, Config(name: "cvd", look: look { $0.colourVision = m }, aspect: false, integer: true), 640, 512)
                let changed = zip(out, base).filter { $0 != $1 }.count
                diffs.append("\(m):\(changed)")
                if m == .greyscale {
                    let grey = out.allSatisfy { p in let r8 = (p >> 16) & 255, g8 = (p >> 8) & 255, b8 = p & 255; return max(r8, g8, b8) - min(r8, g8, b8) <= 1 }
                    r.check("colour vision greyscale is grey", grey)
                }
                writePNG(out, 640, 512, dir + "/\(pic.name)_cvd_\(m.rawValue).png")
            }
            r.check("colour vision modes change the picture", !diffs.contains { $0.hasSuffix(":0") }, diffs.joined(separator: " "))
        }
        // 5. night lift (S16): game window rows brighter, black stays black, HUD rows unchanged
        do {
            var fx = VideoFrameState(); fx.night = 0.6
            let split = fx.splitCanvasY
            let base = render(rd, pic, Config(name: "base", aspect: false, integer: true), 320, 256)
            let out = render(rd, pic, Config(name: "night", fx: fx, aspect: false, integer: true), 320, 256)
            let splitRow = split - rd.crop.y
            var brighter = 0, darker = 0, blackKept = true, hudSame = true
            for y in 0..<256 { for x in 0..<320 {
                let a = base[y * 320 + x] & 0xffffff, b = out[y * 320 + x] & 0xffffff
                if y < splitRow {
                    let la = ((a >> 16) & 255) + ((a >> 8) & 255) + (a & 255), lb = ((b >> 16) & 255) + ((b >> 8) & 255) + (b & 255)
                    if lb > la { brighter += 1 } else if lb < la { darker += 1 }
                    if a == 0 && b != 0 { blackKept = false }
                } else if a != b { hudSame = false }
            } }
            r.check("night lift brightens the game window", brighter > 0 && darker == 0, "\(brighter) brighter, \(darker) darker")
            r.check("night lift keeps black", blackKept)
            r.check("night lift leaves the HUD alone", hudSame)
            writePNG(out, 320, 256, dir + "/\(pic.name)_night.png")
        }
        // 6. S17 display LUT: every top-palette colour mapped; HUD rows unchanged
        do {
            var lut = VideoFX.identityLUT
            for i in 0..<4096 { lut[i] = VideoFX.rgb(i >> 1 & 0x777) }          // halve every channel
            var fx = VideoFrameState(); fx.flashLUT = lut; fx.flashLUTGeneration = 99
            let out = render(rd, pic, Config(name: "lut", fx: fx, aspect: false, integer: true), 320, 256)
            let splitRow = fx.splitCanvasY - rd.crop.y
            var bad = 0
            for y in 0..<256 { for x in 0..<320 {
                let s = src.px[y * 320 + x], o = out[y * 320 + x] & 0xffffff
                let n = Int((s >> 20) & 15) << 8 | Int((s >> 12) & 15) << 4 | Int((s >> 4) & 15)
                let want = y < splitRow ? lut[n] & 0xffffff : s
                if o != want { bad += 1 }
            } }
            r.check("flash LUT maps the game window colours only", bad == 0, "\(bad) wrong pixels")
        }
        // 6b. S17 per-index mapping: a flash that collapses every colour to $f00 is shown by palette index from
        //     the reference frame (the last canvas before the flash)
        do {
            let splitRow = VideoFrameState().splitCanvasY - rd.crop.y
            func c12(_ p: UInt32) -> UInt16 { UInt16((p >> 20) & 15) << 8 | UInt16((p >> 12) & 15) << 4 | UInt16((p >> 4) & 15) }
            var refPal: [UInt16] = []
            for y in 0..<splitRow { for x in 0..<320 { let c = c12(src.px[y * 320 + x]); if !refPal.contains(c) && refPal.count < 16 { refPal.append(c) } } }
            let usable = refPal.count
            while refPal.count < 16 { refPal.append(0xfff) }
            let limited = refPal.map { ($0 >> 1) & 0x777 }
            var fxRef = VideoFrameState(); fxRef.refUpdate = true
            _ = render(rd, pic, Config(name: "ref", fx: fxRef, aspect: false, integer: true), 320, 256)
            var collapsed = pic
            let cy = rd.crop.y
            for y in 0..<(cy + splitRow) { for x in 0..<Chipset.canvasWidth { collapsed.px[y * Chipset.canvasWidth + x] = 0xffff_0000 } }
            var lut = VideoFX.identityLUT; lut[0xf00] = VideoFX.rgb(0x800)
            var fx = VideoFrameState(); fx.flashLUT = lut; fx.flashLUTGeneration = 100
            fx.flashPalettes = refPal + [UInt16](repeating: 0xf00, count: 16) + limited
            let out = render(rd, collapsed, Config(name: "idx", fx: fx, aspect: false, integer: true), 320, 256)
            var bad = 0, checked = 0
            for y in 0..<splitRow { for x in 0..<320 {
                let orig = c12(src.px[y * 320 + x])
                guard let i = refPal.firstIndex(of: orig), i < usable else { continue }
                checked += 1
                if out[y * 320 + x] & 0xffffff != VideoFX.rgb(Int(limited[i])) & 0xffffff { bad += 1 }
            } }
            r.check("flash limiter keeps the picture when the palette collapses", bad == 0 && checked > 0,
                    "\(bad) wrong of \(checked) (\(usable) colours)")
            writePNG(out, 320, 256, dir + "/\(pic.name)_flashindex.png")
        }
        // 7. backdrop (S14): bars black by default, lit when on
        do {
            let off = render(rd, pic, Config(name: "bars"), 1920, 1080)
            let on = render(rd, pic, Config(name: "glow", look: look { $0.backdrop = 1; $0.backdropBrightness = 0.6 }), 1920, 1080, frames: 30)
            let lay = rd.layout(drawableSize: CGSize(width: 1920, height: 1080)).game
            func barSum(_ px: [UInt32]) -> Int {
                var s = 0
                for y in stride(from: 0, to: 1080, by: 7) { for x in stride(from: 0, to: Int(lay.minX) - 2, by: 5) {
                    let p = px[y * 1920 + x]
                    let r8 = Int((p >> 16) & 255), g8 = Int((p >> 8) & 255), b8 = Int(p & 255)
                    s += r8 + g8 + b8 } }
                return s
            }
            r.check("side bars black by default", barSum(off) == 0)
            r.check("ambient backdrop lights the side bars", barSum(on) > 0, "sum \(barSum(on))")
            var gameDiffs = 0
            // (the black border columns of the crop, 16 px each side, get the glow too: check the window between)
            let lowScale = lay.width / 320
            let x0 = Int(lay.minX + 16 * lowScale) + 2, x1 = Int(lay.maxX - 16 * lowScale) - 2
            for y in Int(lay.minY)..<Int(lay.maxY) { for x in x0..<x1 where on[y * 1920 + x] != off[y * 1920 + x] { gameDiffs += 1 } }
            let sameGame = gameDiffs == 0
            r.check("backdrop doesn't touch the game window", sameGame, "\(gameDiffs) differing pixels")
            var borderLit = 0
            for y in stride(from: Int(lay.minY), to: Int(lay.maxY), by: 5) { for x in Int(lay.minX)..<(x0 - 4) where on[y * 1920 + x] & 0xffffff != 0 { borderLit += 1 } }
            r.check("backdrop reaches into the black border columns", borderLit > 0, "\(borderLit) lit samples")
            writePNG(on, 1920, 1080, dir + "/\(pic.name)_backdrop_1080.png")
        }
        // 8. shake (S13): the image moves by whole lowres pixels
        do {
            var fx = VideoFrameState(); fx.shake = (2, -1)
            let base = render(rd, pic, Config(name: "base", aspect: false, integer: true), 1280, 1024)
            let out = render(rd, pic, Config(name: "shake", fx: fx, aspect: false, integer: true), 1280, 1024)
            var bad = 0
            for y in 8..<1000 { for x in 16..<1260 where out[y * 1280 + x] != base[(y + 4) * 1280 + x - 8] { bad += 1 } }
            r.check("shake moves the picture (2, -1) lowres px", bad == 0, "\(bad) differing pixels")
        }
        // 9. HUD magnifier (M21)
        do {
            let l = look { $0.hudMagnifier = true; $0.hudMagnification = 2 }
            let out = render(rd, pic, Config(name: "mag", look: l), 1920, 1080)
            let lay = rd.layout(drawableSize: CGSize(width: 1920, height: 1080))
            r.check("HUD magnifier strip below the picture", lay.magnifier.map { $0.minY >= lay.game.maxY - 0.5 && $0.maxY <= 1080.5 } ?? false,
                    "\(lay.game) \(lay.magnifier.map { "\($0)" } ?? "nil")")
            writePNG(out, 1920, 1080, dir + "/\(pic.name)_magnifier_1080.png")
        }
        // 10. L4 side columns: composited beside the game window, fog towards the outer edge
        do {
            let cols = SideColumnCompositor.shared
            let saved = cols.current, savedReserve = cols.reservedWidth
            cols.reservedWidth = 64
            _ = render(rd, pic, Config(name: "cols"), 1920, 1080)         // (sets the geometry)
            let room = cols.room(leftEdge: 33, rightEdge: 337)
            let w = min(64, room.left), wr = min(64, room.right)
            let lines = 144
            cols.submit(SideColumnFrame(width: w, rightWidth: wr, firstLine: 36, lines: lines, leftEdge: 33, rightEdge: 337,
                                        left: [UInt32](repeating: 0xff00_ff00, count: w * lines),
                                        right: [UInt32](repeating: 0xffff_0000, count: wr * lines), fog: 0.5))
            let out = render(rd, pic, Config(name: "cols"), 1920, 1080)
            let lay = rd.layout(drawableSize: CGSize(width: 1920, height: 1080))
            let yMid = Int(lay.game.minY + (Double(36 - rd.crop.y) + 72) * lay.scaleY)
            let xl = Int(lay.game.minX + (Double(33 - rd.crop.x / 2) - 4) * lay.scaleX)
            let xr = Int(lay.game.minX + (Double(337 - rd.crop.x / 2) + 4) * lay.scaleX)
            let pl = out[yMid * 1920 + xl], pr = out[yMid * 1920 + xr]
            r.check("side columns: room reserved", room.left >= 64 && room.right >= 64, "room \(room)")
            r.check("side columns drawn (left green, right red)", (pl >> 8) & 255 > 200 && (pl >> 16) & 255 < 40 && (pr >> 16) & 255 > 200 && (pr >> 8) & 255 < 40,
                    String(format: "left %08x right %08x", pl, pr))
            let xo = Int(lay.game.minX + (Double(33 - rd.crop.x / 2) - Double(w) + 1) * lay.scaleX)
            r.check("side columns fade towards the outer edge", (out[yMid * 1920 + xo] >> 8) & 255 < (pl >> 8) & 255,
                    String(format: "outer %08x", out[yMid * 1920 + xo]))
            writePNG(out, 1920, 1080, dir + "/\(pic.name)_columns_1080.png")
            cols.reservedWidth = savedReserve
            if let s = saved { cols.submit(s) } else { cols.clear() }
        }
        // 11. looks for visual review: every filter / CRT preset at three output sizes
        for pic in pics {
            for (w, h) in [(1920, 1080), (2560, 1440), (3840, 2160)] {
                var configs: [Config] = [Config(name: "sharp"), Config(name: "smooth", filter: .smooth), Config(name: "mmpx", filter: .mmpx)]
                for p in CRTPreset.allCases where p != .custom { configs.append(Config(name: "crt-\(p.shortTitle)", filter: .crt, look: crt(p))) }
                var nfx = VideoFrameState(); nfx.night = 0.5
                configs.append(Config(name: "night50", fx: nfx))
                nfx.night = 1
                configs.append(Config(name: "night100", fx: nfx))
                configs.append(Config(name: "backdrop", look: look { $0.backdrop = 1 }))
                if w != 2560 { configs = configs.filter { $0.name.hasPrefix("crt") || w == 1920 } }
                if w != 1920 { configs = configs.filter { !$0.name.hasPrefix("night") && $0.name != "backdrop" } }
                for c in configs {
                    let out = render(rd, pic, c, w, h, frames: 3)
                    writePNG(out, w, h, dir + "/look_\(pic.name)_\(c.name)_\(h)p.png")
                    // centre crop, 3x nearest, for looking at details
                    let cw = 320, ch = 200, s = 3
                    var z = [UInt32](repeating: 0, count: cw * s * ch * s)
                    for y in 0..<(ch * s) { for x in 0..<(cw * s) { z[y * cw * s + x] = out[(h / 2 - ch / 2 + y / s) * w + w / 2 - cw / 2 + x / s] } }
                    writePNG(z, cw * s, ch * s, dir + "/zoom_\(pic.name)_\(c.name)_\(h)p.png")
                }
            }
        }
        apply(Config(name: "reset"), rd)
    }

    // MARK: recorder

    static func recorderTests(_ r: Report, _ pics: [Canvas], _ dir: String, done: @escaping () -> Void) {
        guard !pics.isEmpty else { done(); return }
        let crop = (x: (0x71 - Chipset.canvasH0) * 2, y: 0x2c - Chipset.canvasV0, w: 640, h: 256)
        let n = max(60, pics.count * 3)
        // GIF: frames = the pictures in turn (3 frames each), 50 fps
        let gifURL = URL(fileURLWithPath: dir + "/test.gif")
        if let g = GIFWriter(url: gifURL, width: 320, height: 256) {
            for i in 0..<n {
                let p = pics[(i / 3) % pics.count]
                var px = [UInt32](repeating: 0, count: 320 * 256)
                for y in 0..<256 { for x in 0..<320 { px[y * 320 + x] = p.px[(crop.y + y) * Chipset.canvasWidth + crop.x + x * 2] } }
                g.add(px, delay: 2)
            }
            g.finish()
            if let src = CGImageSourceCreateWithURL(gifURL as CFURL, nil) {
                let count = CGImageSourceGetCount(src)
                // identical consecutive frames are merged: expect one frame per picture change
                let distinct = (0..<n).map { (($0 / 3) % pics.count) }.enumerated().filter { $0.offset == 0 || (($0.offset / 3) % pics.count) != ((($0.offset - 1) / 3) % pics.count) }.count
                r.check("GIF decodes", count > 0 && count <= n, "\(count) frames for \(n) (\(distinct) changes)")
                var total = 0.0
                for i in 0..<count {
                    if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                       let gp = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                       let d = gp[kCGImagePropertyGIFUnclampedDelayTime] as? Double { total += d }
                }
                r.check("GIF duration = frames / 50", abs(total - Double(n) / 50) < 0.03, String(format: "%.2f s", total))
                if let last = CGImageSourceCreateImageAtIndex(src, count - 1, nil) {
                    let exp = pics[((n - 1) / 3) % pics.count]
                    let got = pixels(last)
                    var bad = 0
                    for y in 0..<256 { for x in 0..<320 where got[y * 320 + x] & 0xffffff != exp.px[(crop.y + y) * Chipset.canvasWidth + crop.x + x * 2] & 0xffffff { bad += 1 } }
                    r.check("GIF last frame exact (delta frames composited)", bad == 0, "\(bad) differing pixels")
                }
            } else { r.check("GIF decodes", false) }
        } else { r.check("GIF writer", false) }

        // movie: n frames + a 440 Hz tone
        let movURL = URL(fileURLWithPath: dir + "/test.mov")
        try? FileManager.default.removeItem(at: movURL)
        let rate = 48000.0
        do {
            let m = try MovieWriter(url: movURL, lowWidth: 320, height: 256, scale: 2, palAspect: true, sampleRate: rate)
            var phase = 0.0
            let canvases = pics.map { $0.px }
            for i in 0..<n {
                var a = [Float](repeating: 0, count: Int(rate / 50) * 2)
                for k in 0..<(a.count / 2) { let v = Float(sin(phase) * 0.3); a[2 * k] = v; a[2 * k + 1] = v; phase += 2 * .pi * 440 / rate }
                var c = canvases[(i / 3) % canvases.count]
                c.withUnsafeMutableBufferPointer { m.append(canvas: $0.baseAddress!, crop: crop, audio: a) }
                usleep(2000)                       // (real time: the writer's inputs want a steady pace)
            }
            m.finish { err in
                DispatchQueue.main.async {
                    r.check("movie written", err == nil, err ?? "")
                    verifyMovie(r, movURL, frames: n, width: 640, height: 512, first: canvases[0], crop: crop) { done() }
                }
            }
        } catch {
            r.check("movie writer", false, "\(error)")
            done()
        }
    }

    static func pixels(_ img: CGImage) -> [UInt32] {
        let w = img.width, h = img.height
        var raw = [UInt32](repeating: 0, count: w * h)
        raw.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return raw
    }

    /// Reads a finished recording back: frame count, size, audio track and the first frame against its canvas
    /// (H.264 is lossy: mean channel error must be small). Logs to `r`.
    static func verifyMovie(_ r: Report, _ url: URL, frames: Int?, width: Int, height: Int, first: [UInt32]?,
                            crop: (x: Int, y: Int, w: Int, h: Int), done: @escaping () -> Void) {
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let vt = try await asset.loadTracks(withMediaType: .video)
                let at = try await asset.loadTracks(withMediaType: .audio)
                let dur = try await asset.load(.duration).seconds
                var size = CGSize.zero
                if let v = vt.first {
                    // natural size includes the PAL pixel-aspect tag (16:15): the encoded size is in the format
                    if let f = try await v.load(.formatDescriptions).first {
                        let d = CMVideoFormatDescriptionGetDimensions(f)
                        size = CGSize(width: Int(d.width), height: Int(d.height))
                    }
                    let ns = try await v.load(.naturalSize)
                    r.note("movie natural size \(ns) (display aspect \(String(format: "%.3f", ns.width / max(1, ns.height))))")
                }
                var count = 0
                var firstErr = -1.0
                if let v = vt.first {
                    let reader = try AVAssetReader(asset: asset)
                    let out = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    reader.add(out)
                    reader.startReading()
                    while let sb = out.copyNextSampleBuffer() {
                        if count == 0, let first, let pb = CMSampleBufferGetImageBuffer(sb) {
                            CVPixelBufferLockBaseAddress(pb, .readOnly)
                            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
                            let bpr = CVPixelBufferGetBytesPerRow(pb) / 4
                            let sx = CVPixelBufferGetWidth(pb) / (crop.w / 2), sy = CVPixelBufferGetHeight(pb) / crop.h
                            var err = 0.0, n = 0
                            for y in stride(from: 0, to: crop.h, by: 2) { for x in stride(from: 0, to: crop.w / 2, by: 2) {
                                let a = first[(crop.y + y) * Chipset.canvasWidth + crop.x + x * 2]
                                let b = base[(y * sy + sy / 2) * bpr + x * sx + sx / 2]
                                for s in [0, 8, 16] { err += abs(Double(Int((a >> s) & 255) - Int((b >> s) & 255))) }
                                n += 3
                            } }
                            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                            firstErr = err / Double(max(1, n))
                        }
                        count += 1
                    }
                }
                let count0 = count, size0 = size, err0 = firstErr, dur0 = dur, hasAudio = !at.isEmpty
                await MainActor.run {
                    let count = count0, size = size0, firstErr = err0, dur = dur0
                    if let frames {
                        r.check("movie: \(frames) video frames", count == frames, "\(count) frames, \(String(format: "%.2f", dur)) s")
                        r.check("movie duration = frames / 50", abs(dur - Double(frames) / 50) < 0.05, String(format: "%.3f s", dur))
                    } else { r.note("movie: \(count) frames, \(String(format: "%.2f", dur)) s") }
                    r.check("movie size \(width)x\(height)", Int(size.width) == width && Int(size.height) == height, "\(size)")
                    r.check("movie has an audio track", hasAudio)
                    if first != nil { r.check("movie first frame matches the canvas", firstErr >= 0 && firstErr < 12, String(format: "mean error %.2f / 255", firstErr)) }
                    done()
                }
            } catch {
                await MainActor.run { r.check("movie readable", false, "\(error)"); done() }
            }
        }
    }
}

/// PLATOON_VIDEO_SCRIPT (see the top of this file).
final class VideoScript {
    private enum When { case frame(UInt64), after(Int) }
    private var lines: [(When, [String])]
    private var since = 0
    private let dir: String
    private var log: FileHandle?
    private var firstCanvas: [UInt32]?
    private var recordingFrames0 = 0

    init?(path: String?) {
        guard let p = path, let text = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        lines = text.split(separator: "\n").compactMap { l in
            let a = l.split(separator: " ").map(String.init)
            guard a.count >= 2, !a[0].hasPrefix("#") else { return nil }
            if a[0].hasPrefix("+"), let n = Int(a[0].dropFirst()) { return (.after(n), Array(a.dropFirst())) }
            guard let f = UInt64(a[0]) else { return nil }
            return (.frame(f), Array(a.dropFirst()))
        }
        dir = ProcessInfo.processInfo.environment["PLATOON_DEBUG_CAPTURE"] ?? "/tmp/platoon-debug"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/video.log", contents: nil)
        log = FileHandle(forWritingAtPath: dir + "/video.log")
    }

    func write(_ s: String) { log?.write((s + "\n").data(using: .utf8)!); print("[video] " + s) }

    /// Every displayed frame.
    func step(_ ctx: FrameContext) {
        since += 1
        while let (w, cmd) = lines.first {
            switch w {
            case .frame(let f): if ctx.frame < f { return }
            case .after(let n): if since < n { return }
            }
            lines.removeFirst(); since = 0
            run(cmd, ctx)
        }
    }

    /// The canvas of the first recorded frame (checked against the file's first frame).
    func noteFirstFrame(_ chip: Chipset) {
        guard firstCanvas == nil else { return }
        firstCanvas = Array(UnsafeBufferPointer(start: chip.canvas, count: Chipset.canvasWidth * Chipset.canvasHeight))
    }

    private func run(_ a: [String], _ ctx: FrameContext) {
        let arg = a.count > 1 ? a[1] : ""
        switch a[0] {
        case "record":
            firstCanvas = nil
            let k: VideoRecorder.Kind = arg == "gif" ? .gif : .movie
            VideoCommands.toggle(k)
            write("record \(arg) at f\(ctx.frame): recording=\(VideoRecorder.shared.isRecording) file=\(VideoRecorder.shared.url?.path ?? "-")")
        case "stop":
            let rec = VideoRecorder.shared
            let kind = rec.kind, frames = rec.framesRecorded, first = firstCanvas
            let crop = AppServices.shared.app?.renderer.crop ?? (x: 34, y: 20, w: 640, h: 256)
            write("stop at f\(ctx.frame): \(frames) frames")
            rec.stop { [weak self] url, err in
                guard let self else { return }
                self.write("stopped: \(url?.path ?? "-") \(err ?? "ok")")
                guard let url else { return }
                if kind == .movie {
                    let r = VideoSelfTest.Report()
                    let scale = max(1, min(4, Prefs.int(VideoKeys.recordScale)))
                    VideoSelfTest.verifyMovie(r, url, frames: frames, width: crop.w / 2 * scale, height: crop.h * scale, first: first, crop: crop) {
                        r.lines.forEach { self.write($0) }
                    }
                } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    var total = 0.0
                    for i in 0..<CGImageSourceGetCount(src) {
                        if let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                           let g = p[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                           let d = g[kCGImagePropertyGIFUnclampedDelayTime] as? Double { total += d }
                    }
                    self.write(String(format: "gif: %d images, %.2f s (%d recorded frames = %.2f s)", CGImageSourceGetCount(src), total, frames, Double(frames) / 50))
                }
            }
        case "copyshot":
            VideoCommands.copyScreenshot()
            let ok = NSPasteboard.general.data(forType: .png) != nil
            write("copyshot: clipboard png=\(ok)")
        case "look":
            Prefs.applyOverrides(a.dropFirst().joined(separator: " "))
            PrefsModel.shared.bump()
            VideoFX.shared.reloadLook()
            write("look \(arg)")
        case "log":
            let g = ctx.game
            let r = AppServices.shared.app?.renderer
            write("f\(ctx.frame) \(a.dropFirst().joined(separator: " ")): screen=\(g.screen) area=\(g.area) section=\(g.loadedSection) "
                  + "night=\(r?.fx.night ?? -1) lut=\(r?.fx.flashLUT != nil) shake=\(r.map { "\($0.fx.shake)" } ?? "-") split=\(r?.fx.splitCanvasY ?? -1)")
        default: write("unknown command \(a[0])")
        }
    }
}
