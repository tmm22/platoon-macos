import Foundation
import PlatoonCore

// Headless runner for verification against tools/amiga/emu. Uses the same script format:
//   FRAME up|down|left|right|fire|fire0 0|1 ; FRAME key CODE 0|1 ; FRAME shot NAME ; FRAME dump FILE
//   FRAME dumpr HEXADDR HEXLEN FILE ; FRAME poke HEXADDR HEXVAL SIZE ; FRAME quit

func usage() -> Never {
    print("""
    platoon-headless [--adf FILE] [--frames N] [--script FILE] [--out DIR] [--shot-every N] [--wav FILE]
                     [--hash HEXLO HEXLEN] [--chipdump FILE]
      --hash      print an FNV hash of a RAM region after every frame (lockstep comparison)
      --chipdump  test mode: load an emulator chip snapshot (emu 'chipdump' cmd) and just run the copper/display
    """)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var adfPath = "../re/platoon_port.adf", frames = 500, scriptPath: String?, outDir = "out", shotEvery = 0
var wavPath: String?, hashRange: (UInt32, Int)?, chipdump: String?
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String { guard !args.isEmpty else { usage() }; return args.removeFirst() }
    switch a {
    case "--adf": adfPath = next()
    case "--frames": frames = Int(next()) ?? 500
    case "--script": scriptPath = next()
    case "--out": outDir = next()
    case "--shot-every": shotEvery = Int(next()) ?? 0
    case "--wav": wavPath = next()
    case "--hash": hashRange = (UInt32(next(), radix: 16) ?? 0, Int(next(), radix: 16) ?? 0)
    case "--chipdump": chipdump = next()
    default: usage()
    }
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let disk: Disk
do { disk = try Disk(contentsOf: URL(fileURLWithPath: adfPath)) } catch { print("cannot load ADF \(adfPath): \(error)"); exit(1) }
let m = Machine(disk: disk)
var wav: ImageIO.WAVWriter?
if let w = wavPath { wav = ImageIO.WAVWriter(path: w, sampleRate: 48000); m.chip.paula.output = { wav?.write($0) } }

struct Ev { let frame: Int; let cmd: String; let arg: [String] }
var events: [Ev] = []
if let s = scriptPath, let text = try? String(contentsOfFile: s, encoding: .utf8) {
    for line in text.split(separator: "\n") {
        let p = line.split(separator: " ").map(String.init)
        if p.count >= 2, !p[0].hasPrefix("#"), let f = Int(p[0]) { events.append(Ev(frame: f, cmd: p[1], arg: Array(p.dropFirst(2)))) }
    }
    events.sort { $0.frame < $1.frame }
}

func savePNG(_ name: String) { try? ImageIO.canvasPNG(m.chip).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png")) }

if let cd = chipdump {
    guard let d = FileManager.default.contents(atPath: cd) else { print("no chipdump"); exit(1) }
    let b = [UInt8](d)
    m.memory.restore(Array(b[0..<0x80000]))
    var o = 0x80000
    func u16() -> UInt16 { let v = UInt16(b[o]) << 8 | UInt16(b[o + 1]); o += 2; return v }
    for i in 0..<0x100 { m.chip.regs[i] = u16() }
    let dmacon = u16(), intena = u16(); _ = u16(); _ = u16()
    m.chip.write(0x096, 0x7fff); m.chip.write(0x096, 0x8000 | dmacon)
    m.chip.intena = intena & 0x3fff // no handlers in test mode
    m.start { mm in while true { mm.waitVBlank() } }
} else {
    m.start(PlatoonGame.main)
}

var ei = 0
for f in 0..<frames {
    while ei < events.count && events[ei].frame <= f {
        let e = events[ei]; ei += 1
        let on = (e.arg.first ?? "1") != "0"
        switch e.cmd {
        case "up": m.input.up = on
        case "down": m.input.down = on
        case "left": m.input.left = on
        case "right": m.input.right = on
        case "fire": m.input.fire = on
        case "fire0": m.input.fire0 = on
        case "key": if let c = UInt8(e.arg.first?.replacingOccurrences(of: "0x", with: "") ?? "", radix: 16) { m.input.key(c, down: (e.arg.count > 1 ? e.arg[1] : "1") != "0") }
        case "shot": savePNG(e.arg.first ?? "shot")
        case "dump": FileManager.default.createFile(atPath: "\(outDir)/\(e.arg.first ?? "ram.bin")", contents: Data(m.memory.snapshot()))
        case "dumpr":
            if e.arg.count >= 3, let a = UInt32(e.arg[0], radix: 16), let l = Int(e.arg[1], radix: 16) {
                FileManager.default.createFile(atPath: "\(outDir)/\(e.arg[2])", contents: Data(m.memory.slice(a, l)))
            }
        case "poke":
            if e.arg.count >= 2, let a = UInt32(e.arg[0], radix: 16), let v = UInt32(e.arg[1], radix: 16) {
                switch Int(e.arg.count > 2 ? e.arg[2] : "1") ?? 1 { case 1: m.memory.w8(a, UInt8(truncatingIfNeeded: v)); case 2: m.memory.w16(a, UInt16(truncatingIfNeeded: v)); default: m.memory.w32(a, v) }
            }
        case "quit": wav?.close(); exit(0)
        default: print("unknown script command \(e.cmd)")
        }
    }
    m.runFrame()
    if let (lo, len) = hashRange { print(String(format: "frame %d hash %016llx", f + 1, m.memory.hash(lo, len))) }
    if shotEvery > 0 && (f + 1) % shotEvery == 0 { savePNG(String(format: "f%06d", f + 1)) }
    if m.gameFinished { print("game thread finished at frame \(f + 1)"); break }
}
wav?.close()
