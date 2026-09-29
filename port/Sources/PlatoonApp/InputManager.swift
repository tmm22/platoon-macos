import AppKit
import GameController
import PlatoonCore

/// Keyboard + game controller -> Amiga joystick port 2 and keyboard.
final class InputManager {
    weak var input: Input?
    private var keysDown = Set<UInt16>()
    private var padUp = false, padDown = false, padLeft = false, padRight = false, padFire = false
    private var padMenu = false, padOptions = false

    // Mac virtual keycodes used for the joystick
    static let joyUp: Set<UInt16> = [0x7e], joyDown: Set<UInt16> = [0x7d], joyLeft: Set<UInt16> = [0x7b], joyRight: Set<UInt16> = [0x7c]
    static let joyFire: Set<UInt16> = [0x31, 0x06]  // space, Z

    // Mac keycode -> Amiga raw keycode
    static let amigaKeys: [UInt16: UInt8] = [
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
    static let modifierKeys: [UInt16: UInt8] = [0x3a: 0x64, 0x3d: 0x65, 0x38: 0x60, 0x3c: 0x61, 0x3b: 0x63, 0x3e: 0x63]
    static let capsLock: UInt16 = 0x39
    private var modifiersDown = Set<UInt16>()

    /// A modifier key changed state (NSEvent flagsChanged).
    func modifierChanged(_ code: UInt16, flags: NSEvent.ModifierFlags) {
        if code == InputManager.capsLock {           // Amiga CAPS LOCK is a normal key: send a tap per toggle
            input?.key(0x62, down: true); input?.key(0x62, down: false); return
        }
        guard let k = InputManager.modifierKeys[code] else { return }
        let isDown: Bool
        switch code {
        case 0x3a, 0x3d: isDown = flags.contains(.option)
        case 0x38, 0x3c: isDown = flags.contains(.shift)
        default: isDown = flags.contains(.control)
        }
        let wasDown = modifiersDown.contains(code)
        if isDown == wasDown { return }
        if isDown { modifiersDown.insert(code) } else { modifiersDown.remove(code) }
        input?.key(k, down: isDown)
    }

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] g, _ in
            guard let self else { return }
            let x = max(-1, min(1, g.dpad.xAxis.value + g.leftThumbstick.xAxis.value))
            let y = max(-1, min(1, g.dpad.yAxis.value + g.leftThumbstick.yAxis.value))
            self.padLeft = x < -0.4; self.padRight = x > 0.4; self.padUp = y > 0.4; self.padDown = y < -0.4
            self.padFire = g.buttonA.isPressed || g.buttonB.isPressed || g.rightTrigger.isPressed || g.rightShoulder.isPressed
            // Menu = in-game pause (TAB), Options = cycle music/fx (F10)
            let menu = g.buttonMenu.isPressed
            if menu != self.padMenu { self.padMenu = menu; self.input?.key(0x42, down: menu) }
            let opt = g.buttonOptions?.isPressed ?? false
            if opt != self.padOptions { self.padOptions = opt; self.input?.key(0x59, down: opt) }
            self.sync()
        }
    }

    func keyDown(_ code: UInt16, isRepeat: Bool) {
        if isRepeat { return }
        keysDown.insert(code)
        if let k = InputManager.amigaKeys[code] { input?.key(k, down: true) }
        sync()
    }
    func keyUp(_ code: UInt16) {
        keysDown.remove(code)
        if let k = InputManager.amigaKeys[code] { input?.key(k, down: false) }
        sync()
    }
    func releaseAll() {
        for c in keysDown { keyUp(c) }
        keysDown.removeAll()
        for c in modifiersDown { if let k = InputManager.modifierKeys[c] { input?.key(k, down: false) } }
        modifiersDown.removeAll()
        sync()
    }

    private func sync() {
        guard let i = input else { return }
        i.up = padUp || !keysDown.isDisjoint(with: InputManager.joyUp)
        i.down = padDown || !keysDown.isDisjoint(with: InputManager.joyDown)
        i.left = padLeft || !keysDown.isDisjoint(with: InputManager.joyLeft)
        i.right = padRight || !keysDown.isDisjoint(with: InputManager.joyRight)
        i.fire = padFire || !keysDown.isDisjoint(with: InputManager.joyFire)
    }
}
