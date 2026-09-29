import AppKit
import PlatoonCore

// Command-line helpers (no window):
//   Platoon --check-disk A.adf [B.adf ...] [--repair OUT.adf]   M23 health check / repair (exit 0 = verified)
//   Platoon --list-prefs                                        dump the Preferences registry
let cli = Array(CommandLine.arguments.dropFirst())
if cli.first == "--check-disk" {
    var files: [String] = [], out: String?
    var it = cli.dropFirst().makeIterator()
    while let a = it.next() { if a == "--repair" { out = it.next() } else { files.append(a) } }
    let images = files.compactMap { f -> [UInt8]? in
        guard let d = FileManager.default.contents(atPath: f) else { print("cannot read \(f)"); return nil }
        return [UInt8](d)
    }
    for (f, img) in zip(files, images) {
        let r = DiskHealth.check(img)
        print("\(f)\n  \(r.summary)\n  " + r.details.joined(separator: "\n  "))
        print("  bad tracks: \(r.badTracks.isEmpty ? "none" : r.badTracks.map(String.init).joined(separator: " "))")
    }
    guard let rep = DiskHealth.repair(images) else { exit(2) }
    if images.count > 1 || !rep.fixed.isEmpty {
        let fixed = rep.fixed.keys.sorted().map { "\($0)<-\(rep.fixed[$0]! < 0 ? "default" : String(rep.fixed[$0]!))" }
        print("combined: \(rep.report.summary)\n  repaired: \(fixed.isEmpty ? "nothing" : fixed.joined(separator: " "))")
    }
    if let o = out { try? Data(rep.data).write(to: URL(fileURLWithPath: o)); print("wrote \(o)") }
    exit(rep.report.verified ? 0 : rep.report.runnable ? 1 : 2)
}
if cli.first == "--list-prefs" {
    PrefsRegistry.registerDefaults()
    print(PrefsRegistry.dump(), terminator: "")
    var cfg = GameConfig()
    let assisted = PrefsRegistry.apply(to: &cfg)
    print("current settings: enhancements changed = \(cfg.enhancements.changed), assisted = \(assisted)")
    if !EnhancementBridge.errors.isEmpty { print("rejected by the core registry: \(EnhancementBridge.errors.sorted())") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
