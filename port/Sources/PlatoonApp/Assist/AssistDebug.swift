import AppKit
import PlatoonCore

// [assist] App-level test driver for the assists: PLATOON_DEBUG_ASSIST=file, runs alongside PLATOON_DEBUG_SCRIPT
// (which does the window captures). One command per line, "FRAME command args", executed once the emulated frame
// counter reaches FRAME (in order; # comments):
//   play PATH               play a replay / headless input script (M17 player; also the generic input driver)
//   stopreplay              hand the controls over
//   inject PATH             feed a script's input into the RUNNING game from its current frame (no restart; events
//                           at absolute frames, e.g. the rest of a verify script after a practice drill start);
//                           "inject PATH game": the input stands in for a player (the game counts in the service
//                           record and personal bests, unlike a replay)
// A line "+N command" waits N displayed frames after the previous command instead of an emulated frame.
//   savereplay PATH         write the current game's replay (no dialog)
//   practice ID             start a practice drill (jungle bridge village tunnels flare final barnes)
//   practicestop
//   newgame S [det]         new game at start section S (det: the headless --deterministic RNG)
//   openlog / closelog      message log panel
//   dumplog PATH            message log as text
//   dumpspeech PATH         every line the speech feature said (PLATOON_ASSIST_SILENT=1: nothing is spoken aloud)
//   state PATH              append a context summary (+ objectives, HUD readout, timer, practice badge)
//   record PATH             service record + speedrun records as JSON; window PNG next to it (PATH.png)
//   pref key=value,...      set preferences
//   quit
// Output paths are relative to PLATOON_DEBUG_CAPTURE (default /tmp/platoon-debug).

final class AssistDebug {
    private static var shared: AssistDebug?
    /// (frame, relative display-frame wait, command)
    private var lines: [(UInt64, Int?, [String])] = []
    private var waitLeft: Int?
    private var pc = 0
    private let dir: String

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["PLATOON_ASSIST_SILENT"] != nil { AssistCenter.shared.speech.testSink = { _ in } }
        guard let path = env["PLATOON_DEBUG_ASSIST"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let d = AssistDebug(text: text, dir: env["PLATOON_DEBUG_CAPTURE"] ?? "/tmp/platoon-debug")
        shared = d
        AppServices.shared.onDisplay { ctx in d.step(ctx) }
    }

    private init(text: String, dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for l in text.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { continue }
            let p = t.split(separator: " ").map(String.init)
            if p[0].hasPrefix("+"), let n = Int(p[0].dropFirst()), p.count >= 2 { lines.append((0, n, Array(p.dropFirst()))) }
            else if let f = UInt64(p[0]), p.count >= 2 { lines.append((f, nil, Array(p.dropFirst()))) }
        }
    }

    private func path(_ p: String) -> URL { URL(fileURLWithPath: p.hasPrefix("/") ? p : dir + "/" + p) }

    private func append(_ s: String, to p: String) {
        let u = path(p)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile() }
        else { try? (s + "\n").write(to: u, atomically: true, encoding: .utf8) }
    }

    private func step(_ ctx: FrameContext) {
        let c = AssistCenter.shared
        while pc < lines.count {
            if let n = lines[pc].1 {
                if waitLeft == nil { waitLeft = n }
                if waitLeft! > 0 { waitLeft! -= 1; return }
                waitLeft = nil
            } else if ctx.frame < lines[pc].0 { return }
            let a = lines[pc].2; pc += 1
            let arg = a.count > 1 ? a[1] : ""
            switch a[0] {
            case "play": c.replays.play(url: path(arg))
            case "stopreplay": c.replays.stopPlayback()
            case "inject": c.replays.inject(url: path(arg), asPlayer: a.count > 2 && a[2] == "game")
            case "savereplay":
                switch c.replays.currentReplay() {
                case .success(let r): try? c.replays.write(r, to: path(arg))
                case .failure(.message(let m)): append("savereplay: \(m)", to: arg + ".err")
                }
            case "practice": if let d = PracticeDrills.drill(arg) { c.practice.start(d) } else { NSLog("assist debug: no drill \(arg)") }
            case "practicestop": c.practice.stop()
            case "newgame":
                // a new game at a start section with the headless --deterministic RNG (so verification scripts can
                // be injected as the player: "newgame 2 det" + "inject FILE game")
                let sec = Int(arg) ?? 0, det = a.count > 2 && a[2] == "det"
                if let h = c.host {
                    h.restoreGame(section: sec, reason: "Test start") { m, cfg in
                        var k = cfg; k.startSection = sec; k.deterministicRNG = det
                        m.start { PlatoonGame.main($0, config: k) }
                    }
                }
            case "openlog": c.showLog()
            case "closelog": c.logPanel.close()
            case "dumplog": try? c.messageLog.exportText().write(to: path(arg), atomically: true, encoding: .utf8)
            case "dumpspeech": try? c.speech.spokenLog.joined(separator: "\n").write(to: path(arg), atomically: true, encoding: .utf8)
            case "state": append(stateText(ctx), to: arg)
            case "record":
                c.saveRecords()
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
                if let d = try? enc.encode(c.recorder.record) { try? d.write(to: path(arg)) }
                if let d = try? enc.encode(c.records) { try? d.write(to: path(arg + ".speedrun.json")) }
                ServiceRecordWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [dir] in
                    ServiceRecordWindowController.shared.snapshotPNG(to: URL(fileURLWithPath: (arg.hasPrefix("/") ? arg : dir + "/" + arg) + ".png"))
                    ServiceRecordWindowController.shared.window?.orderOut(nil)
                }
            case "pref": Prefs.applyOverrides(a.dropFirst().joined(separator: " ")); PrefsModel.shared.bump()
            case "quit": NSApp.terminate(nil)
            default: NSLog("assist debug: unknown command \(a)")
            }
        }
    }

    private func stateText(_ ctx: FrameContext) -> String {
        let c = AssistCenter.shared, g = ctx.game
        var s = "f\(ctx.frame) " + GameProbe.describe(g)
        let tier = ObjectiveTier(rawValue: max(1, min(3, Prefs.int(AssistPrefs.objectivesTier)))) ?? .goals
        if let sh = c.objectives.sheet(g, tier: tier) {
            s += "\n  objectives[\(sh.title)]: " + sh.objectives.map { "\($0.id)=\($0.state == .done ? "done" : "todo")\($0.progress.map { "(\($0))" } ?? "")" }.joined(separator: " ")
            if !sh.advice.isEmpty { s += " advice=\(sh.advice)" }
        }
        let hud = HudReadout.lines(g)
        if !hud.isEmpty { s += "\n  hud: " + hud.map { "\($0.label)=\($0.value)" }.joined(separator: " ") }
        s += "\n  timer: \(c.timer.status.rawValue) \(RunSplits.clock(c.timer.frames)) " + c.timer.splits.map { "\($0.id)@\($0.frames)" }.joined(separator: " ")
        if let b = c.practice.badgeText { s += "\n  practice: \(b)" }
        if let r = c.replays.statusText { s += "\n  replay: \(r)" }
        s += "\n  assisted: \(ctx.host.assistedReasons)"
        return s
    }
}
