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
    // savestate support (MachineSnapshot.swift): where the host is parked while the game thread runs, a pending
    // mid-frame resume point for a restored game thread, and the detach flag of an abandoned machine.
    private var hostLine = 0
    private var hostAfterEndLine = false
    private var resumePoint: (line: Int, afterEndLine: Bool)?
    private var detached = false
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
        var first = 0
        if let r = resumePoint {
            // Savestate restore (see `startResumed`): the frame was already running when the snapshot was taken
            // (frameHook and lines 0...r.line up to the game's resumption are part of the restored state), so the
            // restored game thread continues at exactly that point of line r.line.
            resumePoint = nil
            first = r.line + 1
            resume(line: r.line, afterEndLine: r.afterEndLine)
            if detached { return }
            if !r.afterEndLine {
                chip.endLine(r.line)
                chip.checkInterrupts()
                if pendingJump != nil, !gameFinished { resume(line: r.line, afterEndLine: true); if detached { return } }
            }
        } else {
            frameHook?(self)
        }
        for v in first..<Chipset.linesPerFrame {
            chip.joy1dat = input.joy1dat
            chip.beginLine(v)
            if v == 0 {
                chip.frame = frameCount
                chip.ciaA.todTick()
                chip.raise(0x0020)   // VERTB
            }
            if v == 100 { deliverKey() }
            switch wait {
            case .vblank where v == 0: resume(line: v, afterEndLine: false)
            case .line(let l) where l == v: resume(line: v, afterEndLine: false)
            case .frames(let n) where v == 0:
                if n <= 1 { resume(line: v, afterEndLine: false) } else { wait = .frames(n - 1) }
            default: break
            }
            if detached { return }
            chip.endLine(v)
            chip.checkInterrupts()
            // a jump requested by an interrupt handler (DEL warm restart) happens at once, not at the next wait
            if pendingJump != nil, !gameFinished { resume(line: v, afterEndLine: true); if detached { return } }
        }
        frameCount += 1
    }

    /// Hands control to the game thread; records where in the frame the host is parked (savestates).
    private func resume(line v: Int, afterEndLine: Bool) {
        hostLine = v
        hostAfterEndLine = afterEndLine
        resume()
    }

    private func deliverKey() {
        if input.keyDelay > 0 { input.keyDelay -= 1; return }
        guard !input.keyQueue.isEmpty else { return }
        let k = input.keyQueue.removeFirst()
        let raw = ((k & 0x7f) << 1) | (k & 0x80 != 0 ? 1 : 0)
        chip.ciaA.sdr = ~raw
        chip.ciaA.icr |= 8
        input.keyDelay = input.keyGapFrames
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
        if let j = pendingJump { pendingJump = nil; jump(j) }
    }

    private var pendingJump: (() -> Void)?

    /// Non-local `jmp` into a routine that never returns (next section, game over, warm restart):
    /// continues the program on a fresh game thread with an empty stack and ends the current one.
    /// Call only from the game thread.
    public func jump(_ entry: @escaping () -> Void) -> Never {
        let t = Thread { [unowned self] in
            entry()
            self.wait = .finished
            self.gameFinished = true
            self.gameYielded.signal()
        }
        t.stackSize = 16 << 20
        t.name = "Platoon game"
        thread = t
        t.start()
        Thread.exit()
        fatalError("unreachable")
    }

    /// Requests a `jump` from outside the game thread (e.g. an interrupt handler running on the host
    /// thread, like the DEL-key warm restart). Performed when the game thread next resumes.
    public func requestJump(_ entry: @escaping () -> Void) {
        if Thread.current === thread { jump(entry) }
        pendingJump = entry
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

    // MARK: savestate support (roadmap F5/L1; used by Game/Snapshot, never by the normal frame path)

    /// Host-owned savestate service that the translated game consults at its main-loop heads
    /// (Game/Snapshot/SnapshotController). nil (default) = no snapshot work at all.
    public var loopHeadService: AnyObject?

    /// Captures the complete machine state. Call ONLY on the game thread (the host is then parked inside
    /// `runFrame` at a known point of the current line, which is recorded so the restore continues there).
    public func captureState() -> MachineState {
        MachineState(frameCount: frameCount, line: hostLine, afterEndLine: hostAfterEndLine,
                     memory: memory.snapshot(), chip: chip.captureState(), input: input.captureState())
    }

    /// True when the game thread may be captured right now: it runs (the host is parked in runFrame) and no
    /// non-local jump is pending.
    public var canCaptureState: Bool { pendingJump == nil && !abortRequested && !detached && !gameFinished }

    /// Abandons this machine from the game thread (savestate round-trip tests): the game thread ends here and the
    /// host's current `runFrame` returns at once, without emulating the rest of the frame. The machine is dead
    /// afterwards (restore a state into it or drop it).
    public func detach() -> Never {
        detached = true
        wait = .finished
        gameFinished = true
        gameYielded.signal()
        Thread.exit()
        fatalError("unreachable")
    }

    /// Restores `state` into this machine and starts a new game thread running `entry` at the captured point:
    /// the next `runFrame` continues the captured frame from the captured beam line (no frameHook for that
    /// partial frame). Any running game thread is abandoned first, so this works on a fresh or a used machine.
    /// Interrupt handlers are cleared; `entry` must reinstall them before it lets the program run.
    /// Call on the host thread (between frames).
    public func startResumed(from state: MachineState, _ entry: @escaping (Machine) -> Void) {
        if thread != nil && !detached { stop() }
        thread = nil
        abortRequested = false
        pendingJump = nil
        gameFinished = false
        detached = false
        chip.interruptHandlers = [(() -> Void)?](repeating: nil, count: 8)
        memory.restore(state.memory)
        chip.restoreState(state.chip)
        input.restoreState(state.input)
        frameCount = state.frameCount
        resumePoint = (state.line, state.afterEndLine)
        wait = .notStarted
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
}
