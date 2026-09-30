import AppKit
import GameController
import PlatoonCore

/// Logical controller buttons (for modal overlays such as the pause menu, and for feature hooks).
/// rsUp/rsDown/rsLeft/rsRight are the right stick used as a d-pad (only when bound, e.g. the right-half preset).
enum PadButton: String, CaseIterable, Codable {
    case up, down, left, right, a, b, x, y, lb, rb, lt, rt, l3, r3, menu, options
    case rsUp, rsDown, rsLeft, rsRight
}

/// Keyboard + game controller -> Amiga joystick port 2 and keyboard.
///
/// OWNER: [input]. Layers (all host-only; the translated game only ever sees Input's joystick bits and key events):
///  1. Bindings (M7, Input/Bindings.swift): logical actions -> keys / controller buttons. The default binding set is
///     the original app's table; keys not bound to an action pass through the Amiga keyboard table
///     (`amigaKeys`, letters by character on non-US layouts: S3, Input/KeyLayout.swift).
///  2. Controller extras (S2): buttons that did nothing before (X = SPACE, Y = change soldier tap, LB/LT = Y/N) and
///     the trap-door context (A = fire + Y, B = fire + N, fresh presses only).
///  3. Per-frame pipeline (Input/InputPipeline.swift), run from Machine.frameHook through `frameTick`: tap
///     stretching (S15), toggle-hold and auto-fire (M13), assisted aiming (L2a), timed key taps, M14 host buttons.
///     With every option off the joystick is written at event time exactly as before.
/// Host features from [app]: per-controller state OR-ed together; a disconnected controller's state is cleared;
/// `suspend()` / `resume()` with resume-press swallowing (S4); `padButtonSink` for modal overlays / host buttons;
/// interceptors `keyInterceptors`, `padInterceptors`, `joyTransforms`.
final class InputManager {
    weak var input: Input?
    /// Tests: receives every Amiga key event instead of `input` (InputSelfTest).
    var keySink: ((UInt8, Bool) -> Void)?
    private func sendKey(_ k: UInt8, _ down: Bool) { if let s = keySink { s(k, down) } else { input?.key(k, down: down) } }

    // MARK: original mapping tables (the passthrough keyboard table; the Original preset reproduces the rest)
    // Mac virtual keycodes used for the joystick by the original app (kept for reference / the self-test)
    static var joyUp: Set<UInt16> = [0x7e], joyDown: Set<UInt16> = [0x7d], joyLeft: Set<UInt16> = [0x7b], joyRight: Set<UInt16> = [0x7c]
    static var joyFire: Set<UInt16> = [0x31, 0x06]  // space, Z

