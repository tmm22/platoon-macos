import AppKit
import SwiftUI
import PlatoonCore

// OWNER: [input]. M7 Controls & Bindings window (replaces the Controls NSAlert): every logical action with up to
// two keys and its controller buttons, click a cell and press a key / button to rebind (modifier keys too), presets
// (Original, Separate fire/SPACE, one-handed left/right; controller Extended / Original / half-controller), stick
// dead zone, layout-following letters, conflicts, and help text generated from the live bindings. Persisted in
// UserDefaults ("input.bindings.v1"). The game is paused while the window is open.

final class ControlsModel: ObservableObject {
    enum Slot: Equatable { case key(Int), pad }
    @Published var bindings: BindingSet
    @Published var capturing: (action: InputAction, slot: Slot)? = nil
    @Published var message: String? = nil
    @Published var revision = 0

    init() { bindings = InputSettings.load() }

    var visibleActions: [InputAction] {
        InputAction.allCases.filter { a in
            if a == .turboFire { return InputSettings.autoFire == 2 || !bindings[a].keys.isEmpty || !bindings[a].pad.isEmpty }
            return true
        }
    }

    func keyTitle(_ a: InputAction, _ i: Int) -> String {
        let k = bindings[a].keys
        return i < k.count ? k[i].name : "—"
    }
    func padTitle(_ a: InputAction) -> String {
        let p = bindings[a].pad
        return p.isEmpty ? "—" : p.map(\.title).joined(separator: " / ")
    }
    func isCapturing(_ a: InputAction, _ s: Slot) -> Bool { capturing?.action == a && capturing?.slot == s }

    func startCapture(_ a: InputAction, _ s: Slot) {
        capturing = (a, s)
        message = s == .pad ? "Press a controller button for \(a.title) (Esc cancels)" : "Press a key for \(a.title) (Esc cancels, Backspace in this window clears)"
        if s == .pad {
            AppServices.shared.host?.inputManager.capturePad = { [weak self] b in
                DispatchQueue.main.async { self?.finishPad(b) }
            }
        }
    }
    func cancelCapture() {
        capturing = nil; message = nil
        AppServices.shared.host?.inputManager.capturePad = nil
    }

    /// A key was pressed while capturing (keycode incl. modifier keys).
    func finishKey(_ code: UInt16) {
        guard let c = capturing, case .key(let i) = c.slot else { return }
        capturing = nil
        var keys = bindings[c.action].keys
        if code == 0x33 {                                  // Backspace clears the slot
            if i < keys.count { keys.remove(at: i) }
        } else {
            let ref = KeyRef.code(code)
            keys.removeAll { $0.keycode == code }
            if i < keys.count { keys[i] = ref } else { keys.append(ref) }
            if keys.count > 2 { keys = Array(keys.prefix(2)) }
        }
        bindings[c.action].keys = keys
        message = warning(forKey: code, action: c.action)
        commit(customKeyboard: true)
    }

    func finishPad(_ b: PadButton) {
        guard let c = capturing, c.slot == .pad else { return }
        capturing = nil
        bindings[c.action].pad = [b]
        message = ["l3": "L3 is fast-forward while that preference is on (General ▸ Fast-forward).",
                   "r3": "R3 is hold-to-rewind while rewind is on (General ▸ Save states)."][b.rawValue]
        commit(customPad: true)
    }

    func clear(_ a: InputAction) {
        bindings[a] = ActionBinding()
        commit(customKeyboard: true, customPad: true)
    }

    private func warning(forKey code: UInt16, action: InputAction) -> String? {
        switch code {
        case 0x35: return "Esc also opens the pause menu (General ▸ Pause menu)."
        case 0x32: return "` is hold-to-fast-forward while that preference is on."
        default: break
        }
        if let c = KeyLayout.character(code), c.isLetter, action.amigaKey != nil {
            return "\(String(c).uppercased()) now sends \(action.title) instead of the letter (except while typing a high-score name)."
        }
        return nil
    }

    func applyKeyboardPreset(_ p: BindingSet.KeyboardPreset) {
        bindings.applyKeyboard(p); Prefs.set(InputSettings.keyboardPresetKey, p.rawValue); commit()
    }
    func applyPadPreset(_ p: BindingSet.PadPreset) {
        bindings.applyPad(p); Prefs.set(InputSettings.padPresetKey, p.rawValue); commit()
    }
    func resetAll() {
        bindings = .standard
        Prefs.set(InputSettings.keyboardPresetKey, 0); Prefs.set(InputSettings.padPresetKey, 0)
        commit()
    }

    func commit(customKeyboard: Bool = false, customPad: Bool = false) {
        InputSettings.save(bindings)
        if customKeyboard { UserDefaults.standard.set(BindingSet.customPreset, forKey: InputSettings.keyboardPresetKey) }
        if customPad { UserDefaults.standard.set(BindingSet.customPreset, forKey: InputSettings.padPresetKey) }
        InputFeature.shared.applyBindings()
        PrefsModel.shared.bump()
        revision += 1
    }
    func reload() { bindings = InputSettings.load(); revision += 1 }
}

