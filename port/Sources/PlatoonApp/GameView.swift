import MetalKit

/// Metal view that forwards keyboard events to the input manager.
final class GameView: MTKView {
    var onKeyDown: ((UInt16, Bool) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        onKeyDown?(e.keyCode, e.isARepeat)
    }
    override func keyUp(with e: NSEvent) { onKeyUp?(e.keyCode) }
    override func flagsChanged(with e: NSEvent) {}
}