    // Mac keycode -> Amiga raw keycode (US positions)
    static var amigaKeys: [UInt16: UInt8] = [
        0x32: 0x00, 0x12: 0x01, 0x13: 0x02, 0x14: 0x03, 0x15: 0x04, 0x17: 0x05, 0x16: 0x06, 0x1a: 0x07, 0x1c: 0x08, 0x19: 0x09, 0x1d: 0x0a,
        0x1b: 0x0b, 0x18: 0x0c, 0x2a: 0x0d,
        0x0c: 0x10, 0x0d: 0x11, 0x0e: 0x12, 0x0f: 0x13, 0x11: 0x14, 0x10: 0x15, 0x20: 0x16, 0x22: 0x17, 0x1f: 0x18, 0x23: 0x19, 0x21: 0x1a, 0x1e: 0x1b,
        0x00: 0x20, 0x01: 0x21, 0x02: 0x22, 0x03: 0x23, 0x05: 0x24, 0x04: 0x25, 0x26: 0x26, 0x28: 0x27, 0x25: 0x28, 0x29: 0x29, 0x27: 0x2a,
        0x06: 0x31, 0x07: 0x32, 0x08: 0x33, 0x09: 0x34, 0x0b: 0x35, 0x2d: 0x36, 0x2e: 0x37, 0x2b: 0x38, 0x2f: 0x39, 0x2c: 0x3a,
        0x31: 0x40, 0x33: 0x41, 0x30: 0x42, 0x4c: 0x43, 0x24: 0x44, 0x35: 0x45, 0x75: 0x46,
        0x7e: 0x4c, 0x7d: 0x4d, 0x7c: 0x4e, 0x7b: 0x4f,
        0x7a: 0x50, 0x78: 0x51, 0x63: 0x52, 0x76: 0x53, 0x60: 0x54, 0x61: 0x55, 0x62: 0x56, 0x64: 0x57, 0x65: 0x58, 0x6d: 0x59, 0x72: 0x5f,
        // keypad
        0x52: 0x0f, 0x53: 0x1d, 0x54: 0x1e, 0x55: 0x1f, 0x56: 0x2d, 0x57: 0x2e, 0x58: 0x2f, 0x59: 0x3d, 0x5b: 0x3e, 0x5c: 0x3f,
        0x41: 0x3c, 0x4e: 0x4a, 0x45: 0x5e, 0x43: 0x5d, 0x4b: 0x5c,
        // laptop substitutes: F11 = HELP, F12 = keypad minus (needed for the MEGA CHEAT code)
        0x67: 0x5f, 0x6f: 0x4a,
    ]
    // modifier keys (arrive as flagsChanged): Mac keycode -> Amiga keycode
    static var modifierKeys: [UInt16: UInt8] = [0x3a: 0x64, 0x3d: 0x65, 0x38: 0x60, 0x3c: 0x61, 0x3b: 0x63, 0x3e: 0x63]
    static let capsLock: UInt16 = 0x39
    /// Amiga keys that type a character in the level-2 keymap (name entry): they are not joystick keys while the
    /// name is typed on the keyboard (S18).
    static let typingAmigaKeys: Set<UInt8> = Set(Array(0x00...0x0d) + Array(0x10...0x1b) + Array(0x20...0x2a) + Array(0x31...0x3a) + [0x40, 0x41, 0x44])

    // MARK: feature hooks. All run on the main thread.
    /// Consulted for every key down/up before the default mapping; return true to consume the event.
    /// (Host hotkeys such as Esc / fast-forward are handled by the app before these.)
    var keyInterceptors: [(_ code: UInt16, _ down: Bool, _ event: NSEvent?) -> Bool] = []
    /// Consulted for every controller button edge before the default mapping; return true to consume it
    /// (the button then doesn't contribute to the joystick / TAB / F10 until released).
    var padInterceptors: [(_ button: PadButton, _ down: Bool) -> Bool] = []
    /// Applied to the joystick state after keyboard + controllers are merged, before it is written to Input.
    var joyTransforms: [(inout JoyState) -> Void] = []
    /// Host-level controller button sink (modal overlays, pause-menu long press, fast-forward): return true to
    /// consume. Set by the app.
    var padButtonSink: ((PadButton, Bool) -> Bool)?
    /// Controller connected / disconnected (after the state was updated).
    var onControllerChange: ((_ connected: Bool, _ controller: GCController) -> Void)?
    /// Controls window: the next controller button press is delivered here instead of the game (M7 capture).
    var capturePad: ((PadButton) -> Void)?

    struct JoyState: Equatable { var up = false, down = false, left = false, right = false, fire = false }

    // MARK: configuration (input agent)
    /// The binding table (M7). Setting it re-resolves every key.
    var bindings = BindingSet.standard { didSet { resolverGeneration = -1; sync() } }
    /// S2 trap-door context for controller fire buttons.
    var padContext = true
    /// Stick dead zone (d-pad + left stick, right stick as buttons).
    var deadZone: Float = 0.4
    /// Frames a controller "tap" (change soldier, context Y/N) holds its Amiga key.
    var padTapFrames = 5
    /// Per-frame features (S15, M13, L2a).
    let pipeline = InputPipeline()
    let aim = AimAssist()
    /// M14: write jump/crouch host buttons (set by the install hook when the run has s0.explicitJumpCrouch).
    var m14Enabled = false

