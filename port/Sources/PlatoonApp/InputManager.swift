import AppKit
import GameController
import PlatoonCore

/// Keyboard + game controller -> Amiga joystick port 2 and keyboard.
final class InputManager {
    weak var input: Input?
    private var keysDown = Set<UInt16>()
    private var padUp = false, padDown = false, padLeft = false, padRight = false, padFire = false

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
    ]

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
    func releaseAll() { for c in keysDown { keyUp(c) }; keysDown.removeAll(); sync() }

    private func sync() {
        guard let i = input else { return }
        i.up = padUp || !keysDown.isDisjoint(with: InputManager.joyUp)
        i.down = padDown || !keysDown.isDisjoint(with: InputManager.joyDown)
        i.left = padLeft || !keysDown.isDisjoint(with: InputManager.joyLeft)
        i.right = padRight || !keysDown.isDisjoint(with: InputManager.joyRight)
        i.fire = padFire || !keysDown.isDisjoint(with: InputManager.joyFire)
    }
}