struct ControlsView: View {
    @ObservedObject var model: ControlsModel
    @State private var deadZone = InputSettings.deadZone
    @State private var letters = InputSettings.layoutLetters

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu("Keyboard preset") {
                    ForEach(BindingSet.KeyboardPreset.allCases, id: \.rawValue) { p in
                        Button(p.title) { model.applyKeyboardPreset(p) }
                    }
                }.frame(width: 190)
                Menu("Controller preset") {
                    ForEach(BindingSet.PadPreset.allCases, id: \.rawValue) { p in
                        Button(p.title) { model.applyPadPreset(p) }
                    }
                }.frame(width: 190)
                Spacer()
                Button("Restore Defaults") { model.resetAll() }
            }
            Text(presetLine).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("Action").bold(); Text("Key").bold(); Text("Key").bold(); Text("Controller").bold(); Text("")
                    }
                    Divider()
                    ForEach(model.visibleActions, id: \.rawValue) { a in
                        GridRow {
                            Text(a.title).frame(width: 190, alignment: .leading)
                            cell(model.keyTitle(a, 0), model.isCapturing(a, .key(0))) { model.startCapture(a, .key(0)) }
                            cell(model.keyTitle(a, 1), model.isCapturing(a, .key(1))) { model.startCapture(a, .key(1)) }
                            cell(model.padTitle(a), model.isCapturing(a, .pad), width: 170) { model.startCapture(a, .pad) }
                            Button { model.clear(a) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Unbind \(a.title)")
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(minHeight: 300)
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.orange)
            }
            let conflicts = model.bindings.conflicts()
            if !conflicts.isEmpty {
                Text("Bound twice: " + conflicts.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Toggle("Letter keys follow the keyboard layout (\(KeyLayout.layoutName))", isOn: $letters)
                    .onChange(of: letters) { _, v in Prefs.set(InputSettings.layoutLettersKey, v); InputFeature.shared.applyBindings(); model.revision += 1 }
            }
            HStack {
                Text("Stick dead zone")
                Slider(value: $deadZone, in: 0.15...0.8, step: 0.05).frame(width: 200)
                    .onChange(of: deadZone) { _, v in Prefs.set(InputSettings.deadZoneKey, v) }
                Text("\(Int(deadZone * 100))%").monospacedDigit()
            }
            GroupBox("Current controls") {
                ScrollView {
                    Text(model.bindings.helpText() + "\n\n" + ControlsView.fixedHelp)
                        .font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(height: 150)
            }
        }
        .padding(16)
        .frame(width: 720)
        .id(model.revision)
    }

    private var presetLine: String {
        let k = Prefs.int(InputSettings.keyboardPresetKey), p = Prefs.int(InputSettings.padPresetKey)
        let kt = BindingSet.KeyboardPreset(rawValue: k)?.title ?? "Custom", pt = BindingSet.PadPreset(rawValue: p)?.title ?? "Custom"
        return "Keyboard: \(kt)  ·  Controller: \(pt). Click a cell, then press a key or controller button. Keys that are not bound to an action type their Amiga key."
    }

    static let fixedHelp = """
    Controller: at the trap-door prompt A (or a fire button) answers Yes, B or the SPACE button answers No.
    Host keys: Esc pause menu · hold ` fast-forward · ⌘P pause · ⌘T turbo · ⌘R reset · ⌘S screenshot · ⌘, preferences
    Name entry: joystick left/right + fire (or type the name, with "Type the high-score name" on).
    """

    private func cell(_ t: String, _ active: Bool, width: CGFloat = 110, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(active ? "press…" : t).lineLimit(1).frame(width: width, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(active ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
    }
}

final class ControlsWindowController: NSObject, NSWindowDelegate {
    static let shared = ControlsWindowController()
    private(set) var window: NSWindow?
    let model = ControlsModel()
    private var monitor: Any?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Controls & Bindings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ControlsView(model: model))
            w.delegate = self
            w.center()
            window = w
        }
        model.reload()
        AppServices.shared.pause(.custom("controls"))
        window?.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func windowWillClose(_ n: Notification) {
        model.cancelCapture()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        AppServices.shared.resume(.custom("controls"))
        AppServices.shared.window?.makeKeyAndOrderFront(nil)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, e.window === self.window, self.model.capturing != nil else { return e }
            if case .pad = self.model.capturing!.slot {
                if e.type == .keyDown && e.keyCode == 0x35 { self.model.cancelCapture(); return nil }
                return e
            }
            if e.type == .keyDown {
                if e.modifierFlags.contains(.command) { return e }
                if e.keyCode == 0x35 { self.model.cancelCapture(); return nil }
                self.model.finishKey(e.keyCode); return nil
            }
            // flagsChanged: a modifier went down
            if InputManager.modifierKeys[e.keyCode] != nil, e.modifierFlags.intersection([.option, .shift, .control]) != [] {
                self.model.finishKey(e.keyCode); return nil
            }
            return e
        }
    }

    /// Renders the window content to a PNG (tests).
    func snapshot(to path: String) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