    // MARK: state
    /// Keys physically held (Mac keycodes incl. modifiers), and the subset whose press was forwarded to the game.
    private var physicalKeys = Set<UInt16>()
    private var keysDown = Set<UInt16>()
    /// Keys held when input resumed: ignored until released.
    private var swallowedKeys = Set<UInt16>()
    private(set) var suspended = false
    /// What each forwarded key press did (so the release undoes exactly that, even if bindings changed meanwhile).
    struct KeyOutput: Equatable {
        var amiga: [UInt8] = []
        var joy = Set<JoyBit>()
        var host = Set<InputAction>()
        /// The key types a character in the name entry (its joystick bits are ignored while typing, S18).
        var typing = false
    }
    private var pressed: [UInt16: KeyOutput] = [:]
    /// Amiga keys held by the host (reference counts: several Mac keys / buttons / taps may hold the same key).
    private var amigaHeld: [UInt8: Int] = [:]
    private var amigaDownFrame: [UInt8: UInt64] = [:]
    /// Deferred releases (taps, S15 minimum hold): each entry holds one reference until `frame`.
    private var pendingUps: [(key: UInt8, frame: UInt64)] = []
    /// Emulated frame number of the last frameTick (0 before the first).
    private(set) var frame: UInt64 = 0
    /// F1 context as of the last emulated frame (nil before the first).
    private(set) var context: GameContext?

    private final class Pad {
        let controller: GCController
        var buttons = Set<PadButton>()      // physically pressed
        var rightStick = CGPoint.zero
        init(_ c: GCController) { controller = c }
    }
    private var pads: [ObjectIdentifier: Pad] = [:]
    /// Buttons consumed by a sink/interceptor or swallowed at resume: ignored until released.
    private var padIgnored = Set<PadButton>()
    /// Amiga keys a controller button holds (released with the button).
    private var padKeysSent: [PadButton: [UInt8]] = [:]
    /// Controller buttons the app keeps for itself (never mapped to the game): e.g. .l3 for fast-forward.
    var hostPadButtons = Set<PadButton>()

    var controllerCount: Int { pads.count }
    var controllers: [GCController] { pads.values.map(\.controller) }
    /// Right stick of all controllers (strongest deflection), x right, y up; -1...1.
    var rightStick: CGPoint {
        var best = debugRightStick
        for p in pads.values where hypot(p.rightStick.x, p.rightStick.y) > hypot(best.x, best.y) { best = p.rightStick }
        return best
    }
    var debugRightStick = CGPoint.zero

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.detach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    // MARK: key resolution

    private var resolverGeneration = -1
    private var keyActions: [UInt16: [InputAction]] = [:]

    private func rebuildResolver() {
        guard resolverGeneration != KeyLayout.generation else { return }
        resolverGeneration = KeyLayout.generation
        var t: [UInt16: [InputAction]] = [:]
        for a in InputAction.allCases {
            for k in bindings[a].keys { if let c = k.keycode, !(t[c]?.contains(a) ?? false) { t[c, default: []].append(a) } }
        }
        keyActions = t
    }

    /// The Amiga key Mac key `code` types when it is not bound to an Amiga-key action.
    static func passthrough(_ code: UInt16) -> UInt8? {
        if let m = modifierKeys[code] { return m }
        if InputSettings.layoutLetters, let us = KeyLayout.usEquivalent(code) { return amigaKeys[us] }
        return amigaKeys[code]
    }

    /// What pressing Mac key `code` does now.
    func resolve(_ code: UInt16) -> KeyOutput {
        rebuildResolver()
        let acts = keyActions[code] ?? []
        var out = KeyOutput()
        let base = InputManager.passthrough(code)
        out.typing = base.map { InputManager.typingAmigaKeys.contains($0) } ?? false
        let keys = acts.compactMap(\.amigaKey)
        out.amiga = keys.isEmpty ? (base.map { [$0] } ?? []) : Array(Set(keys)).sorted()
        for a in acts {
            if a == .turboFire { out.host.insert(a) } else if let j = a.joyBit { out.joy.insert(j) }
            if a == .jump || a == .crouch { out.host.insert(a) }
        }
        return out
    }

    // MARK: Amiga keys (reference counted, frame-timed releases)

