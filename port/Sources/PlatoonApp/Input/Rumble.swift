import Foundation
import GameController
import CoreHaptics
import PlatoonCore

// OWNER: [input]. S13 (controller half): rumble on game events, host-only (F2 observers; nothing touches the game).
//   The sound-effect ids mean different things per section (checked in the translated code: $81 is the player's
//   hit in the jungle but the player's bullet hitting a VC in the tunnels and the grenade hitting Barnes in the
//   foxhole; $80 is a VC kill in the jungle but the player's hit in the tunnels), so the mapping is per section:
//     jungle/village: $85 explosion (grenade, trap) strong, $81 player hit medium, $84 enemy fire and $80 kill
//                     light, $82 shot / $0a throw a short tick
//     tunnels/flare:  $80 player hit medium (flare: also a VC kill, light there), $81 VC hit light, $84 enemy fire
//                     light, $82/$83 shots / $0a flare launch a tick
//     final jungle:   $85 grenade explosion strong, foxhole $81 Barnes hit strong, $82 shot / $0a throw a tick
//   plus the probe's wound (medium) and death (heavy) events, the bridge blast ($60c9c -> 2) and the napalm strike
//   (final-jungle timer runs out) from RAM. A medium pulse right after another one is merged (the fx and the wound
//   event of the same hit). fx(0) (F10 click / menu beep) is ignored. Works with the FX muted too. Default off.

final class Rumble {
    static let shared = Rumble()

    struct Pulse: Equatable {
        var intensity: Float, sharpness: Float, duration: Double
        static let tick = Pulse(intensity: 0.35, sharpness: 0.9, duration: 0.04)
        static let light = Pulse(intensity: 0.5, sharpness: 0.6, duration: 0.08)
        static let medium = Pulse(intensity: 0.75, sharpness: 0.4, duration: 0.18)
        static let strong = Pulse(intensity: 1.0, sharpness: 0.25, duration: 0.35)
        static let heavy = Pulse(intensity: 1.0, sharpness: 0.15, duration: 0.8)
    }

    var enabled = false
    var strength: Float = 1
    /// Every pulse played (tests / PLATOON_INPUT_TEST): (frame, name).
    var log: ((UInt64, String) -> Void)?

    /// Pure mapping (tested). `section` = the loaded section (0 jungle, 1 tunnels/flare, 2 final jungle).
    static func pulse(for e: GameEvent, section: Int?, area: GameContext.Area = .none) -> (Pulse, String)? {
        switch e {
        case .fx(let id, _):
            switch (section ?? 0, id) {
            case (_, 0x85): return (.strong, "explosion")
            case (0, 0x81): return (.medium, "hit")
            case (0, 0x84), (1, 0x84): return (.light, "enemy fire")
            case (0, 0x80): return (.light, "kill")
            case (1, 0x80): return area == .flare ? (.light, "flare hit") : (.medium, "hit")
            case (1, 0x81): return (.light, "kill")
            case (2, 0x81) where area == .bunker: return (.strong, "barnes hit")
            case (0, 0x82), (1, 0x82), (1, 0x83), (2, 0x82): return (.tick, "shot")
            case (_, 0x0a): return (.tick, "throw")
            default: return nil
            }
        case .wounded: return (.medium, "wounded")
        case .death: return (.heavy, "death")
        default: return nil
        }
    }

    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]
    private var lastBridge = 0
    private var lastNapalm = false
    private var lastTimer = -1
    private var lastPulseTime: CFTimeInterval = 0
    private var lastPulse: Pulse?

    func install(_ app: AppServices) {
        app.onHostReady { [weak self] host in
            host.probe.addObserver { [weak host] r in
                guard let self, self.enabled, let host else { return }
                let c = host.probe.context
                guard let (p, name) = Rumble.pulse(for: r.event, section: c.loadedSection, area: c.area) else { return }
                self.play(p, name: name, frame: r.frame)
            }
        }
        app.onReset { [weak self] _ in self?.lastBridge = 0; self?.lastNapalm = false; self?.lastTimer = -1 }
        app.onFrame { [weak self] ctx in
            guard let self, self.enabled else { return }
            let g = ctx.game
            let bridge = g.jungle?.bridge ?? 0
            if bridge == 2 && self.lastBridge != 2 && g.section == 0 { self.play(.heavy, name: "bridge", frame: ctx.frame) }
            self.lastBridge = bridge
            // section 2 ends in the napalm strike when the timer ticks down to 00:00 (s2 main loop -> s2_time_up)
            let t = g.timerMinutes * 60 + g.timerSeconds
            let napalm = g.section == 2 && g.inGame && t == 0
            if napalm && !self.lastNapalm && self.lastTimer > 0 && self.lastTimer <= 2 { self.play(.heavy, name: "napalm", frame: ctx.frame) }
            self.lastNapalm = napalm
            self.lastTimer = g.section == 2 ? t : -1
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.engines[ObjectIdentifier(c)]?.stop(); self?.engines[ObjectIdentifier(c)] = nil }
        }
    }

    func play(_ p: Pulse, name: String, frame: UInt64) {
        log?(frame, name)
        // several small events in one frame: keep the strongest recent one only
        let now = CACurrentMediaTime()
        if p.intensity < 0.6 && now - lastPulseTime < 0.05 { return }
        // the fx and the polled wound event of one hit arrive a frame or two apart: one pulse
        if p == .medium && lastPulse == .medium && now - lastPulseTime < 0.15 { return }
        lastPulseTime = now; lastPulse = p
        for c in GCController.controllers() {
            guard let e = engine(c) else { continue }
            let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, p.intensity * strength)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: p.sharpness),
            ], relativeTime: 0, duration: p.duration)
            if let pattern = try? CHHapticPattern(events: [ev], parameters: []), let player = try? e.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }
    }

    private func engine(_ c: GCController) -> CHHapticEngine? {
        let id = ObjectIdentifier(c)
        if let e = engines[id] { return e }
        guard let h = c.haptics, let e = h.createEngine(withLocality: .default) else { return nil }
        e.isAutoShutdownEnabled = true
        e.resetHandler = { [weak e] in try? e?.start() }
        try? e.start()
        engines[id] = e
        return e
    }
}
