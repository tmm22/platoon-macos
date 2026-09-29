import Foundation

/// Frame driver. The translated main program runs on its own thread as a coroutine: it runs
/// until it waits for the vertical blank (or a raster line) and then hands control back to the
/// host, which emulates the beam line by line (copper, display, interrupts, audio). Exactly one
/// side runs at any time, so everything is deterministic.
public final class Machine {
    public let memory = Memory()
    public let chip: Chipset
    public let input = Input()
    public let disk: Disk
    public private(set) var frameCount: UInt64 = 0

    private var thread: Thread?
    private let resumeGame = DispatchSemaphore(value: 0)
    private let gameYielded = DispatchSemaphore(value: 0)
    private enum WaitState { case notStarted, vblank, line(Int), frames(Int), finished }
    private var wait: WaitState = .notStarted
    private var abortRequested = false
    public private(set) var gameFinished = false
    public var log: ((String) -> Void)?
    /// Called on the host thread at the start of every frame, before any line is emulated.
    public var frameHook: ((Machine) -> Void)?

    public init(disk: Disk) {
        self.disk = disk
        chip = Chipset(memory: memory)
        chip.ciaA.portAInput = { [unowned self] in
            var v: UInt8 = 0xff
            if self.input.fire { v &= ~0x80 }
            if self.input.fire0 { v &= ~0x40 }
            v &= ~0x20  // drive ready
            v &= ~0x04  // disk inserted
            return v
        }
    }

    // MARK: host side

    /// Starts the translated program. `entry` runs on the game thread.
    public func start(_ entry: @escaping (Machine) -> Void) {
        precondition(thread == nil)
        wait = .vblank
        let t = Thread { [unowned self] in
            self.resumeGame.wait()
            if self.abortRequested { self.gameYielded.signal(); return }
            entry(self)
            self.wait = .finished
            self.gameFinished = true
            self.gameYielded.signal()
        }
        t.stackSize = 16 << 20
        t.name = "Platoon game"
        thread = t
        t.start()
    }

    /// Abandons the game thread (used when restarting). The thread exits at its next wait.
    public func stop() {
        guard let _ = thread, !gameFinished else { return }
        abortRequested = true
        resumeGame.signal()
        gameYielded.wait()
        thread = nil
    }

    private func resume() {
        resumeGame.signal()
        gameYielded.wait()
    }

    /// Emulates one PAL frame (313 lines).
    public func runFrame() {
        frameHook?(self)
        for v in 0..<Chipset.linesPerFrame {
            chip.joy1dat = input.joy1dat
            chip.beginLine(v)
            if v == 0 {
                chip.frame = frameCount
                chip.ciaA.todTick()
                chip.raise(0x0020)   // VERTB
            }
            if v == 100 { deliverKey() }
            switch wait {
            case .vblank where v == 0: resume()
            case .line(let l) where l == v: resume()
            case .frames(let n) where v == 0:
                if n <= 1 { resume() } else { wait = .frames(n - 1) }
            default: break
            }
            chip.endLine(v)
            chip.checkInterrupts()
        }
        frameCount += 1
    }

    private func deliverKey() {
        if input.keyDelay > 0 { input.keyDelay -= 1; return }
        guard !input.keyQueue.isEmpty else { return }
        let k = input.keyQueue.removeFirst()
        let raw = ((k & 0x7f) << 1) | (k & 0x80 != 0 ? 1 : 0)
        chip.ciaA.sdr = ~raw
        chip.ciaA.icr |= 8
        input.keyDelay = 2
        chip.ciaCheck()
    }

    // MARK: game side (call only from the game thread)

    private func yieldToHost() {
        gameYielded.signal()
        resumeGame.wait()
        if abortRequested {
            gameYielded.signal()
            Thread.exit()
        }
    }

    /// Waits for the start of the next frame (after the vertical-blank interrupt has run).
    public func waitVBlank() { wait = .vblank; yieldToHost() }

    /// Waits `n` vertical blanks.
    public func waitFrames(_ n: Int) { guard n > 0 else { return }; wait = .frames(n); yieldToHost() }

    /// Waits until the beam reaches line `v` (0...312). If the beam is already past it, waits
    /// for that line in the next frame — like `cmp.b #v,$dff006 / bne` loops.
    public func waitLine(_ v: Int) { wait = .line(v % Chipset.linesPerFrame); yieldToHost() }

    /// The current beam line as seen by the game thread.
    public var beamLine: Int { chip.vpos }
}
