// L4 widescreen jungle (owner: section0): host-rendered background columns beside the 320-px jungle window.
// Read-only: renders the section-0 map ($1b000) with its tiles ($1c000 + n*$600, 4 planes plane-sequential,
// 48 rows x 8 bytes each) and the current top palette (copper $115fa) for the scroll position of the buffer that is
// ON SCREEN. That position is latched when the game swaps buffers (s0WideLatch after k_swap in the main loop and the
// trap-door loop): the scroll variables in RAM are already the next tick's while the previous buffer is shown, so
// reading them at frame end would tear the sides by a tick. Nothing here writes game RAM or changes game timing.
//
// Use (host):
//   let latch = JungleWideLatch.attach(machine)          // once per Machine (reset = new Machine)
//   in frameHook / AppServices.onFrame:  latch.frameStart(machine)     // every emulated frame
//   then  latch.displayed  (nil or !valid = hide the sides)  and
//         JungleWidescreen.render(machine.memory, state, fromX:, width:) -> 0xFFRRGGBB pixels, 144 rows
//
// Geometry (buffer coordinates, verified pixel-exact against the canvas by the PLATOON_S0_WIDETEST self-test):
//   the jungle window starts at DIW h $81 (lowres), 144 rows from line $3c; buffer x 0 shows world pixel
//   X0 = (T+1)*64 + c34*8 of the current level strip, shifted right on screen by the hardware scroll hscroll.
//   Screen lowres h shows world X = X0 + (h - $81) - hscroll (+ JungleWidescreen.hOffset, see below).

import Foundation

public final class JungleWideLatch {
    /// Scroll state of one finished buffer.
    public struct State: Equatable {
        public var frame: UInt64
        public var level: Int, T: Int, c34: Int, hscroll: Int
        /// Top palette table pointer $5a(a6) when the buffer was finished ($19ff8 = the playfield palette).
        public var palette: UInt32
        /// false = a transition (dissolve, man select, restart) started: hide the sides.
        public var valid: Bool
        /// World pixel shown at buffer x 0 (see the file comment).
        public var worldX0: Int { (T + 1) * 64 + c34 * 8 }
    }

    /// Fast path for the game thread: false while no host attached a latch (default, zero cost).
    static var anyActive = false
    private static let tableLock = NSLock()
    private final class Weak { weak var m: Machine?; let l: JungleWideLatch; init(_ m: Machine, _ l: JungleWideLatch) { self.m = m; self.l = l } }
    private static var table: [ObjectIdentifier: Weak] = [:]

    /// The latch of `machine` (created on first use). Host thread.
    public static func attach(_ machine: Machine) -> JungleWideLatch {
        tableLock.lock(); defer { tableLock.unlock() }
        table = table.filter { $0.value.m != nil }
        let k = ObjectIdentifier(machine)
        if let w = table[k], w.m === machine { return w.l }
        let l = JungleWideLatch()
        table[k] = Weak(machine, l)
        anyActive = true
        return l
    }

    /// Stops latching for `machine`.
    public static func detach(_ machine: Machine) {
        tableLock.lock(); defer { tableLock.unlock() }
        table[ObjectIdentifier(machine)] = nil
        table = table.filter { $0.value.m != nil }
        anyActive = !table.isEmpty
    }

    static func existing(_ machine: Machine) -> JungleWideLatch? {
        tableLock.lock(); defer { tableLock.unlock() }
        guard let w = table[ObjectIdentifier(machine)], w.m === machine else { return nil }
        return w.l
    }

    private let lock = NSLock()
    private var queue: [State] = []
    private var shown: State?
    /// The state shown during the current emulated frame (after `frameStart`); nil = unknown / hide.
    public var displayed: State? { lock.lock(); defer { lock.unlock() }; return shown }

    /// Game thread (section code after k_swap, or at a transition).
    func record(_ s: State) {
        lock.lock(); defer { lock.unlock() }
        queue.append(s)
        if queue.count > 8 { queue.removeFirst(queue.count - 8) }
    }

