import AppKit
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
                if maze.next(prev, .right) == st { start(ctx, right: true, maze: maze, st: st) }
                else if maze.next(prev, .left) == st { start(ctx, right: false, maze: maze, st: st) }
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
            if afterSwap >= 2 { stop() }
        }
        if case .idle = phase {} else {
            shownFrames += 1
            if shownFrames > 400 { stop() }             // safety: never cover the game for long
        }
        lastState = st
    }

    private func start(_ ctx: FrameContext, right: Bool, maze: FinalJungleMaze, st: FinalJungleMaze.State) {
        let chip = ctx.machine.chip
        // the playfield of the last displayed frame: canvas lines $3c.., lowres x from DIW $71 (hires pixels doubled)
        let W = Chipset.canvasWidth, x0 = (0x71 - Chipset.canvasH0) * 2, y0 = 0x3c - Chipset.canvasV0
        var old = [UInt32](repeating: 0xff000000, count: 320 * 144)
        for y in 0..<144 { for x in 0..<320 { old[y * 320 + x] = chip.canvas[(y0 + y) * W + x0 + 2 * x] } }
        oldImg = old
        let mem = ctx.memory
        let px = FinalJungleRenderer.room(mem, roomType: maze.type(ofRoom: st.room))
        newImg = FinalJungleRenderer.rgb(px, palette: FinalJungleRenderer.palette(mem))
        self.right = right
        total = max(4, min(30, Int(Prefs.double("section2.roomSlideFrames"))))
        frames = 0
        shownFrames = 0
        sawFade = false
        phase = .sliding
        dirty = true
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
        let t = min(1, Double(frames) / Double(total))
        let e = t * t * (3 - 2 * t)                           // smoothstep
        let shift = Int((e * 320).rounded())
        var out = [UInt32](repeating: 0, count: 320 * 144)
        for y in 0..<144 {
            let row = y * 320
            for x in 0..<320 {
                if right {                                     // turned right: the view pans right
                    let sx = x + shift
                    out[row + x] = sx < 320 ? oldImg[row + sx] : newImg[row + sx - 320]
                } else {
                    let sx = x - shift
                    out[row + x] = sx >= 0 ? oldImg[row + sx] : newImg[row + sx + 320]
                }
            }
        }
        layerView.layer?.contents = FinalRoomSlidePanel.image(out, 320, 144)
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
