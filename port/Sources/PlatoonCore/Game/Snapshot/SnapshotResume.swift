import Foundation

// Savestates (roadmap F5/L1): capture at the main-loop heads and resume through loop-entry wrappers.
// See GameSnapshot.swift for the overall design.

extension Platoon {
    /// Savestate point at a main-loop head (called right BEFORE the loop's tickPoint, so a resumed game passes the
    /// tickPoint exactly once). Zero cost when no savestate service is attached (the default).
    @inline(__always) func snapshotPoint(_ pc: UInt32) {
        guard let svc = m.loopHeadService else { return }
        (svc as? SnapshotController)?.loopHead(self, pc: pc)
    }

    /// True when a consistent snapshot can be taken now (no interrupt handler or CPU-time stretch in progress).
    var snapshotSafe: Bool { irqDepth == 0 && !cpuBusy && chip.ipl == 0 && m.canCaptureState }

    /// Captures the complete game state (game thread only, at a loop head).
    func captureSnapshot(pc: UInt32, label: String, assisted: Bool) -> GameSnapshot? {
        guard let loop = SnapshotLoop(rawValue: pc), snapshotSafe else { return nil }
        let info = SnapshotInfo(loop: loop, frame: m.frameCount, created: Date(), scoreBCD: mem.r32(a6 + KV.score),
                                morale: mem.r16(a6 + KV.morale), manIndex: mem.r16(a6 + KV.manIndex),
                                buildTag: GameSnapshot.buildTag, adfTag: SnapshotController.adfTag(for: disk),
                                assisted: assisted, thumbnailPNG: GameSnapshot.thumbnail(UnsafePointer(chip.canvas)), label: label)
        return GameSnapshot(info: info, machine: m.captureState(), host: captureHostState())
    }

    func captureHostState() -> PlatoonHostState {
        var h = PlatoonHostState()
        h.cpuCycles = cpuCycles; h.interruptedD1 = interruptedD1; h.startSectionDone = startSectionDone
        h.loadedSection = loadedSection; h.diskCylinder = diskCylinder; h.diskRandState = diskRandState
        h.musicPlaying = musicPlaying; h.cpuBusy = cpuBusy; h.irqDepth = irqDepth; h.irqPreempted = irqPreempted
        h.irqBusyUntil = irqBusyUntil
        h.s2PaceIndex = s2PaceIndex; h.s2PacePlayerIndex = s2PacePlayerIndex
        assistLock.lock(); h.runAssist = runAssist.sorted(); assistLock.unlock()
        h.hsSavedOriginal = hsSavedOriginal; h.hsActiveMode = hsActiveMode; h.hsPristine = hsPristine
        h.hsModeTables = hsModeTables; h.inF10 = inF10; h.textScreenPending = textScreenPending
        return h
    }

    func restoreHostState(_ h: PlatoonHostState) {
        cpuCycles = h.cpuCycles; interruptedD1 = h.interruptedD1; startSectionDone = h.startSectionDone
        loadedSection = h.loadedSection; diskCylinder = h.diskCylinder; diskRandState = h.diskRandState
        musicPlaying = h.musicPlaying; cpuBusy = h.cpuBusy; irqDepth = h.irqDepth; irqPreempted = h.irqPreempted
        irqBusyUntil = h.irqBusyUntil
        s2PaceIndex = h.s2PaceIndex; s2PacePlayerIndex = h.s2PacePlayerIndex
        assistLock.lock(); runAssist.formUnion(h.runAssist); assistLock.unlock()   // + marks made during setup
        hsSavedOriginal = h.hsSavedOriginal; hsActiveMode = h.hsActiveMode; hsPristine = h.hsPristine
        hsModeTables = h.hsModeTables; inF10 = h.inF10; textScreenPending = h.textScreenPending
    }

    /// Reinstalls the translated interrupt handlers the way the original's vectors in RAM describe them
    /// (res_restart's monitor stubs, kbd_init's level 2, k_install_vectors' levels 3 and 6, section 2's fade hook).
    func snapshotReinstallInterrupts() {
        for lvl in [1, 3, 4, 5, 6, 7] {
            chip.interruptHandlers[lvl] = { fatalError("Uninitialised interrupt (level \(lvl)) - debug monitor not translated") }
        }
        if mem.r32(0x68) == 0x169c { chip.interruptHandlers[2] = { [unowned self] in self.level2_handler() } }
        if mem.r32(0x78) == KA.level6 { chip.interruptHandlers[6] = { [unowned self] in self.level6_raster() } }
        let l3: (() -> Void) = { [unowned self] in self.level3_vblank() }
        switch mem.r32(0x6c) {
        case KA.level3:
            chip.interruptHandlers[3] = l3
        case S2.l3HookFade where mem.r32(S2.vOldL3Vector) == KA.level3:
            chip.interruptHandlers[3] = { [unowned self] in self.s2_l3hook_fade(chain: l3) }
        default:
            fatalError(String(format: "snapshot resume: unknown level-3 vector $%06X", mem.r32(0x6c)))
        }
    }

    /// Continues the program at the loop head `pc` (loop-entry wrappers: the code that follows each loop in the
    /// original, restructured so the loop is entered at its head without re-running its initialisation).
    func snapshotResumeLoop(_ pc: UInt32) -> Never {
        k_registerDispatch()
        switch SnapshotLoop(rawValue: pc) {
        case .jungle:
            // section0_start's `while true { s0RestartInit(); s0MainLoop() }`, entered at the main loop
            s0RegisterDispatch()
            while true {
                s0MainLoop()
                s0RestartInit()
            }
        case .tunnels:
            // s1_tunnelLives' `while true { restart; main loop; ONE MORE CHANCE }`, entered at the main loop
            s1_tunnelMainLoop()
            s1_textScreenMusic3(S1.txtOneMoreChance)
            s1_tunnelLives()
        case .flare:
            s1_flareMainLoop()
        case .finalJungle:
            s2_registerDispatch()
            s2_main_loop()
        case nil:
            fatalError(String(format: "snapshot resume: $%06X is not a loop head", pc))
        }
    }
}

extension PlatoonGame {
    /// Restores `snapshot` into `machine` (fresh or running: a running game thread is abandoned) and starts the
    /// game thread at the snapshot's loop head. The next `machine.runFrame()` continues the captured frame.
    /// `config` is the configuration of the resumed run (enhancements, hiscore file, tick dumps...), exactly as
    /// for `PlatoonGame.main`. `assisted`: F4 reason the resumed run is marked with (a loaded / rewound game must
    /// not enter the original hiscore table; nil only for exact-continuation tests). The run marks of the saved game
    /// are restored as well. Call on the host thread between frames.
    /// Prefer a FRESH Machine: `PlatoonGame.prepare` chains the probe into `machine.frameHook`.
    public static func resume(_ machine: Machine, from snapshot: GameSnapshot, config: GameConfig = GameConfig(),
                              assisted: String? = "snapshot", alsoAssisted: [String] = []) {
        machine.startResumed(from: snapshot.machine) { m in
            let p = PlatoonGame.prepare(m, config: config)      // the same setup as PlatoonGame.main
            // --- savestate ---
            p.restoreHostState(snapshot.host)
            if let r = assisted { p.markAssisted(r) }
            for r in alsoAssisted { p.markAssisted(r) }
            p.snapshotReinstallInterrupts()
            p.probeResumed()
            p.snapshotResumeLoop(snapshot.info.loop.rawValue)
        }
    }
}