    /// Host, at the start of every emulated frame (game thread parked): decides which buffer is on screen now. The
    /// level-6 handler installs the copper list of a swapped buffer at the split line; the copper uses it from the
    /// next frame on, so an entry whose swap request ($12d74) has been consumed is on screen from this frame.
    public func frameStart(_ machine: Machine) {
        let swapPending = machine.memory.r8(KA.swapPending) != 0
        let inSection0 = PlatoonGame.platoon(for: machine)?.loadedSection == 0
        lock.lock(); defer { lock.unlock() }
        if !inSection0 { queue.removeAll(); shown = nil; return }
        while let e = queue.first {
            if !e.valid { shown = e; queue.removeFirst(); continue }
            // the newest swap request stays pending until the level-6 handler consumed it
            let newer = queue.dropFirst()
            if swapPending && !newer.contains(where: { $0.valid }) && !newer.contains(where: { !$0.valid }) { break }
            shown = e; queue.removeFirst()
        }
    }

    /// Forget everything (host reset).
    public func reset() { lock.lock(); queue.removeAll(); shown = nil; lock.unlock() }
}

public enum JungleWidescreen {
    /// Rows of the jungle window (3 tile rows of 48).
    public static let rows = 144
    /// First beam line and DIW horizontal start (lowres) of the jungle window.
    public static let firstLine = 0x3c
    public static let diwH = 0x81
    /// Correction between the formula in the file comment and the displayed picture (lowres px), measured by the
    /// self-test (PLATOON_S0_WIDETEST).
    public static var hOffset = 0

    /// Current top palette (16 colours of the copper's upper part) as 0xFFRRGGBB.
    public static func topPalette(_ mem: Memory) -> [UInt32] {
        (0..<16).map { Chipset.rgb(mem.r16(KA.copTopPalette + UInt32(4 * $0))) }
    }

    /// Renders background pixels for buffer x in [fromX, fromX+width) (0 = the first pixel of the window at scroll 0,
    /// negative = left of the window) of the given latched state: `rows` rows of `width` pixels, row-major.
    /// World pixels outside the 90-tile strip are black. `palette` defaults to the current top palette.
    public static func render(_ mem: Memory, _ s: JungleWideLatch.State, fromX: Int, width: Int, palette: [UInt32]? = nil) -> [UInt32] {
        let pal = palette ?? topPalette(mem)
        var out = [UInt32](repeating: 0xff00_0000, count: max(0, width) * rows)
        guard width > 0, (0...5).contains(s.level) else { return out }
        let mapLevel = 0x1b000 + UInt32(s.level * 0x10e)
        let x0 = s.worldX0 - s.hscroll + hOffset
        for x in 0..<width {
            let wx = x0 + fromX + x
            guard wx >= 0 && wx < 90 * 64 else { continue }
            let col = wx >> 6, px = wx & 63
            let byte = UInt32(px >> 3), bit = UInt8(0x80 >> (px & 7))
            for r in 0..<3 {
                let tile = UInt32(mem.r8(mapLevel + UInt32(r * 90 + col)))
                let g = 0x1c000 + tile * 0x600 + byte
                for y in 0..<48 {
                    let a = g + UInt32(y * 8)
                    var c = 0
                    if mem.r8(a) & bit != 0 { c |= 1 }
                    if mem.r8(a + 0x180) & bit != 0 { c |= 2 }
                    if mem.r8(a + 0x300) & bit != 0 { c |= 4 }
                    if mem.r8(a + 0x480) & bit != 0 { c |= 8 }
                    out[(r * 48 + y) * width + x] = pal[c]
                }
            }
        }
        return out
    }
}

// MARK: - headless self-test (PLATOON_S0_WIDETEST=dir[,everyFrames])

/// Verification of the latch + renderer against the real picture: every `every` frames while the jungle is shown,
/// renders the visible window from the map and compares it with the canvas (background pixels must match exactly;
/// bobs differ), writes `<dir>/wide.log` (match ratio per frame, and the best offset if it isn't 0) and a PPM of the
/// canvas window with 96-px rendered side columns (`wide_<frame>.ppm`, every 10th sample).
final class JungleWideSelfTest {
    static var installed = false
    let dir: String, every: Int
    var n = 0
    let logFile: FileHandle?