    private func amigaPress(_ k: UInt8) {
        let n = amigaHeld[k, default: 0]
        amigaHeld[k] = n + 1
        if n == 0 { sendKey(k, true); amigaDownFrame[k] = frame }
    }
    private func amigaRelease(_ k: UInt8, minHold: Int = 0) {
        guard let n = amigaHeld[k], n > 0 else { return }
        if minHold > 0, let d = amigaDownFrame[k], frame < d &+ UInt64(minHold), n == 1 {
            pendingUps.append((k, d &+ UInt64(minHold)))       // keeps the reference until then
            return
        }
        if n == 1 { amigaHeld[k] = nil; sendKey(k, false) } else { amigaHeld[k] = n - 1 }
    }
    /// Presses Amiga key `k` for `frames` emulated frames (controller taps).
    func amigaTap(_ k: UInt8, frames: Int) {
        amigaPress(k)
        pendingUps.append((k, frame &+ UInt64(max(1, frames))))
    }
    /// S15: minimum hold for released Amiga keys (0 = off, or outside the play screens).
    private var keyMinHold: Int {
        guard pipeline.stretchFrames > 0, let c = context, InputPipeline.stretchScreens.contains(c.screen) else { return 0 }
        return pipeline.stretchFrames
    }

    // MARK: keyboard

    /// A modifier key changed state (NSEvent flagsChanged).
    func modifierChanged(_ code: UInt16, flags: NSEvent.ModifierFlags) {
        if code == InputManager.capsLock {           // Amiga CAPS LOCK is a normal key: send a tap per toggle
            if suspended { return }
            sendKey(0x62, true); sendKey(0x62, false); return
        }
        guard InputManager.modifierKeys[code] != nil else { return }
        // Left and right modifiers share one class flag: use the device-dependent bits (NX_DEVICEL/R*KEYMASK)
        // so releasing one Option while the other is held is seen. Synthetic events without them: toggle.
        let raw = flags.rawValue
        let device: UInt
        let cls: NSEvent.ModifierFlags
        switch code {
        case 0x3a: device = 0x20; cls = .option
        case 0x3d: device = 0x40; cls = .option
        case 0x38: device = 0x02; cls = .shift
        case 0x3c: device = 0x04; cls = .shift
        case 0x3b: device = 0x01; cls = .control
        default: device = 0x2000; cls = .control
        }
        let isDown: Bool
        if !flags.contains(cls) { isDown = false }
        else if raw & 0x2067 != 0 { isDown = raw & device != 0 }
        else { isDown = !physicalKeys.contains(code) }
        if isDown {
            guard !physicalKeys.contains(code) else { return }
            physicalKeys.insert(code); swallowedKeys.remove(code)
            if suspended || keysDown.contains(code) { return }
            press(code)
        } else {
            guard physicalKeys.contains(code) || keysDown.contains(code) else { return }
            physicalKeys.remove(code)
            if swallowedKeys.remove(code) != nil { return }
            if keysDown.contains(code) { release(code) }
        }
    }

    func keyDown(_ code: UInt16, isRepeat: Bool, event: NSEvent? = nil) {
        if isRepeat { return }
        physicalKeys.insert(code)
        swallowedKeys.remove(code)          // a fresh (non-repeat) press: its earlier release was missed
        if suspended { return }
        for f in keyInterceptors where f(code, true, event) { return }
        if keysDown.contains(code) { return }
        press(code)
    }
    func keyUp(_ code: UInt16, event: NSEvent? = nil) {
        physicalKeys.remove(code)
        if swallowedKeys.remove(code) != nil { return }
        guard keysDown.contains(code) else {
            // not forwarded (suspended / consumed): still let interceptors see the release
            for f in keyInterceptors where f(code, false, event) { return }
            return
        }
        for f in keyInterceptors where f(code, false, event) { break }
        release(code)
    }

    private func press(_ code: UInt16) {
        var out = resolve(code)
        // S18: while the name is typed on the keyboard, a key that types a character types it, whatever action it
        // is bound to (e.g. Return = SPACE in the right-hand preset must still finish the name, E = change soldier
        // in the left-hand preset types E). Its joystick bits are ignored in `merged` meanwhile.
        if keyboardFireSuppressed && out.typing, let base = InputManager.passthrough(code) { out.amiga = [base] }
        keysDown.insert(code)
        pressed[code] = out
        for k in out.amiga { amigaPress(k) }
        sync()
    }
    private func release(_ code: UInt16) {
        keysDown.remove(code)
        let out = pressed.removeValue(forKey: code) ?? KeyOutput()
        let hold = keyMinHold
        for k in out.amiga { amigaRelease(k, minHold: hold) }
        sync()
    }

