import MetalKit

/// Metal view that forwards keyboard events to the input manager and accepts dropped .adf files (M23).
final class GameView: MTKView {
    var onKeyDown: ((UInt16, Bool, NSEvent) -> Void)?
    var onKeyUp: ((UInt16, NSEvent) -> Void)?
    var onFlags: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    /// Dropped disk images; return true if accepted.
    var onDrop: (([URL]) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        onKeyDown?(e.keyCode, e.isARepeat, e)
    }
    override func keyUp(with e: NSEvent) { onKeyUp?(e.keyCode, e) }
    override func flagsChanged(with e: NSEvent) { onFlags?(e.keyCode, e.modifierFlags) }

    private func adfURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "adf" }
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { adfURLs(info).isEmpty ? [] : .copy }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let u = adfURLs(info)
        guard !u.isEmpty else { return false }
        // run the import after the drag session ends (it shows modal alerts)
        DispatchQueue.main.async { [weak self] in _ = self?.onDrop?(u) }
        return true
    }
}
