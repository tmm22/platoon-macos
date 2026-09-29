import Foundation

// Game-side half of the F1/F2 probe (owner: core): the calls the kernel makes at its choke points. Every function
// returns at once when no probe is attached (GameConfig.probe == nil); none writes RAM or charges CPU time, so the
// game behaves identically with or without a probe.

extension Platoon {
    @inline(__always) var probe: GameProbe? { config.probe }

    /// tickPoint(pc): section main-loop heads / wait loops identify the screen and sub-mode.
    @inline(__always) func probeTick(_ pc: UInt32) {
        guard let p = config.probe, let s = GameProbe.screenForTick(pc) else { return }
        p.lock.lock()
        p.modePC = pc; p.modeTicks &+= 1
        let changed = p.screen != s
        if changed { p.screen = s; p.capturingText = false }
        p.lock.unlock()
        if changed && s == .manSelect { p.record(m.frameCount, .manSelect) }
    }

    /// k_queue_text ($1070c), before the queue-full drop.
    func probeMessage(_ d0in: UInt16, dropped: Bool) {
        guard let p = config.probe else { return }
        let idx = UInt32(d0in & 0xff), table = mem.r32(a6 + KV.textTable)
        let text = PrintText.decode(mem, mem.r32(table &+ (idx << 2)))
        let sec: Int? = table == KA.kernelTexts ? nil : loadedSection
        p.record(m.frameCount, .message(.init(section: sec, index: Int(idx), table: table, dropped: dropped, text: text)))
    }

    /// k_fx ($10c50), before the FX-off early return (k_fx(0) from the F10 handler is not reported).
    func probeFx(_ d0: UInt16) {
        guard let p = config.probe, !inF10 else { return }
        p.record(m.frameCount, .fx(id: Int(d0 & 0xff), enabled: mem.r8(a6 + KV.soundFlags) & 2 != 0))
    }

    /// k_add_score ($10638), after the addition.
    func probeScore(after a0: UInt32) {
        guard let p = config.probe else { return }
        p.record(m.frameCount, .score(added: mem.r32(a0 &- 4), total: mem.r32(a6 + KV.score)))
    }

    func probeScreen(_ s: GameContext.Screen) {
        config.probe?.setScreen(s)
    }

    /// k_clear_screens inside a section: a full-screen text (or a transition) follows; capture what is printed.
    func probeClearScreens() {
        guard let p = config.probe else { return }
        p.lock.lock()
        if p.inSection && (p.screen == .playing || p.screen == .textScreen) {
            p.capturingText = true; p.screenText = []; textScreenPending = false   // .textScreen once text is printed
        } else if p.screen == .loading {
            p.capturingText = true; p.screenText = []
        }
        p.lock.unlock()
    }

    /// r_print ($1a5c) while a text screen is being drawn.
    func probePrint(_ a0: UInt32) {
        guard let p = config.probe else { return }
        p.lock.lock(); let cap = p.capturingText; p.lock.unlock()
        guard cap, !inTextStart, !(KA.strScoreHdr..<KA.strDiskError).contains(a0) else { return }   // not HUD / messages
        let t = PrintText.decode(mem, a0)
        guard !t.isEmpty else { return }
        p.lock.lock()
        p.screenText.append(t)
        if p.inSection { p.screen = .textScreen }
        p.lock.unlock()
        textScreenPending = true
    }

    /// k_wait_vbl: a text screen that was printed is now on display -> one textScreen event.
    @inline(__always) func probeVbl() {
        guard textScreenPending, let p = config.probe else { return }
        textScreenPending = false
        p.lock.lock(); let t = p.screenText.joined(separator: "\n"), s = p.screen; p.lock.unlock()
        if s == .textScreen { p.record(m.frameCount, .textScreen(t)) }
    }

    func probeNewGame(_ section: Int) {
        guard let p = config.probe else { return }
        p.lock.lock(); p.inGame = true; p.lock.unlock()
        p.record(m.frameCount, .newGame(section: section))
    }

    func probeSectionStart() {
        guard let p = config.probe else { return }
        p.lock.lock()
        p.loadedSection = loadedSection; p.inSection = true; p.screen = .playing; p.modePC = 0; p.capturingText = false
        p.lock.unlock()
        p.record(m.frameCount, .sectionStart(section: loadedSection, globals: mem.slice(a6, 0x76)))
    }

    /// k_next_section: the running section (if any) was completed; LOADING follows.
    func probeNextSection() {
        guard let p = config.probe else { return }
        p.lock.lock()
        let was = p.inSection ? p.loadedSection : nil
        p.inSection = false; p.screen = .loading; p.capturingText = true; p.screenText = []
        p.lock.unlock()
        if let s = was { p.record(m.frameCount, .sectionEnd(section: s)) }
    }

    func probeLoaded() {
        guard let p = config.probe else { return }
        p.lock.lock(); p.loadedSection = loadedSection; p.lock.unlock()
    }

    func probeGameOver() {
        guard let p = config.probe else { return }
        p.lock.lock()
        let sec = p.loadedSection
        p.inSection = false; p.screen = .gameOver; p.capturingText = false
        p.lock.unlock()
        p.record(m.frameCount, .gameOver(score: mem.r32(a6 + KV.score), section: sec))
    }

    func probeHiscore(rank: Int, score: UInt32, nameAddr: UInt32) {
        guard let p = config.probe else { return }
        let name = String(mem.slice(nameAddr, 16).map { PrintText.glyph($0 == 0x5f ? 0x20 : $0) })
            .trimmingCharacters(in: .whitespaces)
        p.record(m.frameCount, .hiscore(rank: rank, score: score, name: name, mode: hsActiveMode ?? "original"))
    }

    /// k_init (cold start, after a game over, or DEL).
    func probeInit() {
        guard let p = config.probe else { return }
        p.lock.lock()
        let aborted = p.inGame && p.screen != .gameOver && p.screen != .nameEntry
        p.inGame = false; p.inSection = false
        if p.screen != .boot { p.screen = .title }
        p.capturingText = false
        p.lock.unlock()
        if aborted { p.record(m.frameCount, .aborted) }
    }

    func probeSoundFlags() {
        guard let p = config.probe else { return }
        p.record(m.frameCount, .soundFlags(mem.r8(a6 + KV.soundFlags)))
    }

    /// Snapshot resume (at a section main-loop head): the probe's kernel-reported state for a running section.
    func probeResumed() {
        guard let p = config.probe else { return }
        p.lock.lock()
        p.loadedSection = loadedSection; p.inSection = loadedSection >= 0; p.inGame = true
        p.screen = .playing; p.modePC = 0; p.capturingText = false
        p.lock.unlock()
    }

    /// Called once when the game starts: attach the probe and the machine lookup (PlatoonGame.attached).
    func probeAttach() {
        guard let p = config.probe else { return }
        p.lock.lock()
        p.platoon = self
        p.difficulty = enhancements.difficulty
        let early = p.earlyReasons; p.earlyReasons.removeAll()
        p.lock.unlock()
        for r in early { markAssisted(r) }
        if p.autoPoll {
            let prev = m.frameHook
            m.frameHook = { [weak p] mm in prev?(mm); p?.poll(mm) }
        }
    }
}