    /// Releases everything the game currently sees as held (window lost focus, pause, reset).
    func releaseAll() {
        keysDown.removeAll(); pressed.removeAll()
        for (k, _) in amigaHeld.sorted(by: { $0.key < $1.key }) { sendKey(k, false) }
        amigaHeld.removeAll(); pendingUps.removeAll(); padKeysSent.removeAll()
        padIgnored.formUnion(allPadButtons)
        pipeline.reset()
        aim.releaseAll()
        sync()
    }
    /// After a focus change the physical key state is unknown: forget it too.
    func forgetPhysicalKeys() {
        physicalKeys.removeAll(); swallowedKeys.removeAll()
    }

    // MARK: host pause

    /// Stops all input to the game (host pause). Held keys/buttons are released as far as the game is concerned.
    func suspend() {
        guard !suspended else { return }
        releaseAll()
        suspended = true
    }
    /// Re-enables input. Anything still held is ignored until it is released.
    func resume() {
        guard suspended else { return }
        suspended = false
        swallowedKeys = physicalKeys
        padIgnored = allPadButtons
        sync()
    }

    // MARK: controllers

    private var allPadButtons: Set<PadButton> { pads.values.reduce(into: debugPadButtons) { $0.formUnion($1.buttons) } }
    /// Buttons held by a virtual controller (debug scripts / tests).
    private var debugPadButtons = Set<PadButton>()

    /// Presses / releases a button of a virtual controller (debug scripts / tests): same path as a real pad.
    func injectPad(_ b: PadButton, down: Bool) {
        let before = allPadButtons
        if down { debugPadButtons.insert(b) } else { debugPadButtons.remove(b) }
        let after = allPadButtons
        if before.contains(b) != after.contains(b) { buttonEdge(b, down: down) }
        sync()
    }
    /// Current merged joystick state as last written to Input (tests).
    var debugJoy: JoyState { JoyState(up: input?.up ?? false, down: input?.down ?? false, left: input?.left ?? false, right: input?.right ?? false, fire: input?.fire ?? false) }
    /// Simulates a controller disconnect for every virtual button (tests).
    func injectDisconnect() {
        let held = debugPadButtons
        debugPadButtons.removeAll()
        debugRightStick = .zero
        for b in held where !allPadButtons.contains(b) { buttonEdge(b, down: false) }
        sync()
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        let id = ObjectIdentifier(c)
        if pads[id] == nil { pads[id] = Pad(c) }
        pad.valueChangedHandler = { [weak self] g, _ in self?.padChanged(id, g) }
        onControllerChange?(true, c)
    }

    private func detach(_ c: GCController) {
        let id = ObjectIdentifier(c)
        guard let p = pads.removeValue(forKey: id) else { return }
        c.extendedGamepad?.valueChangedHandler = nil
        for b in p.buttons where !allPadButtons.contains(b) { buttonEdge(b, down: false) }
        sync()
        onControllerChange?(false, c)
    }

    static func buttons(_ g: GCExtendedGamepad, deadZone dz: Float = 0.4) -> Set<PadButton> {
        var s = Set<PadButton>()
        let x = max(-1, min(1, g.dpad.xAxis.value + g.leftThumbstick.xAxis.value))
        let y = max(-1, min(1, g.dpad.yAxis.value + g.leftThumbstick.yAxis.value))
        if x < -dz { s.insert(.left) }; if x > dz { s.insert(.right) }
        if y > dz { s.insert(.up) }; if y < -dz { s.insert(.down) }
        let rx = g.rightThumbstick.xAxis.value, ry = g.rightThumbstick.yAxis.value
        if rx < -dz { s.insert(.rsLeft) }; if rx > dz { s.insert(.rsRight) }
        if ry > dz { s.insert(.rsUp) }; if ry < -dz { s.insert(.rsDown) }
        if g.buttonA.isPressed { s.insert(.a) }; if g.buttonB.isPressed { s.insert(.b) }
        if g.buttonX.isPressed { s.insert(.x) }; if g.buttonY.isPressed { s.insert(.y) }
        if g.leftShoulder.isPressed { s.insert(.lb) }; if g.rightShoulder.isPressed { s.insert(.rb) }
        if g.leftTrigger.isPressed { s.insert(.lt) }; if g.rightTrigger.isPressed { s.insert(.rt) }
        if g.leftThumbstickButton?.isPressed == true { s.insert(.l3) }
        if g.rightThumbstickButton?.isPressed == true { s.insert(.r3) }
        if g.buttonMenu.isPressed { s.insert(.menu) }
        if g.buttonOptions?.isPressed == true { s.insert(.options) }
        return s
    }

