import AppKit
import GameController
import PlatoonCore

/// Logical controller buttons (for modal overlays such as the pause menu, and for feature hooks).
enum PadButton: String, CaseIterable {
    case up, down, left, right, a, b, x, y, lb, rb, lt, rt, l3, r3, menu, options
}

/// Keyboard + game controller -> Amiga joystick port 2 and keyboard.
///
/// Host features on top of the original mapping (the default tables are unchanged):
///  - per-controller state OR-ed together; a disconnected controller's state is cleared (was stuck before);
///  - `suspend()` / `resume()` (host pause): nothing reaches the game while suspended, and on resume every key or
///    button that is still held is ignored until released ("resume-press swallowing", S4) — so the press that
///    closes the pause menu doesn't fire a shot;
///  - controller button events for modal overlays (`padButtonSink`) and host actions (fast-forward hold, pause-menu
///    long press);
///  - interceptors for feature owners (input agent): `keyInterceptors`, `padInterceptors`, `joyTransforms`.
final class InputManager {
    weak var input: Input?

    // MARK: mapping tables (defaults = the original app's mapping)
    // Mac virtual keycodes used for the joystick
    static var joyUp: Set<UInt16> = [0x7e], joyDown: Set<UInt16> = [0x7d], joyLeft: Set<UInt16> = [0x7b], joyRight: Set<UInt16> = [0x7c]
    static var joyFire: Set<UInt16> = [0x31, 0x06]  // space, Z

    // Mac keycode -> Amiga raw keycode
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

    // MARK: feature hooks (input agent). All run on the main thread.
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

    struct JoyState: Equatable { var up = false, down = false, left = false, right = false, fire = false }

    // MARK: state
    /// Keys physically held (Mac keycodes), and the subset whose press was forwarded to the game.
    private var physicalKeys = Set<UInt16>()
    private var keysDown = Set<UInt16>()
    /// Keys held when input resumed: ignored until released.
    private var swallowedKeys = Set<UInt16>()
    private var modifiersDown = Set<UInt16>()         // forwarded to the game
    private var physicalModifiers = Set<UInt16>()
    private var swallowedModifiers = Set<UInt16>()
    private(set) var suspended = false

    private final class Pad {
        let controller: GCController
        var buttons = Set<PadButton>()      // physically pressed
        init(_ c: GCController) { controller = c }
    }
    private var pads: [ObjectIdentifier: Pad] = [:]
    /// Buttons consumed by a sink/interceptor or swallowed at resume: ignored until released.
    private var padIgnored = Set<PadButton>()
    private var padMenuSent = false, padOptionsSent = false
    /// Controller buttons the app keeps for itself (never mapped to the game): e.g. .l3 for fast-forward.
    var hostPadButtons = Set<PadButton>()

    var controllerCount: Int { pads.count }

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

    // MARK: keyboard

    /// A modifier key changed state (NSEvent flagsChanged).
    func modifierChanged(_ code: UInt16, flags: NSEvent.ModifierFlags) {
        if code == InputManager.capsLock {           // Amiga CAPS LOCK is a normal key: send a tap per toggle
            if suspended { return }
            input?.key(0x62, down: true); input?.key(0x62, down: false); return
        }
        guard let k = InputManager.modifierKeys[code] else { return }
        let isDown: Bool
        switch code {
        case 0x3a, 0x3d: isDown = flags.contains(.option)
        case 0x38, 0x3c: isDown = flags.contains(.shift)
        default: isDown = flags.contains(.control)
        }
        if isDown { physicalModifiers.insert(code) } else { physicalModifiers.remove(code); swallowedModifiers.remove(code) }
        if suspended || swallowedModifiers.contains(code) { return }
        let wasDown = modifiersDown.contains(code)
        if isDown == wasDown { return }
        if isDown { modifiersDown.insert(code) } else { modifiersDown.remove(code) }
        input?.key(k, down: isDown)
    }

