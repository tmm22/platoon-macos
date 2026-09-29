/// Joystick (port 2), fire buttons and Amiga keyboard, fed by the host app or a script.
public final class Input {
    public var up = false, down = false, left = false, right = false
    public var fire = false          // port 2 fire (CIA-A PRA bit 7)
    public var fire0 = false         // port 1 fire / left mouse (bit 6)
    var keyQueue: [UInt8] = []       // raw Amiga keycodes, bit 7 = release
    var keyDelay = 0
    /// Frames between two delivered key events (2 = the original pacing; M25 "faster key delivery" sets 0).
    public var keyGapFrames = 2

    public init() {}

    /// JOY1DAT as the hardware encodes it.
    public var joy1dat: UInt16 {
        var v: UInt16 = 0
        if right { v |= 0x0002 }
        if left { v |= 0x0200 }
        if up != left { v |= 0x0100 }
        if down != right { v |= 0x0001 }
        return v
    }

    public func key(_ code: UInt8, down isDown: Bool) { keyQueue.append((code & 0x7f) | (isDown ? 0 : 0x80)) }
    public func clearKeys() { keyQueue.removeAll() }
}
