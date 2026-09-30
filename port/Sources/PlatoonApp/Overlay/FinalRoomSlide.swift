import AppKit
import ImageIO
import PlatoonCore

// M25 final-jungle directional room slide (owner: section2). Presentation only, default off (pref
// "section2.roomSlide", Video tab). When you leave a final-jungle room the original fades the picture to black,
// decodes the next room (~12 frames) and switches the palette on instantly. With the slide on, an overlay covering
// the playfield (never in the canvas, the Metal drawable or ⌘S screenshots) instead pushes the old view out to the
// side you turned to while the new room slides in. Nothing in the game changes (read-only: RAM + the canvas).
//
// Timing (all in emulated frames, so fast-forward keeps it in step):
//  - start: the room/direction long changes to the exact trans_left/trans_right successor of the previous state
//    (room_setup, before the fade starts). Old image = the canvas playfield of the last displayed frame; new image
//    = the host rendering of the new room (FinalJungleRenderer: the game's picture decoder, bob cut and depth sort,
//    background + static objects + the player at the entry), available at once.
//  - the slide takes `section2.roomSlideFrames` frames (default 12) and then holds the new room, so it always ends
//    before the game sets the palette (fade <= 16 frames + decode);
//  - end: once the game has set its palette again and swapped in the first drawn buffer of the new room, the
//    overlay is removed and the game's own picture (identical apart from what moved) shows again.

final class FinalRoomSlidePanel: OverlayPanel {
    private let layerView = NSView()
    private enum Phase { case idle, sliding, waitSwap }
    private var phase = Phase.idle
    private var swapFrom: UInt32 = 0
    private var afterSwap = 0
    private var sawFade = false
    private var frames = 0
    private var total = 12
    private var right = true
    private var oldImg: [UInt32] = []
    private var newImg: [UInt32] = []
    private var oldCols = 0...319, newCols = 0...319
    private var lastState: FinalJungleMaze.State?
    private var dirty = false
    /// Frames in which the slide was visible (tests).
    private(set) var shownFrames = 0

