import AppKit
import simd
import PlatoonCore

// OWNER: [presentation]. Per-frame presentation state driven by the game (host-only, read-only RAM access from
// AppServices.onFrame where the game thread is parked):
//   S13 screen shake (+ optional hit edge tint) from the F2 fx / wound events, the bridge blast and the napalm strike
//   S16 night black-level lift while the tunnels or the flare night are on screen
//   S17 reduced flashing: a display LUT that limits the tunnel/flare "hit" red flash, the napalm white-out and
//       the flare light-up (nothing in the game changes; the original palette values stay in RAM)
//   M21 split line of the HUD (for the magnifier)
// and it feeds the M24 recorder. Nothing here writes game RAM.

/// Dynamic per-frame state the renderer reads.
struct VideoFrameState {
    /// S13 offset of the game image in whole lowres pixels.
    var shake = (x: 0, y: 0)
    /// S13 red edge tint 0..1.
    var tint: Float = 0
    /// S16 current night-lift amount 0..1 (ramped).
    var night: Float = 0
    /// Canvas line where the HUD (bottom palette) starts: lines above it are the game window.
    var splitCanvasY = 180
    /// S17 colour LUT (4096 entries, index = 12-bit Amiga colour, value 0xAARRGGBB) or nil = none.
    var flashLUT: [UInt32]?
    var flashLUTGeneration = 0
    /// Emulated frames since the last canvas upload (persistence / temporal filters decay per emulated frame).
    var framesSinceUpload = 0
}

final class VideoFX {
    static let shared = VideoFX()

    private(set) var look = VideoLook()
    private var lookDirty = true
    private var renderer: MetalRenderer? { AppServices.shared.app?.renderer }

    // S13
    private var trauma: Float = 0
    private var sustain = 0
    private var tint: Float = 0
    private var rng: UInt32 = 0x2545_f491
    private var lastBridge: Int?
    // S16
    private var night: Float = 0
    // S17
    private var napalmArmed = false
    private var stableTop: [UInt16] = Array(repeating: 0, count: 16)
    private var slew: [SIMD3<Float>]? = nil
    private var lastLUTKey: [UInt32] = []
    private var lutGeneration = 0
    static func rgb(_ c12: Int) -> UInt32 {
        let r = UInt32((c12 >> 8) & 15) * 0x11, g = UInt32((c12 >> 4) & 15) * 0x11, b = UInt32(c12 & 15) * 0x11
        return 0xff00_0000 | r << 16 | g << 8 | b
    }
    static let identityLUT: [UInt32] = (0..<4096).map(rgb)

    /// Debug/test log of effect events (PLATOON_VIDEO_LOG=file).
    private var log: FileHandle?

    func install(_ app: AppServices) {
        if let p = ProcessInfo.processInfo.environment["PLATOON_VIDEO_LOG"] {
            FileManager.default.createFile(atPath: p, contents: nil); log = FileHandle(forWritingAtPath: p)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lookDirty = true
        }
        app.onHostReady { [weak self] host in
            host.probe.onFx { id, _ in self?.fx(id) }
            host.probe.addObserver { r in
                switch r.event {
                case .wounded, .death: self?.hit()
                default: break
                }
            }
            if VideoRecorder.shared.isRecording { VideoRecorder.shared.tapAudio(host.machine) }
        }
        app.onReset { [weak self] host in
            self?.resetRun()
            if VideoRecorder.shared.isRecording { VideoRecorder.shared.tapAudio(host.machine) }
        }
        app.onFrame { [weak self] ctx in self?.frame(ctx) }
        app.onDisplay { [weak self] ctx in self?.display(ctx) }
        app.onPauseChange { [weak self] paused in
            guard let self, paused else { return }
            self.renderer?.fx.shake = (0, 0)
        }
    }

    private func note(_ s: String) {
        log?.write("\(AppServices.shared.host?.machine.frameCount ?? 0) \(s)\n".data(using: .utf8)!)
    }