    func keyDown(_ code: UInt16, isRepeat: Bool, event: NSEvent? = nil) {
        if isRepeat { return }
        physicalKeys.insert(code)
        swallowedKeys.remove(code)          // a fresh (non-repeat) press: its earlier release was missed
        if suspended { return }
        for f in keyInterceptors where f(code, true, event) { return }
        keysDown.insert(code)
        if let k = InputManager.amigaKeys[code] { input?.key(k, down: true) }
        sync()
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
        keysDown.remove(code)
        if let k = InputManager.amigaKeys[code] { input?.key(k, down: false) }
        sync()
    }
    /// Releases everything the game currently sees as held (window lost focus, pause, reset).
    func releaseAll() {
        for c in keysDown { if let k = InputManager.amigaKeys[c] { input?.key(k, down: false) } }
        keysDown.removeAll()
        for c in modifiersDown { if let k = InputManager.modifierKeys[c] { input?.key(k, down: false) } }
        modifiersDown.removeAll()
        if padMenuSent { padMenuSent = false; input?.key(0x42, down: false) }
        if padOptionsSent { padOptionsSent = false; input?.key(0x59, down: false) }
        padIgnored.formUnion(allPadButtons)
        sync()
    }
    /// After a focus change the physical key state is unknown: forget it too.
    func forgetPhysicalKeys() {
        physicalKeys.removeAll(); physicalModifiers.removeAll(); swallowedKeys.removeAll(); swallowedModifiers.removeAll()
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
        swallowedModifiers = physicalModifiers
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

    private static func buttons(_ g: GCExtendedGamepad) -> Set<PadButton> {
        var s = Set<PadButton>()
        let x = max(-1, min(1, g.dpad.xAxis.value + g.leftThumbstick.xAxis.value))
        let y = max(-1, min(1, g.dpad.yAxis.value + g.leftThumbstick.yAxis.value))
        if x < -0.4 { s.insert(.left) }; if x > 0.4 { s.insert(.right) }
        if y > 0.4 { s.insert(.up) }; if y < -0.4 { s.insert(.down) }
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
        p.buttons = InputManager.buttons(g)
        let after = allPadButtons
        for b in PadButton.allCases where before.contains(b) != after.contains(b) { buttonEdge(b, down: after.contains(b)) }
        sync()
    }

    /// A merged button changed state.
    private func buttonEdge(_ b: PadButton, down: Bool) {
        if !down && padIgnored.remove(b) != nil {
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
        // Menu = in-game pause (TAB), Options = cycle music/fx (F10)
        switch b {
        case .menu: if down != padMenuSent { padMenuSent = down; input?.key(0x42, down: down) }
        case .options: if down != padOptionsSent { padOptionsSent = down; input?.key(0x59, down: down) }
        default: break
        }
    }

    /// Sends a TAB tap as if the controller Menu button had been pressed and released (pause-menu long-press
    /// mode sends TAB on release of a short press).
    func tapPadMenu() { input?.key(0x42, down: true); input?.key(0x42, down: false) }

    /// S18 keyboard name entry: keyboard keys don't press joystick fire (letters and Space type the name).
    var keyboardFireSuppressed = false { didSet { if keyboardFireSuppressed != oldValue { sync() } } }

    private func sync() {
        guard let i = input else { return }
        let live = allPadButtons.subtracting(padIgnored).subtracting(hostPadButtons)
        var j = JoyState()
        if !suspended {
            j.up = live.contains(.up) || !keysDown.isDisjoint(with: InputManager.joyUp)
            j.down = live.contains(.down) || !keysDown.isDisjoint(with: InputManager.joyDown)
            j.left = live.contains(.left) || !keysDown.isDisjoint(with: InputManager.joyLeft)
            j.right = live.contains(.right) || !keysDown.isDisjoint(with: InputManager.joyRight)
            j.fire = !live.isDisjoint(with: [.a, .b, .rt, .rb]) || (!keyboardFireSuppressed && !keysDown.isDisjoint(with: InputManager.joyFire))
            for t in joyTransforms { t(&j) }
        }
        i.up = j.up; i.down = j.down; i.left = j.left; i.right = j.right; i.fire = j.fire
    }
    /// Re-applies the merged state (call after changing mapping tables or transforms).
    func refresh() { sync() }
}