    init() {
        super.init(id: "section2.roomSlide", view: layerView, anchor: .fillGame, zIndex: 5)
        layerView.wantsLayer = true
        layerView.layer?.magnificationFilter = .nearest
        layerView.layer?.contentsGravity = .resize
        view.isHidden = true
        anchor = .custom { l, _ in
            // playfield rows 0..143 = beam lines $3c..$cb (visible-screen y 16..159), x 0..319
            let a = l.point(x: 0, y: 16), b = l.point(x: 320, y: 160)
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
    }

    static var enabled: Bool { Prefs.bool("section2.roomSlide") }

    /// Every emulated frame (onFrame; game thread parked).
    func frame(_ ctx: FrameContext) {
        let g = ctx.game
        guard FinalRoomSlidePanel.enabled, g.inGame, g.loadedSection == 2, g.section == 2, g.screen == .playing else {
            if case .idle = phase {} else { stop() }
            lastState = nil
            return
        }
        let live = FinalJungleLive.read(ctx.memory)
        let st = live.state
        switch phase {
        case .idle:
            if let prev = lastState, prev != st {
                let maze = FinalJungleMaze(memory: ctx.memory)
                if maze.next(prev, .right) == st { start(ctx, right: true, maze: maze, from: prev, st: st) }
                else if maze.next(prev, .left) == st { start(ctx, right: false, maze: maze, from: prev, st: st) }
            }
        case .sliding:
            if frames < total { frames += 1; dirty = true }
            if live.transition { sawFade = true }
            // the game has set its palette again (fade over, picture decoded, playfield cleared): finish the slide
            if sawFade && !live.transition && live.topPalette == FinalJungleRenderer.paletteAddr {
                if frames < total { frames = total; dirty = true }
                phase = .waitSwap; swapFrom = live.backBuffer; afterSwap = 0
            }
        case .waitSwap:
            // the first buffer of the new room was swapped in: show the game again one frame later
            if afterSwap > 0 || live.backBuffer != swapFrom { afterSwap += 1 }
            // (and only once the canvas really shows a picture again, never a black frame)
            if afterSwap >= 2 && FinalRoomSlidePanel.canvasShowsPicture(ctx.machine.chip) { stop() }
        }
        if case .idle = phase {} else {
            shownFrames += 1
            if shownFrames > 400 { stop() }             // safety: never cover the game for long
        }
        lastState = st
        dump(ctx, live)
    }

    private func start(_ ctx: FrameContext, right: Bool, maze: FinalJungleMaze, from prev: FinalJungleMaze.State,
                       st: FinalJungleMaze.State) {
        oldImg = FinalRoomSlidePanel.canvasPlayfield(ctx.machine.chip)
        let mem = ctx.memory
        let px = FinalJungleRenderer.room(mem, roomType: maze.type(ofRoom: st.room))
        newImg = FinalJungleRenderer.rgb(px, palette: FinalJungleRenderer.palette(mem))
        // picture edges from the bare backgrounds (the canvas may have the player / bullets in the border columns)
        let pal = FinalJungleRenderer.palette(mem)
        func cols(_ room: Int) -> ClosedRange<Int> {
            FinalRoomSlidePanel.contentColumns(FinalJungleRenderer.rgb(
                FinalJungleRenderer.room(mem, roomType: maze.type(ofRoom: room), player: false), palette: pal))
        }
        oldCols = cols(prev.room)
        newCols = cols(st.room)
        self.right = right
        total = max(4, min(30, Int(Prefs.double("section2.roomSlideFrames"))))
        frames = 0
        shownFrames = 0
        sawFade = false
        phase = .sliding
        dirty = true
    }

    /// The playfield of the last displayed frame: canvas lines $3c.., lowres x from DIW $71 (hires pixels doubled).
    static func canvasPlayfield(_ chip: Chipset) -> [UInt32] {
        let W = Chipset.canvasWidth, x0 = (0x71 - Chipset.canvasH0) * 2, y0 = 0x3c - Chipset.canvasV0
        var out = [UInt32](repeating: 0xff000000, count: 320 * 144)
        for y in 0..<144 { for x in 0..<320 { out[y * 320 + x] = chip.canvas[(y0 + y) * W + x0 + 2 * x] } }
        return out
    }

    /// Columns [first, last] of an image that are mostly (> 50 %) not black. The room pictures fill x 16..304;
    /// outside that they are black or only sparsely drawn (up to ~25 % of a column). The slide butts the two
    /// pictures together at these edges so no dark band runs between them.
    static func contentColumns(_ px: [UInt32]) -> ClosedRange<Int> {
        var lit = [Int](repeating: 0, count: 320)
        for y in 0..<144 { for x in 0..<320 where px[y * 320 + x] & 0xffffff != 0 { lit[x] += 1 } }
        let used = lit.map { $0 * 2 > 144 }
        guard let a = used.firstIndex(of: true), let b = used.lastIndex(of: true) else { return 0...319 }
        return a...b
    }

    /// Most of a sample grid of the canvas playfield is not black (the game shows a room, not the fade).
    static func canvasShowsPicture(_ chip: Chipset) -> Bool {
        let W = Chipset.canvasWidth, x0 = (0x71 - Chipset.canvasH0) * 2, y0 = 0x3c - Chipset.canvasV0
        var lit = 0, n = 0
        for y in stride(from: 8, to: 144, by: 16) {
            for x in stride(from: 24, to: 300, by: 12) {
                n += 1
                if chip.canvas[(y0 + y) * W + x0 + 2 * x] & 0xffffff != 0 { lit += 1 }
            }
        }
        return lit * 2 > n
    }

    /// The slide image for the current progress (old view pushed out, new room pushed in, edge to edge).
    /// Turned right: the view pans right (the old picture leaves to the left, the new one follows from the right);
    /// turned left: the reverse. At the end the new picture is exactly in place (offset 0).
    private func compose() -> [UInt32] {
        let t = min(1, Double(frames) / Double(total))
        let e = t * t * (3 - 2 * t)                           // smoothstep
        // distance travelled: from the old picture's leading content edge to the new one's trailing edge
        let dist = max(1, right ? oldCols.upperBound + 1 - newCols.lowerBound : newCols.upperBound + 1 - oldCols.lowerBound)
        let shift = Int((e * Double(dist)).rounded())
        if shift >= dist { return newImg }                    // the new room in place (as the game will show it)
        let oldOff = right ? -shift : shift                   // x of old pixel 0 on screen
        let newOff = right ? dist - shift : shift - dist
        var out = [UInt32](repeating: 0xff000000, count: 320 * 144)
        for y in 0..<144 {
            let row = y * 320
            for x in 0..<320 {
                let ox = x - oldOff, nx = x - newOff
                if nx >= 0 && nx < 320 && newCols.contains(nx) { out[row + x] = newImg[row + nx] }
                else if ox >= 0 && ox < 320 && oldCols.contains(ox) { out[row + x] = oldImg[row + ox] }
            }
        }
        return out
    }

    // Test aid (off by default): PLATOON_S2SLIDE_DUMP=<dir> writes, for every emulated frame of a slide and a few
    // frames after it, the slide image (f<frame>_slide.png, what the overlay shows) and the game's playfield
    // (f<frame>_game.png, the canvas under it) plus a line in slide.log, so the timing and the hand-over to the
    // game's own picture can be checked frame by frame (captures in the debug script are too slow for that).
    private static let dumpDir = ProcessInfo.processInfo.environment["PLATOON_S2SLIDE_DUMP"]
    private var dumpTail = 0
    private func dump(_ ctx: FrameContext, _ live: FinalJungleLive) {
        guard let dir = FinalRoomSlidePanel.dumpDir else { return }
        let idle: Bool = { if case .idle = phase { return true }; return false }()
        if idle { guard dumpTail > 0 else { return }; dumpTail -= 1 } else { dumpTail = 6 }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = ctx.frame
        func png(_ px: [UInt32], _ name: String) {
            guard let img = FinalRoomSlidePanel.image(px, 320, 144),
                  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name)") as CFURL,
                                                          "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
        png(FinalRoomSlidePanel.canvasPlayfield(ctx.machine.chip), "f\(f)_game.png")
        if !idle, oldImg.count == 320 * 144, newImg.count == 320 * 144 { png(compose(), "f\(f)_slide.png") }
        let line = "f\(f) phase \(phase) frames \(frames)/\(total) right \(right) room \(live.room) transition \(live.transition) "
            + String(format: "pal %05x back %05x\n", live.topPalette, live.backBuffer)
        let url = URL(fileURLWithPath: "\(dir)/slide.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.data(using: .utf8)!.write(to: url) }
    }

    private func stop() {
        phase = .idle
        oldImg = []; newImg = []
        dirty = false
        if isVisible { isVisible = false }
    }

    override func update(_ ctx: FrameContext?) {
        if case .idle = phase { if isVisible { isVisible = false }; return }
        guard dirty, oldImg.count == 320 * 144, newImg.count == 320 * 144 else { return }
        dirty = false
        layerView.layer?.contents = FinalRoomSlidePanel.image(compose(), 320, 144)
        if !isVisible { isVisible = true }
    }

    override func hostDidReset() { stop(); lastState = nil }

    static func image(_ px: [UInt32], _ w: Int, _ h: Int) -> CGImage? {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
