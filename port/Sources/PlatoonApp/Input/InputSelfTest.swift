import AppKit
import PlatoonCore

// OWNER: [input]. Self-test of the input layer (PLATOON_INPUT_TEST=outdir, optional PLATOON_ADF=disk and
// PLATOON_REPO=repository root for the section-0/1 harness scripts; runner: port/verify/input/run.sh). Runs at launch, prints
// PASS/FAIL lines, writes outdir/report.txt (+ PNGs of the Controls window and the controller hint) and exits
// 0 (all pass) / 1.
//
// Unit part: default bindings == the original app's tables for every key and button (US layout); layouts
// (QWERTZ/AZERTY simulated); S18 typing suppression; S15 stretcher; aim steering; rumble mapping; persistence.
// Game part (real Machine + the translated game, run headless-fast inside the app process, --deterministic):
// S2 pad X = SPACE (grenade), pad Y = change soldier, trap door A = Yes / B = No (RAM-identical to the keyboard
// answer), S15 1-frame tunnel turns, M13 toggle + auto-fire, L2 assisted aim (tunnels combat + flare) and direct
// aim, M14 jump button.

enum InputSelfTest {
    final class Report {
        var lines: [String] = []
        var failed = 0, passed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            let d = detail()
            let l = "\(ok ? "PASS" : "FAIL") \(name)\(d.isEmpty ? "" : " — " + d)"
            lines.append(l); print("[input-test] " + l)
            if ok { passed += 1 } else { failed += 1 }
        }
        func note(_ s: String) { lines.append("     " + s); print("[input-test]      " + s) }
    }

    static var outDir: String?

    static func run(outDir: String) {
        self.outDir = outDir
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let r = Report()
        let t0 = Date()
        unitTests(r)
        uiTests(r, outDir)
        if let disk = loadDisk() {
            gameTests(r, disk)
        } else {
            r.note("no disk (set PLATOON_ADF): game tests skipped")
        }
        r.lines.append("\(r.passed) passed, \(r.failed) failed (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
        print("[input-test] \(r.passed) passed, \(r.failed) failed")
        try? r.lines.joined(separator: "\n").write(toFile: outDir + "/report.txt", atomically: true, encoding: .utf8)
        exit(r.failed == 0 ? 0 : 1)
    }

    static func loadDisk() -> Disk? {
        let env = ProcessInfo.processInfo.environment
        let cands = [env["PLATOON_ADF"], Bundle.main.url(forResource: "Platoon", withExtension: "adf")?.path].compactMap { $0 }
        for p in cands { if let d = try? Disk(contentsOf: URL(fileURLWithPath: p)) { return d } }
        return nil
    }

    // MARK: - unit tests

    /// A manager with a recording key sink, on a fresh Input.
    final class Rig {
        let input = Input()
        let im = InputManager()
        var keys: [(UInt8, Bool)] = []
        init(bindings: BindingSet = .standard) {
            im.input = input
            im.keySink = { [unowned self] k, d in self.keys.append((k, d)) }
            im.bindings = bindings
        }
        var joy: InputManager.JoyState { im.debugJoy }
        var frame: UInt64 = 0
        /// One emulated frame of the frame-timed layer (no Machine).
        func tick(_ c: GameContext = InputSelfTest.ctx()) { frame += 1; im.tick(frame: frame, context: c, machine: nil) }
        func take() -> [(UInt8, Bool)] { defer { keys = [] }; return keys }
    }

    /// A default F1 context (GameContext has no public initialiser): a fresh probe's.
    static func ctx(_ screen: GameContext.Screen = .boot, _ area: GameContext.Area = .none) -> GameContext {
        var c = GameProbe().context; c.screen = screen; c.area = area; return c
    }

    static func eq(_ a: [(UInt8, Bool)], _ b: [(UInt8, Bool)]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0 == $1 } }
    static func fmt(_ a: [(UInt8, Bool)]) -> String { a.map { String(format: "%02x%@", $0.0, $0.1 ? "↓" : "↑") }.joined(separator: " ") }

    static let modifierFlags: [UInt16: (NSEvent.ModifierFlags, UInt)] = [
        0x3a: (.option, 0x20), 0x3d: (.option, 0x40), 0x38: (.shift, 0x02), 0x3c: (.shift, 0x04), 0x3b: (.control, 0x01), 0x3e: (.control, 0x2000),
    ]

    static func unitTests(_ r: Report) {
        KeyLayout.simulated = "us"; KeyLayout.refresh()
        UserDefaults.standard.removeObject(forKey: InputSettings.layoutLettersKey)

        // U1: every key of the original tables, pressed and released alone: identical key events + joystick
        var bad: [String] = []
        let legacyJoy: (UInt16) -> InputManager.JoyState = { c in
            InputManager.JoyState(up: InputManager.joyUp.contains(c), down: InputManager.joyDown.contains(c),
                                  left: InputManager.joyLeft.contains(c), right: InputManager.joyRight.contains(c),
                                  fire: InputManager.joyFire.contains(c))
        }
        for code in InputManager.amigaKeys.keys.sorted() {
            let g = Rig()
            g.im.keyDown(code, isRepeat: false)
            let dn = g.take(), jd = g.joy
            g.im.keyUp(code)
            let up = g.take(), ju = g.joy
            let k = InputManager.amigaKeys[code]!
            if !eq(dn, [(k, true)]) || !eq(up, [(k, false)]) || jd != legacyJoy(code) || ju != .init() {
                bad.append(String(format: "%02x: %@ / %@", code, fmt(dn), fmt(up)))
            }
        }
        for (code, (cls, dev)) in modifierFlags.sorted(by: { $0.key < $1.key }) {
            let g = Rig()
            g.im.modifierChanged(code, flags: NSEvent.ModifierFlags(rawValue: cls.rawValue | dev))
            let dn = g.take()
            g.im.modifierChanged(code, flags: [])
            let up = g.take(), k = InputManager.modifierKeys[code]!
            if !eq(dn, [(k, true)]) || !eq(up, [(k, false)]) || g.joy != .init() { bad.append(String(format: "mod %02x: %@ / %@", code, fmt(dn), fmt(up))) }
        }
        r.check("M7 default keyboard bindings == original tables (\(InputManager.amigaKeys.count) keys + 6 modifiers)", bad.isEmpty, bad.prefix(6).joined(separator: "; "))

        // combos: Space + Z, arrows
        do {
            let g = Rig()
            g.im.keyDown(0x31, isRepeat: false); g.im.keyDown(0x06, isRepeat: false); g.im.keyUp(0x31)
            let f1 = g.joy.fire
            g.im.keyUp(0x06)
            g.im.keyDown(0x7e, isRepeat: false); g.im.keyDown(0x7b, isRepeat: false)
            let ul = g.joy
            g.im.keyUp(0x7e); g.im.keyUp(0x7b)
            r.check("keyboard combos (Space+Z fire held, up+left)", f1 && ul == .init(up: true, left: true) && g.joy == .init(),
                    fmt(g.keys))
        }
        // left/right Option held together, release one
        do {
            let g = Rig()
            g.im.modifierChanged(0x3a, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20))
            g.im.modifierChanged(0x3d, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x60))
            g.im.modifierChanged(0x3a, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40))
            let ev = g.take()
            r.check("left Option released while right Option held", eq(ev, [(0x64, true), (0x65, true), (0x64, false)]), fmt(ev))
        }

        // U2: controller: original-only preset == legacy; extended adds X/Y/LB/LT only
        do {
            var bad: [String] = []
            for preset in [BindingSet.PadPreset.original, .extended] {
                for b in PadButton.allCases {
                    let g = Rig(bindings: .preset(keyboard: .original, pad: preset))
                    g.im.injectPad(b, down: true)
                    let dn = g.take(), j = g.joy
                    g.tick()   // advance time for taps
                    g.im.injectPad(b, down: false)
                    for _ in 0..<8 { g.tick() }
                    let up = g.take()
                    var expDn: [(UInt8, Bool)] = [], expJ = InputManager.JoyState()
                    switch b {
                    case .up: expJ.up = true; case .down: expJ.down = true; case .left: expJ.left = true; case .right: expJ.right = true
                    case .a, .b, .rt, .rb: expJ.fire = true
                    case .menu: expDn = [(0x42, true)]
                    case .options: expDn = [(0x59, true)]
                    case .x where preset == .extended: expDn = [(0x40, true)]
                    case .y where preset == .extended: expDn = [(0x64, true)]
                    case .lb where preset == .extended: expDn = [(0x15, true)]
                    case .lt where preset == .extended: expDn = [(0x36, true)]
                    default: break
                    }
                    let expUp = expDn.map { ($0.0, false) }
                    if !eq(dn, expDn) || !eq(up, expUp) || j != expJ { bad.append("\(preset) \(b.rawValue): \(fmt(dn)) / \(fmt(up)) joy \(j)") }
                }
            }
            r.check("S2 controller: Original preset == original mapping; Extended adds only X/Y/LB/LT", bad.isEmpty, bad.prefix(4).joined(separator: "; "))
        }
        // pad Y is a tap (released after padTapFrames even when held)
        do {
            let g = Rig()
            g.im.injectPad(.y, down: true)
            for _ in 0..<12 { g.tick() }
            let ev = g.take()
            g.im.injectPad(.y, down: false)
            r.check("S2 pad Y = Left-Alt tap (released while still held)", eq(ev, [(0x64, true), (0x64, false)]) && g.take().isEmpty, fmt(ev))
        }

        // U3: layouts
        do {
            KeyLayout.simulated = "qwertz"; KeyLayout.refresh()
            let g = Rig()
            g.im.keyDown(0x06, isRepeat: false)                // labelled Y on QWERTZ
            let y = g.take(), yFire = g.joy.fire
            g.im.keyUp(0x06); _ = g.take()
            g.im.keyDown(0x10, isRepeat: false)                // labelled Z on QWERTZ
            let z = g.take(), zFire = g.joy.fire
            g.im.keyUp(0x10); _ = g.take()
            r.check("S3 QWERTZ: key labelled Y sends Amiga Y (no fire), key labelled Z fires + Amiga Z",
                    eq(y, [(0x15, true)]) && !yFire && eq(z, [(0x31, true)]) && zFire, "Y: \(fmt(y)) fire \(yFire), Z: \(fmt(z)) fire \(zFire)")
            KeyLayout.simulated = "azerty"; KeyLayout.refresh()
            let h = Rig()
            var out: [String] = []
            for (code, want) in [(0x0c, 0x20), (0x00, 0x10), (0x0d, 0x31), (0x06, 0x11), (0x29, 0x37), (0x12, 0x01)] as [(UInt16, UInt8)] {
                h.im.keyDown(code, isRepeat: false); let e = h.take(); h.im.keyUp(code); _ = h.take()
                if !eq(e, [(want, true)]) { out.append(String(format: "%02x -> %@ (want %02x)", code, fmt(e), want)) }
            }
            r.check("S3 AZERTY: A/Q/Z/W/M by label, digits row by position", out.isEmpty, out.joined(separator: "; "))
            UserDefaults.standard.set(false, forKey: InputSettings.layoutLettersKey)
            let p = Rig(); p.im.keyDown(0x0c, isRepeat: false); let e = p.take()
            UserDefaults.standard.removeObject(forKey: InputSettings.layoutLettersKey)
            r.check("S3 'letters follow layout' off = US positions", eq(e, [(0x10, true)]), fmt(e))
            KeyLayout.simulated = "us"; KeyLayout.refresh()
        }

        // U4: S18 typing suppression
        do {
            let g = Rig()
            g.im.keyboardFireSuppressed = true
            g.im.keyDown(0x31, isRepeat: false); let sp = g.joy.fire
            g.im.keyDown(0x06, isRepeat: false); let z = g.joy.fire
            g.im.keyDown(0x7c, isRepeat: false); let right = g.joy.right
            g.im.keyboardFireSuppressed = false
            let fireAfter = g.joy.fire
            let ev = g.take()
            r.check("S18 while typing: Space/Z type but don't fire, arrows still steer", !sp && !z && right && fireAfter
                    && eq(ev, [(0x40, true), (0x31, true), (0x4e, true)]), fmt(ev))
            let s = Rig(bindings: .preset(keyboard: .leftHand, pad: .extended))
            s.im.keyboardFireSuppressed = true
            s.im.keyDown(0x0e, isRepeat: false)                 // E = change soldier in the left-hand preset
            let e1 = s.take()
            r.check("S18 while typing: a letter bound to an action types the letter (left-hand E)", eq(e1, [(0x12, true)]), fmt(e1))
            let rh = Rig(bindings: .preset(keyboard: .rightHand, pad: .extended))
            rh.im.keyboardFireSuppressed = true
            rh.im.keyDown(0x24, isRepeat: false)                // Return = SPACE in the right-hand preset
            let e2 = rh.take()
            rh.im.keyUp(0x24); _ = rh.take(); rh.im.keyboardFireSuppressed = false
            rh.im.keyDown(0x24, isRepeat: false)
            let e3 = rh.take()
            r.check("S18 while typing: Return finishes the name in the right-hand preset (SPACE again afterwards)",
                    eq(e2, [(0x44, true)]) && eq(e3, [(0x40, true)]), "\(fmt(e2)) / \(fmt(e3))")
        }

        // U5: stretcher
        do {
            let p = InputPipeline(); p.stretchFrames = 4
            var c = ctx(.playing)
            var out: [Bool] = []
            // a tap entirely between two frames, then a double tap
            var raw = InputManager.JoyState()
            for f in 1...30 {
                if f == 3 { raw.left = true; p.observe(raw, turbo: false, context: c); raw.left = false; p.observe(raw, turbo: false, context: c) }
                if f == 14 { for _ in 0..<2 { raw.left = true; p.observe(raw, turbo: false, context: c); raw.left = false; p.observe(raw, turbo: false, context: c) } }
                out.append(p.tick(frame: UInt64(f), raw: raw, turbo: false, context: c).left)
            }
            let s = out.map { $0 ? "#" : "." }.joined()
            let pulses = s.split(separator: ".", omittingEmptySubsequences: true).map(\.count)
            r.check("S15 stretcher: 0-frame tap -> 4 frames, double tap -> two 4-frame presses", pulses == [4, 4, 4], s)
            let t = ctx(.title)
            let q = InputPipeline(); q.stretchFrames = 4
            var raw2 = InputManager.JoyState(); raw2.fire = true
            q.observe(raw2, turbo: false, context: t); let a = q.tick(frame: 1, raw: raw2, turbo: false, context: t).fire
            raw2.fire = false; q.observe(raw2, turbo: false, context: t); let b = q.tick(frame: 2, raw: raw2, turbo: false, context: t).fire
            r.check("S15 not applied on the title / text screens", a && !b)
            // toggles
            let tg = InputPipeline(); tg.toggleDirections = true
            var j = InputManager.JoyState()
            j.up = true; tg.observe(j, turbo: false, context: c); j.up = false; tg.observe(j, turbo: false, context: c)
            let held = (1...5).allSatisfy { tg.tick(frame: UInt64($0), raw: j, turbo: false, context: c).up }
            j.down = true; tg.observe(j, turbo: false, context: c); j.down = false; tg.observe(j, turbo: false, context: c)
            let sw = tg.tick(frame: 6, raw: j, turbo: false, context: c)
            j.down = true; tg.observe(j, turbo: false, context: c); j.down = false; tg.observe(j, turbo: false, context: c)
            let off = tg.tick(frame: 7, raw: j, turbo: false, context: c)
            r.check("M13 toggle directions: tap up latches, tap down switches, tap again releases", held && sw.down && !sw.up && off == .init())
            let af = InputPipeline(); af.autoFireMode = 1
            var cj = c; cj.area = .tunnels
            var fj = InputManager.JoyState(); fj.fire = true
            af.observe(fj, turbo: false, context: cj)
            let pat = (1...16).map { af.tick(frame: UInt64($0), raw: fj, turbo: false, context: cj).fire ? "#" : "." }.joined()
            r.check("M13 auto-fire in the tunnels: 4 on / 4 off", pat == "####....####....", pat)
        }

        // U6: aim steering converges on a model of the tunnel combat crosshair (step = crossSpeed, +2 up to 16)
        do {
            var ok = true, worst = 0.0
            for (tx, ty) in [(20.0, 100.0), (150.0, 30.0), (93.0, 64.0), (89.0, 25.0)] {
                var x = 89.0, y = 25.0, speed = 2
                for tick in 0..<60 {
                    let j = AimAssist.steer(from: CGPoint(x: x, y: y), to: CGPoint(x: tx, y: ty), step: AimAssist.nextStep(.tunnelCombat, crossSpeed: speed))
                    _ = tick
                    if !j.anyDirection { speed = 2; continue }
                    let d = Double(speed); if speed < 0xf { speed += 2 }
                    if j.left { x -= d }; if j.right { x += d }; if j.up { y -= d }; if j.down { y += d }
                }
                let e = max(abs(x - tx), abs(y - ty)); worst = max(worst, e)
                if e > 1 { ok = false }
            }
            r.check("L2 steering model converges (tunnel combat speeds)", ok, "worst error \(worst)")
        }

        // U7: rumble mapping
        do {
            let m = [Rumble.pulse(for: .fx(id: 0x85, enabled: true))?.1, Rumble.pulse(for: .fx(id: 0x81, enabled: false))?.1,
                     Rumble.pulse(for: .fx(id: 0, enabled: true))?.1, Rumble.pulse(for: .death(man: 1))?.1]
            r.check("S13 rumble mapping ($85 explosion, $81 hit with FX off, fx 0 ignored, death)",
                    m == ["explosion", "hit", nil, "death"], "\(m)")
        }

        // U8: persistence + presets
        do {
            var b = BindingSet.standard
            b[.space].keys = [.code(0x0c)]; b[.fire].pad = [.rb]
            let d = try? JSONEncoder().encode(b)
            let back = d.flatMap { try? JSONDecoder().decode(BindingSet.self, from: $0) }
            r.check("M7 bindings JSON round trip", back == b)
            let sep = BindingSet.preset(keyboard: .separate, pad: .extended)
            let g = Rig(bindings: sep)
            g.im.keyDown(0x31, isRepeat: false); let spFire = g.joy.fire; let ev = g.take(); g.im.keyUp(0x31)
            g.im.keyDown(0x07, isRepeat: false); let xFire = g.joy.fire
            r.check("S3 Separate preset: Space = SPACE only, X fires", !spFire && eq(ev, [(0x40, true)]) && xFire)
            let lh = Rig(bindings: .preset(keyboard: .leftHand, pad: .extended))
            lh.im.keyDown(0x0d, isRepeat: false); let w = lh.joy.up
            lh.im.keyDown(0x0c, isRepeat: false); let q = lh.take()
            r.check("M13 one-handed left preset: W = up, Q = SPACE", w && eq(q, [(0x11, true), (0x40, true)]), fmt(q))
            r.check("M7 help text generated from bindings", BindingSet.standard.helpText().contains("Fire: Space / Z"),
                    BindingSet.standard.helpText().components(separatedBy: "\n").prefix(3).joined(separator: " | "))
            r.check("M7 standard bindings have no conflicts", BindingSet.standard.conflicts().isEmpty, BindingSet.standard.conflicts().joined(separator: ", "))
        }
    }


    // MARK: - UI renders

    static func uiTests(_ r: Report, _ dir: String) {
        let w = ControlsWindowController.shared
        w.show()
        w.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        w.snapshot(to: dir + "/controls_window.png")
        r.check("M7 Controls window renders", FileManager.default.fileExists(atPath: dir + "/controls_window.png"))
        var retargeted: [String] = []
        func scan(_ m: NSMenu?) {
            for i in m?.items ?? [] {
                if i.target === InputMenuTarget.shared { retargeted.append(i.title) }
                scan(i.submenu)
            }
        }
        scan(NSApp.mainMenu)
        r.check("M7 Game ▸ Controls… opens the Controls & Bindings window (menu item retargeted)", !retargeted.isEmpty, retargeted.joined(separator: ", "))
        w.window?.close()
        let p = ControllerHintPanel()
        let c = ctx(.trapDoorPrompt)
        if let parts = ControllerHintPanel.hint(c, bindings: .standard) {
            let s = ControllerHintPanel.attributed(parts, pad: nil)
            let size = s.size()
            let img = NSImage(size: NSSize(width: size.width + 20, height: size.height + 10), flipped: false) { rect in
                NSColor(calibratedWhite: 0.05, alpha: 1).setFill(); rect.fill()
                s.draw(at: NSPoint(x: 10, y: 5)); return true
            }
            if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/hint_trapdoor.png"))
            }
            r.check("S2 trap-door hint text", s.string.contains("Yes") && s.string.contains("No"), s.string)
        } else { r.check("S2 trap-door hint text", false) }
        _ = p
    }

    // MARK: - game tests

    /// A real game on a private Machine, driven through an InputManager exactly like the app (frameTick in the
    /// frame hook), --deterministic.
    final class Game {
        let m: Machine
        let probe = GameProbe()
        let im = InputManager()
        var events: [GameEventRecord] = []
        var directAim = false
        var frame: Int { Int(m.frameCount) }
        var ctx: GameContext { probe.context }

        init(_ disk: Disk, section: Int?, enh: [String] = [], bindings: BindingSet = .standard) {
            var cfg = GameConfig()
            cfg.startSection = section
            cfg.deterministicRNG = true
            probe.autoPoll = false
            cfg.probe = probe
            let errs = cfg.enhancements.apply(["originalCredits=0"] + enh)
            if !errs.isEmpty { print("[input-test] option errors: \(errs)") }
            m = Machine(disk: disk)
            im.input = m.input
            im.bindings = bindings
            probe.addObserver { [unowned self] e in self.events.append(e) }
            m.frameHook = { [unowned self] mm in
                self.probe.poll(mm)
                self.im.frameTick(machine: mm, context: self.probe.context, directAim: self.directAim)
            }
            m.start { PlatoonGame.main($0, config: cfg) }
        }
        func run(_ n: Int, _ each: (() -> Void)? = nil) { for _ in 0..<n { each?(); m.runFrame() } }
        func runUntil(_ limit: Int, _ cond: () -> Bool) -> Bool {
            for _ in 0..<limit { if cond() { return true }; m.runFrame() }
            return cond()
        }
        /// Presses fire (directly on Input, like a script) until `cond`.
        func fireThrough(_ limit: Int, _ cond: () -> Bool) -> Bool {
            var n = 0
            return runUntil(limit) {
                n += 1
                m.input.fire = n % 40 < 5
                return cond()
            }
        }
        /// Replays a platoon-headless script (frame cmd args) up to (excluding) frame `until`.
        func replay(_ lines: [String], until: Int, skip: (Int, String) -> Bool = { _, _ in false }) {
            var ev: [(Int, [String])] = []
            for l in lines {
                let p = l.split(separator: " ").map(String.init)
                if p.count >= 2, let f = Int(p[0]), f < until, !skip(f, l) { ev.append((f, Array(p.dropFirst()))) }
            }
            ev.sort { $0.0 < $1.0 }
            var i = 0
            while frame < until {
                while i < ev.count && ev[i].0 <= frame {
                    let a = ev[i].1; i += 1
                    let on = (a.count > 1 ? a[1] : "1") != "0"
                    switch a[0] {
                    case "up": m.input.up = on; case "down": m.input.down = on; case "left": m.input.left = on
                    case "right": m.input.right = on; case "fire": m.input.fire = on
                    case "key": if let c = UInt8(a[1].replacingOccurrences(of: "0x", with: ""), radix: 16) { m.input.key(c, down: (a.count > 2 ? a[2] : "1") != "0") }
                    case "poke":
                        if a.count >= 3, let ad = UInt32(a[1], radix: 16), let v = UInt32(a[2], radix: 16) {
                            switch Int(a.count > 3 ? a[3] : "1") ?? 1 { case 1: m.memory.w8(ad, UInt8(truncatingIfNeeded: v)); case 2: m.memory.w16(ad, UInt16(truncatingIfNeeded: v)); default: m.memory.w32(ad, v) }
                        }
                    default: break
                    }
                }
                m.runFrame()
            }
        }
        /// Canvas screenshot into the report directory (diagnostics).
        func shot(_ name: String) {
            guard let d = InputSelfTest.outDir else { return }
            try? ImageIO.canvasPNG(m.chip).write(to: URL(fileURLWithPath: d + "/game_" + name + ".png"))
        }
        func keyHeld(_ k: UInt8) -> Bool { m.memory.r8(0x2498 + UInt32(k >> 3)) & (1 << (k & 7)) != 0 }
        func count(_ f: (GameEvent) -> Bool) -> Int { events.filter { f($0.event) }.count }
        func stop() { m.stop() }
    }

    /// The verification scripts come straight from the section harnesses (the regression gate's inputs):
    /// section 0 port scripts (tick-aligned, --start-section 0) and section 1 scripts (from power-on).
    /// PLATOON_REPO = the repository root (default: the current directory or its parent).
    static func script(_ name: String) -> [String]? {
        let env = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        var roots = [env["PLATOON_REPO"]].compactMap { $0 }
        roots += [cwd, cwd + "/.."]
        let subdirs = ["port/verify/section0/harness/sc", "port/verify/section1/scripts", "port/verify/input/scripts"]
        for r in roots {
            for d in subdirs {
                if let t = try? String(contentsOfFile: r + "/" + d + "/" + name, encoding: .utf8) {
                    return t.split(separator: "\n").map(String.init)
                }
            }
        }
        return nil
    }

    /// PLATOON_INPUT_ONLY=name,name: run only these game tests (s2jungle m14 trapdoor s15 m13toggle m13auto l2).
    static func want(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["PLATOON_INPUT_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { $0 == name }
    }

    static func gameTests(_ r: Report, _ disk: Disk) {
        // --- S2 in the jungle: pad X = SPACE (grenade), pad Y = change soldier
        if want("s2jungle") {
            // like the section-0 harness scripts (--start-section 0): the jungle runs from ~frame 700; invincible
            let g = Game(disk, section: 0)
            g.run(706)
            g.m.memory.w8(0x60ca0, 0xff)
            g.run(120)
            let ok = g.ctx.screen == .playing && g.ctx.area == .jungle
            // SPACE throws only while the man stands/walks (pstate 0) with no grenade in the air
            let ready = g.runUntil(900) { g.m.memory.r16(0x5f89a) == 0 && g.m.memory.r8(0x60c42) == 0 }
            g.shot("s2_before_x")
            let gren0 = g.ctx.man?.grenades ?? -1
            let fx0 = g.count { if case .fx(0x0a, _) = $0 { return true }; return false }
            g.im.injectPad(.x, down: true)
            var sawSpace = false
            g.run(30) { if g.keyHeld(0x40) { sawSpace = true } }
            g.im.injectPad(.x, down: false)
            g.shot("s2_after_x")
            g.run(40)
            let fx1 = g.count { if case .fx(0x0a, _) = $0 { return true }; return false }
            r.check("S2 pad X = Amiga SPACE: jungle grenade thrown", ok && ready && sawSpace && fx1 > fx0,
                    "playing \(ok), ready \(ready), SPACE in key matrix \(sawSpace), grenade sfx \(fx0)->\(fx1), grenades \(gren0)->\(g.ctx.man?.grenades ?? -1)")
            // Left-Alt is only honoured with no enemy on screen (estate 0)
            let calm = g.runUntil(3000) { g.m.memory.r16(0x5f888) == 0 && g.m.memory.r16(0x5f89a) == 0 && g.m.memory.r8(0x60c42) == 0 }
            g.shot("s2_before_y")
            g.im.injectPad(.y, down: true)
            var altSeen = false
            // the jungle dissolves out first (~2-3 s), then the choose-your-man box opens
            let sel = g.runUntil(400) { if g.keyHeld(0x64) { altSeen = true }; return g.ctx.screen == .manSelect }
            g.shot("s2_after_y")
            g.run(10)
            let altStillHeld = g.keyHeld(0x64)
            g.im.injectPad(.y, down: false)
            r.check("S2 pad Y = change soldier (man select opens, Alt tap released while Y held)", calm && sel && !altStillHeld,
                    "calm \(calm), alt seen \(altSeen), manSelect \(sel), alt held \(altStillHeld), screen \(g.ctx.screen)")
            // choose the man with fire (pad A) and back to the jungle; must not re-enter
            let back = g.runUntil(900) {
                if g.frame % 30 == 0 { g.im.injectPad(.a, down: true) } else if g.frame % 30 == 6 { g.im.injectPad(.a, down: false) }
                return g.ctx.screen == .playing
            }
            g.im.injectPad(.a, down: false)
            var reentered = false
            g.run(150) { if g.ctx.screen == .manSelect { reentered = true } }
            r.check("S2 back from man select, no re-entry", sel && back && !reentered, "back \(back) reentered \(reentered)")
            g.stop()
        }
        // --- M14 host jump button (section-0 option)
        if want("m14") {
            let g = Game(disk, section: 0, enh: ["s0.explicitJumpCrouch=1"])
            g.run(706)
            g.m.memory.w8(0x60ca0, 0xff)
            g.run(120)
            g.im.m14Enabled = true
            g.im.injectPad(.lb, down: true)
            var jumped = false
            g.run(20) { if g.m.memory.r16(0x5f89a) == 1 { jumped = true } }
            g.im.injectPad(.lb, down: false)
            r.check("M14 LB / X = jump (s0.explicitJumpCrouch): player state 1", jumped, "state \(g.m.memory.r16(0x5f89a))")
            g.stop()
        }
        // --- S2 trap door: pad answers vs keyboard answers (RAM identical afterwards)
        if !want("trapdoor") {
        } else if let hv = script("honest_village_dj.port.txt") {
            let ref = Game(disk, section: 0)
            ref.replay(hv, until: 12700)
            let refRAM = ref.m.memory.snapshot(); let refSec = ref.ctx.loadedSection
            ref.stop()
            let g = Game(disk, section: 0)
            g.replay(hv, until: 12524, skip: { f, l in f == 12524 && l.contains("key 0x15") })
            let prompt = g.ctx.screen == .trapDoorPrompt
            g.im.injectPad(.a, down: true)
            g.replay([], until: 12530)
            g.im.injectPad(.a, down: false)
            g.replay(hv.filter { (Int($0.split(separator: " ").first ?? "") ?? 0) > 12524 }, until: 12700)
            let same = g.m.memory.snapshot() == refRAM
            let diff = same ? 0 : zip(g.m.memory.snapshot(), refRAM).filter { $0 != $1 }.count
            r.check("S2 trap door: controller A answers Yes (RAM == keyboard Y run at f12700)", prompt && same && g.ctx.loadedSection == refSec,
                    "prompt \(prompt), loaded \(g.ctx.loadedSection) vs \(refSec), \(diff) bytes differ")
            g.stop()
        } else { r.note("honest_village_dj.port.txt not found (PLATOON_REPO): trap door Yes test skipped") }
        if !want("trapdoor") {
        } else if let vr = script("village_route_dj.port.txt") {
            let ref = Game(disk, section: 0)
            ref.replay(vr, until: 2130)
            let refRAM = ref.m.memory.snapshot()
            ref.stop()
            let g = Game(disk, section: 0)
            g.replay(vr, until: 2000, skip: { f, l in (f == 2000 || f == 2011) && l.contains("key 0x36") })
            let prompt = g.ctx.screen == .trapDoorPrompt
            g.im.injectPad(.b, down: true)
            g.replay(vr.filter { !$0.contains("key 0x36") }, until: 2011)
            g.im.injectPad(.b, down: false)
            g.replay(vr.filter { (Int($0.split(separator: " ").first ?? "") ?? 0) >= 2011 && !$0.contains("key 0x36") }, until: 2130)
            let same = g.m.memory.snapshot() == refRAM
            let diff = same ? 0 : zip(g.m.memory.snapshot(), refRAM).filter { $0 != $1 }.count
            r.check("S2 trap door: controller B answers No, fire not sent (RAM == keyboard N run at f2130)", prompt && same,
                    "prompt \(prompt), \(diff) bytes differ, screen \(g.ctx.screen)")
            g.stop()
        } else { r.note("village_route.port.txt not found: trap door No test skipped") }

        // --- tunnels: boot into section 1 exactly like the section-1 regression scripts (idle.txt), enemy spawns
        // suppressed ($3b237 = $ff, re/tunnels/NOTES.md) so the corridor stays in walking mode
        let idle = script("idle.txt")
        func tunnelGame() -> Game? {
            guard let idle else { return nil }
            let g = Game(disk, section: nil)
            g.replay(idle, until: 906)                            // the tunnels start at frame ~905
            g.m.memory.w8(0x3b237, 0xff)                          // as honest.txt: no enemy spawns for ~20 s
            g.run(60)
            return g
        }
        func corridorState(_ g: Game) -> String {
            "screen \(g.ctx.screen) area \(g.ctx.area) inRoom \(g.m.memory.r8(0x3b230)) obj \(g.m.memory.r8(0x19d44))/\(g.m.memory.r8(0x19d56))/\(g.m.memory.r8(0x19d68))"
        }
        func corridor(_ g: Game) -> Bool {
            g.ctx.screen == .playing && g.ctx.area == .tunnels && g.m.memory.r8(0x3b230) == 0
                && g.m.memory.r8(0x19d44) == 0 && g.m.memory.r8(0x19d56) == 0 && g.m.memory.r8(0x19d68) == 0
        }

        // --- S15: 0-frame turn taps in the tunnels
        func tunnels(_ stretch: Int, taps: Int) -> (turns: Int, ok: Bool) {
            guard let g = tunnelGame() else { return (0, false) }
            let ok = corridor(g)
            if !ok { r.note("tunnels at start: " + corridorState(g)) }
            g.shot("s15_start_\(stretch)")
            g.im.pipeline.stretchFrames = stretch
            g.im.configurationChanged()
            var turns = 0, last = g.m.memory.r16(Platoon.a6 + 0x2a) & 3
            for i in 0..<taps {
                g.m.memory.w8(0x3b237, 0xff)
                g.im.keyDown(0x7c, isRepeat: false); g.im.keyUp(0x7c)          // press+release between two frames
                g.run(13 + i % 3) {
                    let h = g.m.memory.r16(Platoon.a6 + 0x2a) & 3
                    if h != last { turns += 1; last = h }
                }
            }
            let still = corridor(g)
            if !still { r.note("tunnels at end: " + corridorState(g)) }
            g.shot("s15_end_\(stretch)")
            g.stop()
            return (turns, ok && still)
        }
        if !want("s15") {
        } else if idle != nil {
            let off = tunnels(0, taps: 20), on = tunnels(4, taps: 20)
            r.check("S15 tunnels, 20 zero-length right taps: off loses taps, on registers every turn", off.ok && on.ok && off.turns < 20 && on.turns == 20,
                    "off \(off.turns)/20, on \(on.turns)/20, corridor \(off.ok)/\(on.ok)")
        } else { r.note("idle.txt not found: tunnel tests skipped") }

        // --- M13 toggle in the tunnels: one tap of up keeps walking
        if want("m13toggle"), let g = tunnelGame() {
            let ok = corridor(g)
            g.im.pipeline.toggleDirections = true
            g.im.configurationChanged()
            g.im.keyDown(0x7e, isRepeat: false); g.run(2); g.im.keyUp(0x7e)
            var upFrames = 0, moves = 0
            var pos = g.m.memory.r16(0x1a0b0)
            g.run(300) {
                if g.m.frameCount % 100 == 0 { g.m.memory.w8(0x3b237, 0xff) }
                if g.m.input.up { upFrames += 1 }
                let p = g.m.memory.r16(0x1a0b0); if p != pos { moves += 1; pos = p }
            }
            g.im.keyDown(0x7e, isRepeat: false); g.run(2); g.im.keyUp(0x7e); g.run(3)
            r.check("M13 toggle-hold: one tap of up keeps walking, another tap stops", ok && upFrames >= 298 && !g.m.input.up,
                    "corridor \(ok), up held \(upFrames)/300 frames, maze moves \(moves), up after 2nd tap \(g.m.input.up)")
            g.stop()
        }

        // --- M13 auto-fire in the final jungle (one shot per press rifle)
        func finalJungleShots(_ mode: Int) -> (Int, Bool) {
            let g = Game(disk, section: 2)
            let ok = g.fireThrough(4000) { g.ctx.screen == .playing && g.ctx.area == .finalJungle }
            g.m.input.fire = false
            g.run(60)
            g.im.pipeline.autoFireMode = mode
            g.im.configurationChanged()
            let s0 = g.count { if case .fx(0x82, _) = $0 { return true }; return false }
            g.im.keyDown(0x06, isRepeat: false)                              // hold Z
            g.run(150)
            g.im.keyUp(0x06)
            g.run(10)
            let s1 = g.count { if case .fx(0x82, _) = $0 { return true }; return false }
            g.stop()
            return (s1 - s0, ok)
        }
        if want("m13auto") {
            let a0 = finalJungleShots(0), a1 = finalJungleShots(1)
            r.check("M13 auto-fire, fire held 3 s in the final jungle: many more shots with auto-fire", a0.1 && a1.1 && a1.0 >= a0.0 + 8,
                    "off \(a0.0), on \(a1.0) shots")
        }

        // --- L2 assisted aim: tunnel combat and flare
        if !want("l2") {
        } else if let combat = script("combat.txt") {
            let g = Game(disk, section: nil)
            g.replay(combat, until: 975)
            g.im.aim.enabled = true
            g.im.configurationChanged()
            let info0 = TunnelAim.info(g.m.memory, area: g.ctx.area)
            var reached = false, err = 999.0
            if let i0 = info0 {
                let target = CGPoint(x: i0.centre.x - 40, y: i0.centre.y + 30)
                g.im.aim.pointer = target; g.im.aim.pointerMovedAt = CACurrentMediaTime() + 3600
                g.run(120) {
                    if let i = TunnelAim.info(g.m.memory, area: g.ctx.area) {
                        err = max(abs(i.centre.x - target.x), abs(i.centre.y - target.y))
                        if err <= 1 { reached = true }
                    }
                }
            }
            r.check("L2 assisted aim, tunnel combat: crosshair reaches the pointer", info0?.mode == .tunnelCombat && reached,
                    "mode \(info0.map { $0.mode.rawValue } ?? "none"), final error \(err)")
            g.stop()
        } else { r.note("combat.txt not found: L2 tunnel test skipped") }
        if !want("l2") {
        } else if let lit = script("fl_lit.txt") {
            for direct in [false, true] {
                let g = Game(disk, section: nil, enh: direct ? ["s1.directAim=1"] : [])
                g.directAim = direct
                g.replay(lit, until: 1850)
                g.im.aim.enabled = true
                g.im.configurationChanged()
                let info0 = TunnelAim.info(g.m.memory, area: g.ctx.area)
                var reachedAt = -1, err = 999.0
                if let i0 = info0 {
                    let target = CGPoint(x: min(i0.bounds.maxX, i0.centre.x + 70), y: max(i0.bounds.minY, i0.centre.y - 35))
                    g.im.aim.pointer = target; g.im.aim.pointerMovedAt = CACurrentMediaTime() + 3600
                    let start = g.frame
                    g.run(150) {
                        if let i = TunnelAim.info(g.m.memory, area: g.ctx.area) {
                            err = max(abs(i.centre.x - target.x), abs(i.centre.y - target.y))
                            if err <= 1 && reachedAt < 0 { reachedAt = g.frame - start }
                        }
                    }
                }
                r.check("L2 \(direct ? "direct (s1.directAim)" : "assisted") aim, flare: crosshair reaches the pointer",
                        info0?.mode == .flare && reachedAt >= 0, "after \(reachedAt) frames, final error \(err)")
                g.stop()
            }
        } else { r.note("fl_lit.txt not found: L2 flare test skipped") }
    }
}