    init(dir: String, every: Int) {
        self.dir = dir; self.every = every
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/wide.log", contents: nil)
        logFile = FileHandle(forWritingAtPath: dir + "/wide.log")
    }

    static func installIfRequested(_ m: Machine) {
        guard !installed, let spec = ProcessInfo.processInfo.environment["PLATOON_S0_WIDETEST"] else { return }
        installed = true
        let p = spec.split(separator: ",").map(String.init)
        let t = JungleWideSelfTest(dir: p[0], every: p.count > 1 ? Int(p[1]) ?? 25 : 25)
        let latch = JungleWideLatch.attach(m)
        let prev = m.frameHook
        m.frameHook = { mm in
            prev?(mm)
            // the canvas now holds the previous frame, shown with the previous frame's latch
            let shownBefore = latch.displayed
            latch.frameStart(mm)
            if mm.frameCount % UInt64(t.every) == 0, let s = shownBefore, s.valid, s.palette == 0x19ff8 { t.sample(mm, s) }
        }
    }

    func sample(_ m: Machine, _ s: JungleWideLatch.State) {
        let mem = m.memory
        let W = 320
        let pal = JungleWidescreen.topPalette(mem)
        // canvas window: lowres h $81.., lines $3c..
        func canvasPixel(_ x: Int, _ y: Int) -> UInt32 {
            let cx = (JungleWidescreen.diwH + x - Chipset.canvasH0) * 2
            let cy = JungleWidescreen.firstLine + y - Chipset.canvasV0
            return m.chip.canvas[cy * Chipset.canvasWidth + cx]
        }
        var best = (off: 0, ratio: -1.0)
        for off in -20...20 {
            let r = JungleWidescreen.render(mem, s, fromX: off, width: W, palette: pal)
            var same = 0
            for y in 0..<JungleWidescreen.rows { for x in 0..<W where r[y * W + x] == canvasPixel(x, y) { same += 1 } }
            let ratio = Double(same) / Double(W * JungleWidescreen.rows)
            if ratio > best.ratio { best = (off, ratio) }
        }
        let r0 = JungleWidescreen.render(mem, s, fromX: 0, width: W, palette: pal)
        var same0 = 0
        for y in 0..<JungleWidescreen.rows { for x in 0..<W where r0[y * W + x] == canvasPixel(x, y) { same0 += 1 } }
        let line = String(format: "f%d level %d T %d c34 %d hs %d: match %.4f (best offset %d: %.4f)\n", m.frameCount, s.level, s.T,
                          s.c34, s.hscroll, Double(same0) / Double(W * JungleWidescreen.rows), best.off, best.ratio)
        logFile?.write(line.data(using: .utf8)!)
        n += 1
        if n % 10 == 1 {
            let side = 96
            let left = JungleWidescreen.render(mem, s, fromX: -side, width: side, palette: pal)
            let right = JungleWidescreen.render(mem, s, fromX: W, width: side, palette: pal)
            let TW = side + W + side, H = JungleWidescreen.rows
            var ppm = "P6 \(TW) \(H) 255\n".data(using: .ascii)!
            for y in 0..<H {
                for x in 0..<TW {
                    let c: UInt32
                    if x < side { c = dim(left[y * side + x]) }
                    else if x < side + W { c = canvasPixel(x - side, y) }
                    else { c = dim(right[y * side + x - side - W]) }
                    ppm.append(contentsOf: [UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)])
                }
            }
            FileManager.default.createFile(atPath: "\(dir)/wide_\(m.frameCount).ppm", contents: ppm)
        }
    }

    /// Side columns are shown slightly darker in the test image so the seam is visible.
    private func dim(_ c: UInt32) -> UInt32 {
        let r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255
        return 0xff00_0000 | (r * 3 / 4) << 16 | (g * 3 / 4) << 8 | (b * 3 / 4)
    }
}