    private func padChanged(_ id: ObjectIdentifier, _ g: GCExtendedGamepad) {
        guard let p = pads[id] else { return }
        let before = allPadButtons
        p.buttons = InputManager.buttons(g, deadZone: deadZone)
        p.rightStick = CGPoint(x: CGFloat(g.rightThumbstick.xAxis.value), y: CGFloat(g.rightThumbstick.yAxis.value))
        let after = allPadButtons
        for b in PadButton.allCases where before.contains(b) != after.contains(b) { buttonEdge(b, down: after.contains(b)) }
        sync()
    }

    /// A merged button changed state.
    private func buttonEdge(_ b: PadButton, down: Bool) {
        if down, let cap = capturePad { capturePad = nil; padIgnored.insert(b); cap(b); return }
        if !down && padIgnored.remove(b) != nil {
            for k in padKeysSent.removeValue(forKey: b) ?? [] { amigaRelease(k) }
            _ = padButtonSink?(b, false)       // let the sink see releases of what it consumed (long-press timing)
            return
        }
        if down {
            if padButtonSink?(b, true) == true { padIgnored.insert(b); return }
            if suspended { padIgnored.insert(b); return }
            for f in padInterceptors where f(b, true) { padIgnored.insert(b); return }
        } else {
            if padButtonSink?(b, false) == true { return }
            for f in padInterceptors where f(b, false) { break }
        }
        if hostPadButtons.contains(b) { return }
        padAction(b, down: down)
    }

    /// Amiga-key actions of a controller button (the joystick part is merged in `sync`).
    private func padAction(_ b: PadButton, down: Bool) {
        let acts = bindings.actions(forPad: b)
        if down {
            var held: [UInt8] = []
            for a in acts {
                guard let k = a.amigaKey else { continue }
                if a.padTap { amigaTap(k, frames: padTapFrames) } else { amigaPress(k); held.append(k) }
            }
            // S2 context layer: at the trap-door prompt a fresh press of a fire button answers (A = yes, B = no; a
            // button bound to SPACE = no). Only fresh presses: a fire held into the prompt doesn't answer.
            // The answering press is consumed (no fire), so after "No" the player doesn't shoot on return to the
            // jungle while the button is still held.
            if padContext, context?.screen == .trapDoorPrompt, acts.contains(.fire) || acts.contains(.space) {
                amigaTap(acts.contains(.fire) && b != .b ? 0x15 : 0x36, frames: padTapFrames + 1)
                padIgnored.insert(b)
            }
            if !held.isEmpty { padKeysSent[b, default: []] += held }
        } else {
            let hold = keyMinHold
            for k in padKeysSent.removeValue(forKey: b) ?? [] { amigaRelease(k, minHold: hold) }
        }
    }

    /// Sends a TAB tap as if the controller Menu button had been pressed and released (pause-menu long-press
    /// mode sends TAB on release of a short press).
    func tapPadMenu() { sendKey(0x42, true); sendKey(0x42, false) }

    /// S18 keyboard name entry: keyboard keys that type don't press joystick buttons (letters and Space type).
    var keyboardFireSuppressed = false { didSet { if keyboardFireSuppressed != oldValue { sync() } } }

    // MARK: joystick merge

    /// Host actions (jump, crouch, turbo fire) held now by keys or buttons.
    private(set) var hostActions = Set<InputAction>()
    /// Keyboard/controller joystick before the per-frame pipeline (tests).
    private(set) var rawJoy = JoyState()

