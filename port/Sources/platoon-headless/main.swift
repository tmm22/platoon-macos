import Foundation
import PlatoonCore

// Headless runner for verification against tools/amiga/emu. Uses the same script format:
//   FRAME up|down|left|right|fire|fire0 0|1 ; FRAME key CODE 0|1 ; FRAME shot NAME ; FRAME dump FILE
//   FRAME dumpr HEXADDR HEXLEN FILE ; FRAME poke HEXADDR HEXVAL SIZE ; FRAME quit

func usage() -> Never {
    print("""
    platoon-headless [--adf FILE] [--frames N] [--script FILE] [--out DIR] [--shot-every N] [--wav FILE]
                     [--hash HEXLO HEXLEN] [--chipdump FILE] [--start-section N] [--deterministic]
                     [--tickdump HEXPC HEXLO HEXLEN FILE]
                     [--music-test SONG] [--sfx-test ID] [--audio-test] [--reglog FILE] [--wav-rate HZ] [--no-filter]
      --hash      print an FNV hash of a RAM region after every frame (lockstep comparison)
      --start-section N  skip the title and start a new game in load section N (0,1,2)
      --trainer LIST     ammo,morale,invulnerable (host-side trainer, as in the app)
      --deterministic    no 'interrupted d1' term in the vblank RNG (pair with emu --deterministic)
      --tickdump  append [u32 frame][LEN bytes at LO] whenever translated code calls tickPoint(PC)
      --music-test SONG  audio test mode: load the main program, run only the music driver (vblank md_play),
                         start song SONG (0..6) before frame 0. Script cmds: music N, musicoff, stop, fade, sfx ID (hex, kernel routing),
                         rawsfx D0 (hex, (channel<<8)|id straight to the driver $2838)
      --sfx-test ID      audio test mode (music off unless --music-test): trigger sfx ID (hex, e.g. 82) at frame 0
      --audio-test       audio test mode without an initial song (drive it with script cmds music/musicoff/stop/sfx)
      --reglog FILE      log every custom register write of the music driver ("W f<frame> v<line> CPU reg=val")
      --wav-rate HZ      Paula output rate for --wav (default 48000); --no-filter: disable the A500 low-pass
      --chipdump  test mode: load an emulator chip snapshot (emu 'chipdump' cmd) and just run the copper/display
    """)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var adfPath = "../re/platoon_port.adf", frames = 500, scriptPath: String?, outDir = "out", shotEvery = 0
var wavPath: String?, hashRange: (UInt32, Int)?, chipdump: String?
var config = GameConfig()
var trainer = Trainer()
var musicTest: Int?, sfxTest: Int?, audioTestMode = false, reglogPath: String?, wavRate = 48000, noFilter = false
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
    case "--start-section": config.startSection = Int(next())
    case "--deterministic": config.deterministicRNG = true
    case "--trainer": for t in next().split(separator: ",") { switch t { case "ammo": trainer.infiniteAmmo = true; case "morale": trainer.infiniteMorale = true; case "invulnerable": trainer.invulnerable = true; default: usage() } }
    case "--tickdump":
        let pc = UInt32(next(), radix: 16) ?? 0, lo = UInt32(next(), radix: 16) ?? 0, len = Int(next(), radix: 16) ?? 0, f = next()
        FileManager.default.createFile(atPath: f, contents: nil)
        if let h = FileHandle(forWritingAtPath: f) { config.tickDumps.append((pc, lo, len, h)) }
    case "--music-test": musicTest = Int(next())
    case "--sfx-test": sfxTest = Int(next(), radix: 16)
    case "--audio-test": audioTestMode = true
    case "--reglog": reglogPath = next()
    case "--wav-rate": wavRate = Int(next()) ?? 48000
    case "--no-filter": noFilter = true
    default: usage()
    }
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let disk: Disk
do { disk = try Disk(contentsOf: URL(fileURLWithPath: adfPath)) } catch { print("cannot load ADF \(adfPath): \(error)"); exit(1) }
let m = Machine(disk: disk)
if trainer.isActive { m.frameHook = { trainer.apply(to: $0) } }
var wav: ImageIO.WAVWriter?
if let w = wavPath {
    m.chip.paula.sampleRate = Double(wavRate)
    wav = ImageIO.WAVWriter(path: w, sampleRate: wavRate); m.chip.paula.output = { wav?.write($0) }
}
if noFilter { m.chip.paula.filterEnabled = false }
var reglog: FileHandle?
if let r = reglogPath {
    FileManager.default.createFile(atPath: r, contents: nil)
    reglog = FileHandle(forWritingAtPath: r)
    MusicDriverTrace.write = { reg, v in
        reglog?.write(String(format: "W f%d v%d CPU %03x=%04x pc=002800\n", m.frameCount, m.chip.vpos, reg, v).data(using: .utf8)!)
    }
}
let audioTest: MusicDriverTestHarness? = (musicTest != nil || sfxTest != nil || audioTestMode) ? MusicDriverTestHarness(machine: m) : nil

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
} else if let at = audioTest {
    at.setup()
    m.start { mm in while true { mm.waitVBlank() } }
    if let n = musicTest { at.music(n) }
    if let id = sfxTest { at.sfx(id) }
} else {
    m.start { PlatoonGame.main($0, config: config) }
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
        case "music": audioTest?.music(Int(e.arg.first ?? "0") ?? 0)
        case "musicoff": audioTest?.musicOff()
        case "stop": audioTest?.stop()
        case "rawsfx": audioTest?.rawSfx(UInt16(e.arg.first?.replacingOccurrences(of: "0x", with: "") ?? "0", radix: 16) ?? 0)
        case "fade": audioTest?.fade()
        case "sfx": audioTest?.sfx(Int(e.arg.first?.replacingOccurrences(of: "0x", with: "") ?? "0", radix: 16) ?? 0)
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
