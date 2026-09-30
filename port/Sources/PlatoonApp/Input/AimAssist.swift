import AppKit
import PlatoonCore

// OWNER: [input]. L2 (a) assisted pointer / analog aiming for the crosshair parts of section 1 (tunnel combat, room
// search, flare dugout). Host-only: every frame (Machine.frameHook, game parked) it reads where the crosshair is
// (TunnelAim.info, section-1 agent: RAM $19d34/$19d36, flare $19eae/$19eb0, byte column $3b3f8) and presses the
// VIRTUAL STICK towards the target, so the original pacing, acceleration ($1a0ae) and bounds stay in force:
//  - the target is the mouse / trackpad pointer over the game image (active while it moves or a button is held),
//    or the right stick (proportional: the target leads the crosshair by the deflection);
//  - one axis at a time (the flare's up-skips-left branch), and the stick is released when the next step (predicted
//    from the current crossSpeed) would overshoot, so it settles on the target instead of oscillating;
//  - left click = fire, right click = SPACE (flare);
//  - any keyboard/controller direction the player presses wins.
// With the section-1 gameplay option s1.directAim (L2 b) on, the target is handed to the game instead
// (TunnelAim.setTarget) and the stick is left alone. Aiming assistance marks the run assisted.

final class AimAssist {
    /// 0 off, 1 on (pointer + right stick).
    var enabled = false
    /// Right-stick lead in visible pixels at full deflection.
    var stickLead: Double = 40
    var active: Bool { enabled }

    // pointer (main thread, from the event monitor / display tick)
    /// Pointer position in visible-screen lowres coordinates (0..319 x 0..255), nil = outside the game image.
    var pointer: CGPoint?
    var pointerMovedAt: CFTimeInterval = 0
    var leftDown = false, rightDown = false
    /// Seconds a still pointer keeps steering.
    var pointerTimeout: Double = 1.5

    struct Output {
        /// Directions to show (nil = leave the player's directions alone).
        var directions: InputManager.JoyState?
        var fire = false
        var spaceDown = false
    }

    /// Last decision (tests / overlay).
    private(set) var lastTarget: CGPoint?
    private(set) var lastInfo: TunnelAim.Info?
    private(set) var usedThisRun = false
    private var directTargetSet: ObjectIdentifier?
    var onFirstUse: (() -> Void)?

    func releaseAll() { leftDown = false; rightDown = false }
    func newRun() { usedThisRun = false; directTargetSet = nil }

    var pointerActive: Bool {
        pointer != nil && (leftDown || rightDown || CACurrentMediaTime() - pointerMovedAt < pointerTimeout)
    }

    /// Step the game will move the crosshair at its next read if the stick is held now (visible pixels).
    static func nextStep(_ mode: TunnelAim.Mode, crossSpeed: Int) -> Double {
        switch mode {
        case .tunnelCombat: return Double(max(2, crossSpeed))
        case .tunnelRoom: return Double(max(1, crossSpeed >> 2))
        case .flare: return Double(max(2, crossSpeed >> 1))
        }
    }

    /// The directions that move the crosshair from `c` towards `t` without overshooting (one axis at a time).
    static func steer(from c: CGPoint, to t: CGPoint, step: Double) -> InputManager.JoyState {
        var j = InputManager.JoyState()
        let dx = Double(t.x - c.x), dy = Double(t.y - c.y)
        // pressing moves by `step`: worth it only if that reduces the error (step < 2|d|)
        let okX = 2 * abs(dx) > step, okY = 2 * abs(dy) > step
        if okX && (!okY || abs(dx) >= abs(dy)) { if dx > 0 { j.right = true } else { j.left = true } }
        else if okY { if dy > 0 { j.down = true } else { j.up = true } }
        return j
    }

    func tick(machine m: Machine, context c: GameContext, userDirections: Bool, stick: CGPoint, directAim: Bool) -> Output? {
        guard enabled, c.screen == .playing, c.area == .tunnels || c.area == .flare else { clearDirect(m); lastInfo = nil; return nil }
        var out = Output()
        let pointerOn = pointerActive
        if pointerOn {
            out.fire = leftDown
            out.spaceDown = rightDown && c.area == .flare
        }
        guard let info = TunnelAim.info(m.memory, area: c.area) else { clearDirect(m); lastInfo = nil; return out }
        lastInfo = info
        var target: CGPoint?
        if pointerOn, let p = pointer {
            target = p
        } else if hypot(stick.x, stick.y) > 0.25 {
            // proportional: the target leads the crosshair by the deflection (y up on the stick)
            target = CGPoint(x: info.centre.x + Double(stick.x) * stickLead, y: info.centre.y - Double(stick.y) * stickLead)
        }
        guard var t = target, !userDirections else { clearDirect(m); lastTarget = nil; return out }
        t.x = min(max(t.x, info.bounds.minX), info.bounds.maxX)
        t.y = min(max(t.y, info.bounds.minY), info.bounds.maxY)
        lastTarget = t
        if !usedThisRun { usedThisRun = true; onFirstUse?() }
        if directAim {
            TunnelAim.setTarget(m, x: Double(t.x), y: Double(t.y))
            directTargetSet = ObjectIdentifier(m)
            out.directions = InputManager.JoyState()           // the stick stays neutral
            return out
        }
        clearDirect(m)
        let speed = Int(m.memory.r16(0x1a0ae))
        let step = AimAssist.nextStep(info.mode, crossSpeed: speed)
        out.directions = AimAssist.steer(from: CGPoint(x: info.centre.x, y: info.centre.y), to: t, step: step)
        return out
    }

    private func clearDirect(_ m: Machine) {
        if directTargetSet != nil { TunnelAim.clearTarget(m); directTargetSet = nil }
    }

    // MARK: pointer tracking (main thread)

    private var monitor: Any?

    /// Mouse / trackpad over the game image -> visible-screen coordinates (inverse of OverlayLayout.point).
    static func visible(_ pInOverlay: CGPoint, _ l: OverlayLayout) -> CGPoint? {
        guard l.gameRect.width > 0, l.gameRect.contains(pInOverlay) else { return nil }
        let cx = Double(pInOverlay.x - l.gameRect.minX) / Double(l.scaleX)
        let cy = Double(pInOverlay.y - l.gameRect.minY) / Double(l.scaleY)
        return CGPoint(x: cx - Double(0x71 - 0x60) + Double(l.crop.x) / 2, y: cy - Double(0x2c - 0x18) + Double(l.crop.y))
    }

    func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .leftMouseDragged, .rightMouseDragged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e); return e
        }
    }

    private func handle(_ e: NSEvent) {
        guard enabled, let w = AppServices.shared.window, e.window === w else { return }
        let overlay = AppServices.shared.overlay
        if overlay.modalPanel != nil { leftDown = false; rightDown = false; return }
        let p = overlay.view.convert(e.locationInWindow, from: nil)
        pointer = AimAssist.visible(p, overlay.layoutInfo)
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged: pointerMovedAt = CACurrentMediaTime()
        case .leftMouseDown: if pointer != nil { leftDown = true; pointerMovedAt = CACurrentMediaTime() }
        case .leftMouseUp: leftDown = false
        case .rightMouseDown: if pointer != nil { rightDown = true; pointerMovedAt = CACurrentMediaTime() }
        case .rightMouseUp: rightDown = false
        default: break
        }
        if pointer == nil { leftDown = false; rightDown = false }
    }
}