    private func merged() -> JoyState {
        let live = allPadButtons.subtracting(padIgnored).subtracting(hostPadButtons)
        var j = JoyState()
        var host = Set<InputAction>()
        guard !suspended else { hostActions = []; return j }
        for b in live {
            for a in bindings.actions(forPad: b) {
                if a == .turboFire || a == .jump || a == .crouch { host.insert(a) } else if let bit = a.joyBit { j[bit] = true }
            }
        }
        for c in keysDown {
            guard let o = pressed[c] else { continue }
            host.formUnion(o.host)
            if keyboardFireSuppressed && o.typing { continue }
            for bit in o.joy { j[bit] = true }
        }
        for t in joyTransforms { t(&j) }
        hostActions = host
        return j
    }

    private func sync() {
        guard let i = input else { return }
        rawJoy = merged()
        pipeline.observe(rawJoy, turbo: hostActions.contains(.turboFire), context: context)
        if pipeline.active || aimEngaged { return }       // the per-frame pipeline writes Input (frameTick)
        write(rawJoy, to: i)
    }
    private func write(_ j: JoyState, to i: Input) {
        i.up = j.up; i.down = j.down; i.left = j.left; i.right = j.right; i.fire = j.fire
    }
    /// Re-applies the merged state (call after changing mapping tables or transforms).
    func refresh() { resolverGeneration = -1; sync() }

    // MARK: per emulated frame (Machine.frameHook, game thread parked)

    /// Runs the frame-timed features: deferred key releases, S15/M13 pipeline, L2 aiming, M14 buttons.
    func frameTick(machine m: Machine, context c: GameContext, directAim: Bool = false) {
        tick(frame: m.frameCount, context: c, machine: m, directAim: directAim)
    }

    /// The frame-timed part (`machine` nil = unit tests: no aiming / M14 host buttons).
    func tick(frame f: UInt64, context c: GameContext, machine m: Machine?, directAim: Bool = false) {
        frame = f
        context = c
        if !pendingUps.isEmpty {
            let due = pendingUps.filter { $0.frame <= frame }
            pendingUps.removeAll { $0.frame <= frame }
            for u in due { amigaRelease(u.key) }
        }
        guard let i = input else { return }
        let userDirs = rawJoy.anyDirection
        let aimOut = suspended || m == nil ? nil : aim.tick(machine: m!, context: c, userDirections: userDirs, stick: rightStick, directAim: directAim)
        if let a = aimOut {
            if a.spaceDown != aimSpaceHeld { aimSpaceHeld = a.spaceDown; if a.spaceDown { amigaPress(0x40) } else { amigaRelease(0x40) } }
        } else if aimSpaceHeld { aimSpaceHeld = false; amigaRelease(0x40) }
        // the aim assist takes over the stick only on frames where it steers or fires (elsewhere, e.g. on the title
        // or in the corridors, input stays event-timed like the original)
        let engaged = aimOut.map { $0.directions != nil || $0.fire } ?? false
        defer { aimEngaged = engaged }
        if !pipeline.active && !engaged {
            if aimEngaged { write(rawJoy, to: i) }             // hand the stick back
        } else {
            var j = suspended ? JoyState() : pipeline.tick(frame: frame, raw: rawJoy, turbo: hostActions.contains(.turboFire), context: c)
            if let a = aimOut {
                if let d = a.directions { j.up = d.up; j.down = d.down; j.left = d.left; j.right = d.right }
                if a.fire { j.fire = true }
            }
            write(j, to: i)
        }
        if m14Enabled, let m {
            let b = Section0HostButtons.of(m)
            let jump = !suspended && hostActions.contains(.jump), crouch = !suspended && hostActions.contains(.crouch)
            if b.jump != jump { b.jump = jump }
            if b.crouch != crouch { b.crouch = crouch }
        }
    }
    private var aimSpaceHeld = false
    /// The aim assist drove the stick in the last frame (Input is then written per frame).
    private var aimEngaged = false

    /// Pipeline / aim options changed: write the current state now.
    func configurationChanged() {
        if !aim.active { aimEngaged = false }
        sync()
        if !(pipeline.active || aimEngaged), let i = input { write(rawJoy, to: i) }
    }
}
