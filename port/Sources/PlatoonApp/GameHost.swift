import Foundation
import QuartzCore
import PlatoonCore

/// Owns the running game and paces it at 50 Hz (PAL) independent of the display refresh rate.
final class GameHost {
    let disk: Disk
    private(set) var machine: Machine
    let audio = AudioOutput()
    let inputManager = InputManager()
    var turbo = false
    var paused = false { didSet { if paused { inputManager.releaseAll() }; last = 0 } }
    private var last: CFTimeInterval = 0
    private var acc: Double = 0
    static let frameTime = 1.0 / 50.0

    init(disk: Disk) {
        self.disk = disk
        machine = Machine(disk: disk)
        wire()
        machine.start { PlatoonGame.main($0, config: GameHost.gameConfig()) }
    }

    static func gameConfig() -> GameConfig {
        var c = GameConfig()
        if let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = sup.appendingPathComponent("Platoon", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            c.hiscoreURL = dir.appendingPathComponent("hiscores.bin")
        }
        c.onSectionStart = { section, a6 in
            // Section 0 re-initialises the platoon, so only the later sections are worth continuing from.
            guard section > 0 else { return }
            Settings.shared.continueSection = section
            Settings.shared.continueCarry = Data(a6)
        }
        return c
    }

    static func applyCheats(_ m: Machine) {
        let s = Settings.shared
        Trainer(infiniteAmmo: s.cheatAmmo, infiniteMorale: s.cheatMorale, invulnerable: s.cheatInvulnerable).apply(to: m)
    }

    private func wire() {
        machine.frameHook = { GameHost.applyCheats($0) }
        machine.chip.paula.output = { [audio] in audio.push($0) }
        inputManager.input = machine.input
        applyAudioSettings()
    }

    func applyAudioSettings() {
        let s = Settings.shared, p = machine.chip.paula
        p.interpolate = s.interpolate; p.filterEnabled = s.a500Filter
        p.stereoSeparation = Float(s.separation); p.volume = Float(s.volume)
    }

    /// Taps an Amiga key (press now, release a few frames later).
    func tapKey(_ code: UInt8) {
        machine.input.key(code, down: true)
        machine.input.key(code, down: false)
    }

    func reset(startSection: Int? = nil, carry: [UInt8]? = nil) {
        machine.stop()
        machine = Machine(disk: disk)
        wire()
        audio.flush()
        var cfg = GameHost.gameConfig()
        cfg.startSection = startSection
        cfg.carry = carry
        machine.start { PlatoonGame.main($0, config: cfg) }
        acc = 0; last = 0
    }

    /// Runs as many emulated frames as are due. Returns true if a new frame was produced.
    @discardableResult func tick() -> Bool {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard !paused, last > 0 else { return false }
        let dt = min(0.25, now - last)
        let perTick = turbo ? 4 : 1
        // Display running at ~50 Hz (e.g. a variable-refresh display): one Amiga frame per display frame,
        // so every frame is shown exactly once and scrolling stays perfectly smooth.
        if abs(dt - GameHost.frameTime) < GameHost.frameTime * 0.15 {
            for _ in 0..<perTick { machine.runFrame() }
            acc = 0
            return true
        }
        acc += dt
        var ran = false, n = 0
        while acc >= GameHost.frameTime && n < 5 {
            for _ in 0..<perTick { machine.runFrame() }
            acc -= GameHost.frameTime; ran = true; n += 1
        }
        if n == 5 { acc = 0 }
        return ran
    }

}