    func reloadLook() {
        look = VideoLook.load()
        renderer?.look = look
        lookDirty = false
        AppServices.shared.overlay.setNeedsLayout()      // the HUD magnifier moves the game image
    }

    private func resetRun() {
        trauma = 0; sustain = 0; tint = 0; lastBridge = nil; night = 0
        napalmArmed = false; slew = nil; lastLUTKey = []
        renderer?.fx = VideoFrameState()
    }

    // MARK: S13 events

    private func fx(_ id: Int) {
        guard look.shake != 0 else { return }
        let ctx = AppServices.shared.probe?.context
        switch id {
        case 0x85: kick(1.0); note("shake explosion")
        case 0x81:
            if ctx?.loadedSection == 2 && ctx?.timerMinutes == 0 && ctx?.timerSeconds == 0 { kick(1.0, sustain: 45); note("shake napalm") }
            else { kick(0.6); note("shake hit") }
        default: break
        }
    }
    private func hit() {
        guard look.hitTint else { return }
        tint = 1; note("tint")
    }
    private func kick(_ t: Float, sustain s: Int = 0) { trauma = max(trauma, t); sustain = max(sustain, s) }
    private func random() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng & 0xffff) / 32767.5 - 1
    }

    // MARK: per emulated frame

    private func frame(_ ctx: FrameContext) {
        if lookDirty { reloadLook() }
        guard let r = renderer else { return }
        let g = ctx.game
        let mem = ctx.memory
        r.fx.framesSinceUpload += 1

        // M21/S17: HUD split (copper WAIT before the HUD palette: VP byte at $11638)
        let vp = Int(mem.r8(0x11638))
        if (0x60...0x120).contains(vp) { r.fx.splitCanvasY = vp - Chipset.canvasV0 }

        // S13 shake
        if look.shake != 0 {
            if let b = g.jungle?.bridge {
                if let l = lastBridge, l != 2, b == 2 { kick(1.0, sustain: 30); note("shake bridge") }
                lastBridge = b
            } else { lastBridge = nil }
            if sustain > 0 { sustain -= 1 } else { trauma = max(0, trauma - 0.07) }
            let amp = (look.shake == 2 ? Float(3) : 2) * trauma * trauma
            r.fx.shake = amp > 0.05 ? (Int((random() * amp).rounded()), Int((random() * amp).rounded())) : (0, 0)
        } else if r.fx.shake != (0, 0) || trauma > 0 { trauma = 0; r.fx.shake = (0, 0) }
        tint = max(0, tint - 0.06)
        r.fx.tint = look.hitTint ? tint : 0

        // S16 night lift (game window only; text screens and the HUD keep their colours)
        let dark = look.nightLift && g.screen == .playing && (g.area == .tunnels || g.area == .flare)
        let target: Float = dark ? look.nightLiftAmount : 0
        night += max(-0.05, min(0.05, target - night))
        if abs(night - target) < 0.001 { night = target }
        r.fx.night = night

        // S17 reduced flashing
        updateFlashLUT(ctx, r)

        // M24
        VideoRecorder.shared.frame(ctx.machine.chip)
    }

    private func display(_ ctx: FrameContext) {
        if lookDirty { reloadLook() }
        if ctx.host.paused, let r = renderer, r.fx.shake != (0, 0) { r.fx.shake = (0, 0) }
    }

    // MARK: S17

    private static let a6: UInt32 = 0x12dde
    private static let copTopPalette: UInt32 = 0x115fa   // value words of the top-palette copper MOVEs (step 4)
    private static let tunnelWork: UInt32 = 0x1a012, tunnelBase: UInt32 = 0x1a032
    private static let napalmWork: UInt32 = 0x57f70
    private static let nightPalettes: Set<UInt32> = [0x19f92, 0x19fb2, 0x19fd2, 0x19ff2]

    private func updateFlashLUT(_ ctx: FrameContext, _ r: MetalRenderer) {
        guard look.reduceFlashing else {
            if r.fx.flashLUT != nil { r.fx.flashLUT = nil }
            slew = nil; napalmArmed = false
            return
        }
        let g = ctx.game, mem = ctx.memory
        let top = (0..<16).map { mem.r16(VideoFX.copTopPalette + UInt32(4 * $0)) & 0xfff }
        let ptr = mem.r32(VideoFX.a6 + 0x5a)
        let cap = max(0.1, min(1, look.flashCap))
        var shown: [SIMD3<Float>]? = nil
        func nib(_ c: UInt16) -> SIMD3<Float> { SIMD3(Float((c >> 8) & 15), Float((c >> 4) & 15), Float(c & 15)) }

        if g.loadedSection == 2 {
            // napalm: time_up ramps a copy of the palette ($57f70) to white; cap the rise at `cap` of the way
            if g.inGame && g.timerMinutes == 0 && g.timerSeconds == 0 && g.screen == .playing { napalmArmed = true }
            if g.screen == .textScreen || g.screen == .gameOver || !g.inGame { napalmArmed = false }
            if napalmArmed && ptr == VideoFX.napalmWork {
                shown = (0..<16).map { i in
                    let b = nib(stableTop[i]), w = nib(top[i])
                    return simd_min(w, b + (SIMD3(repeating: 15) - b) * cap)
                }
            } else { stableTop = top }
            slew = nil
        } else if g.loadedSection == 1 && g.screen == .playing {
            let base = (0..<16).map { mem.r16(VideoFX.tunnelBase + UInt32(2 * $0)) & 0xfff }
            if ptr == VideoFX.tunnelWork, (0..<16).contains(where: { (top[$0] >> 8) & 15 > (base[$0] >> 8) & 15 }) {
                // hit: flash_red pushes red up and green/blue down; keep only `cap` of the deviation
                shown = (0..<16).map { i in
                    let b = nib(base[i]), w = nib(top[i])
                    let lo = b * -cap, hi = (SIMD3(repeating: 15) - b) * cap
                    return b + simd_clamp(w - b, lo, hi)
                }
                slew = nil
            } else if g.area == .flare && VideoFX.nightPalettes.contains(ptr) {
                // flare light-up (night0 -> night3 within 3 iterations): brighten gradually, darken at once
                let rate: Float = 0.25 + cap * 0.5          // nibbles per emulated frame
                var s = slew ?? top.map(nib)
                for i in 0..<16 {
                    let w = nib(top[i])
                    s[i] = simd_min(w, s[i] + SIMD3(repeating: rate))   // (a darker target is taken at once)
                }
                slew = s
                shown = s
            } else { slew = nil }
        } else { slew = nil; napalmArmed = false }

        guard let d = shown else {
            if r.fx.flashLUT != nil { r.fx.flashLUT = nil; lastLUTKey = [] }
            return
        }
        // LUT: every colour of the current top palette -> the limited colour (first entry wins on duplicates)
        var key: [UInt32] = []
        var lut = VideoFX.identityLUT
        var done = Set<UInt16>()
        var changed = false
        for i in 0..<16 where done.insert(top[i]).inserted {
            let v = simd_clamp(d[i], SIMD3(repeating: 0), SIMD3(repeating: 15)) * 17
            let r8 = UInt32(v.x.rounded()), g8 = UInt32(v.y.rounded()), b8 = UInt32(v.z.rounded())
            let out: UInt32 = 0xff00_0000 | r8 << 16 | g8 << 8 | b8
            lut[Int(top[i])] = out
            if out != VideoFX.identityLUT[Int(top[i])] { changed = true }
            key.append(UInt32(top[i])); key.append(out)
        }
        if !changed {
            if r.fx.flashLUT != nil { r.fx.flashLUT = nil; lastLUTKey = [] }
            return
        }
        if key != lastLUTKey {
            lastLUTKey = key
            lutGeneration += 1
            r.fx.flashLUT = lut
            r.fx.flashLUTGeneration = lutGeneration
            note("flashLUT ptr=\(String(ptr, radix: 16)) section=\(g.loadedSection)")
        }
    }
}
