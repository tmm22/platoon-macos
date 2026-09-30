import Foundation
import PlatoonCore

// OWNER: [input]. Per-emulated-frame joystick features (host-only; they change only what the virtual joystick
// shows, never game RAM):
//
//  S15 tap stretching: every press and every release of a direction or fire lasts at least N emulated frames, so a
//      short tap is not lost between the tunnels' 4-vblank stick reads or the jungle's 2-3-frame ticks. Double taps
//      still register as two presses (transitions are queued, not merged). Only on play screens (not title, name
//      entry, text screens). Amiga key releases (SPACE, Alt, Y, N) get the same minimum hold (InputManager).
//  M13 toggle-hold: a tap of fire / a direction latches it on, another tap releases it (a direction also releases
//      the opposite one): "tap UP to keep walking" in the tunnels and the final jungle.
//  M13 auto-fire: while fire is held (or the turbo-fire button), fire pulses N frames on / N off (auto: 3 in the
//      jungle, 4 in the tunnels/flare, 2 in the final jungle - at least one game tick each).
//
// Order: raw -> toggle -> stretch -> auto-fire. With every option off `active` is false and the InputManager writes
// the joystick at event time exactly as the original app did.

final class InputPipeline {
    /// Screens where tap stretching applies.
    static let stretchScreens: Set<GameContext.Screen> = [.playing, .manSelect, .trapDoorPrompt]

    // MARK: options
    var stretchFrames = 0            // 0 = off
    var toggleFire = false
    var toggleDirections = false
    /// 0 off, 1 while fire is held, 2 turbo-fire button only.
    var autoFireMode = 0
    /// Frames on (= off) per pulse; 0 = automatic per area.
    var autoFireRate = 0

    var active: Bool { stretchFrames > 0 || toggleFire || toggleDirections || autoFireMode != 0 }

    // MARK: state
    private struct Stretcher {
        var out = false
        var lastChange: UInt64 = 0
        var queue: [Bool] = []
        mutating func push(_ v: Bool) {
            if v == (queue.last ?? out) { return }
            queue.append(v)
            if queue.count > 4 { queue.removeFirst(2) }        // mashing: drop the oldest press+release pair
        }
        mutating func tick(_ f: UInt64, _ minHold: Int) -> Bool {
            if let n = queue.first, f &- lastChange >= UInt64(minHold) || lastChange == 0 {
                queue.removeFirst(); out = n; lastChange = max(f, 1)
            }
            return out
        }
    }
    private var stretch = [Stretcher](repeating: Stretcher(), count: JoyBit.allCases.count)
    private var latched = InputManager.JoyState()
    private var lastRaw = InputManager.JoyState()
    private var autoStart: UInt64?
    /// Frames the auto-fire pulse was on/off in the last run (tests).
    private(set) var pulses = 0
    /// Auto-fire acted in this run (marks it assisted once).
    private var autoFireUsed = false
    var onAutoFireUse: (() -> Void)?
    func newRun() { autoFireUsed = false; pulses = 0 }

    func reset() {
        stretch = [Stretcher](repeating: Stretcher(), count: JoyBit.allCases.count)
        latched = .init(); lastRaw = .init(); autoStart = nil
    }

    private func inPlay(_ c: GameContext?) -> Bool { c?.screen == .playing }

    /// Event time: the merged keyboard/controller state changed.
    func observe(_ raw: InputManager.JoyState, turbo: Bool, context c: GameContext?) {
        guard active else { lastRaw = raw; return }
        let play = inPlay(c)
        // toggle-hold on rising edges
        if play && (toggleFire || toggleDirections) {
            for b in JoyBit.allCases where raw[b] && !lastRaw[b] {
                if b == .fire ? !toggleFire : !toggleDirections { continue }
                if latched[b] { latched[b] = false } else {
                    latched[b] = true
                    if let o = InputPipeline.opposite(b) { latched[o] = false }
                }
            }
        }
        lastRaw = raw
        let t = afterToggle(raw, play)
        if stretchFrames > 0, let c, InputPipeline.stretchScreens.contains(c.screen) {
            for b in JoyBit.allCases { stretch[b.rawValue].push(t[b]) }
        }
    }

    private func afterToggle(_ raw: InputManager.JoyState, _ play: Bool) -> InputManager.JoyState {
        guard play else { return raw }
        var t = raw
        for b in JoyBit.allCases where b == .fire ? toggleFire : toggleDirections { t[b] = latched[b] }
        return t
    }

    static func opposite(_ b: JoyBit) -> JoyBit? {
        switch b { case .up: return .down; case .down: return .up; case .left: return .right; case .right: return .left; case .fire: return nil }
    }

    /// Frame time: the joystick the game sees during this emulated frame.
    func tick(frame f: UInt64, raw: InputManager.JoyState, turbo: Bool, context c: GameContext) -> InputManager.JoyState {
        let play = inPlay(c)
        if !play && latched != .init() { latched = .init() }
        var j = afterToggle(raw, play)
        if stretchFrames > 0, InputPipeline.stretchScreens.contains(c.screen) {
            for b in JoyBit.allCases {
                var s = stretch[b.rawValue]
                if s.queue.isEmpty && s.out != j[b] { s.push(j[b]) }     // state set while not observed
                j[b] = s.tick(f, stretchFrames)
                stretch[b.rawValue] = s
            }
        } else if stretchFrames > 0 {
            for b in JoyBit.allCases { stretch[b.rawValue] = Stretcher(out: j[b], lastChange: 0, queue: []) }
        }
        // auto-fire
        let wantsPulse = play && ((autoFireMode == 1 && j.fire) || (autoFireMode == 2 && turbo))
        if wantsPulse {
            let n = UInt64(autoFireRate > 0 ? autoFireRate : InputPipeline.autoRate(c.area))
            if autoStart == nil { autoStart = f }
            if !autoFireUsed { autoFireUsed = true; onAutoFireUse?() }
            let phase = (f &- autoStart!) / n
            j.fire = phase % 2 == 0
            pulses += 1
        } else {
            autoStart = nil
        }
        return j
    }

    /// Frames per auto-fire half period: at least one game tick on and one off.
    static func autoRate(_ a: GameContext.Area) -> Int {
        switch a {
        case .jungle, .village, .hut: return 3
        case .tunnels, .flare: return 4
        case .finalJungle, .bunker: return 2
        case .none: return 3
        }
    }
}
