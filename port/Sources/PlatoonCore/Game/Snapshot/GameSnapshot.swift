import Foundation

// Savestates (roadmap F5/L1): the snapshot container and its file format.
//
// A snapshot is taken on the game thread at one of the four section main-loop heads, where the Swift game-thread
// stack holds no game state (everything is in chip RAM, the virtual chipset and a few Platoon host variables):
//   $17186 s0 main_loop (jungle & village)   $171c6 s1 tunnel main loop
//   $18bd8 s1 flare_main_loop                $17118 s2 main_loop (final jungle & foxhole)
// Restoring rebuilds that state in a Machine and continues on a fresh game thread through a loop-entry wrapper
// (SnapshotResume.swift), at the same beam line of the same frame, so a restored game continues exactly like the
// uninterrupted one (verified by the headless round-trip test: tick dumps byte-identical).
//
// File layout (".pltsnap"):
//   "PLTSNAP\0"  u32 format version  u32 header length  header (SnapWriter)  payload (zlib-compressed SnapWriter)
// The header holds everything a slot menu needs (thumbnail PNG, section, score, dates, build/ADF tags) without
// decompressing the payload.

/// Where (which main loop) a snapshot was taken.
public enum SnapshotLoop: UInt32, CaseIterable {
    case jungle = 0x17186       // section 0 main loop
    case tunnels = 0x171c6      // section 1 tunnel main loop
    case flare = 0x18bd8        // section 1 flare main loop
    case finalJungle = 0x17118  // section 2 main loop

    public var section: Int {
        switch self { case .jungle: return 0; case .tunnels, .flare: return 1; case .finalJungle: return 2 }
    }
    public var title: String {
        switch self {
        case .jungle: return "Jungle & Village"
        case .tunnels: return "Tunnels"
        case .flare: return "Flare Night"
        case .finalJungle: return "Final Jungle"
        }
    }
}

/// Metadata of a snapshot (the uncompressed file header).
public struct SnapshotInfo {
    public var loop: SnapshotLoop
    /// Emulated frame number at the capture.
    public var frame: UInt64
    public var created: Date
    /// Score, 8 BCD digits ($4e(a6)).
    public var scoreBCD: UInt32
    /// Morale ($2e(a6), 8.8 fixed point) and the current man index ($22(a6)).
    public var morale: UInt16
    public var manIndex: UInt16
    /// Build tag of the program that wrote the snapshot (hash of the executable) and the disk image tag.
    public var buildTag: String
    public var adfTag: UInt64
    /// The run the snapshot came from was already assisted/tainted (loaded, rewound, trainer, ...).
    public var assisted: Bool
    /// PNG thumbnail of the display (lowres, cropped to the game window, half size).
    public var thumbnailPNG: Data
    /// Free-form label ("Quick save", "Checkpoint: bridge blown", ...).
    public var label: String

    public var score: String {
        let s = String(format: "%08X", scoreBCD)
        let t = s.drop { $0 == "0" }
        return t.isEmpty ? "0" : String(t)
    }
    public var section: Int { loop.section }
}

/// Host-side (not in RAM) state of the translated program that must survive a restore.
struct PlatoonHostState {
    var cpuCycles = 0
    var interruptedD1: UInt32 = 0
    var startSectionDone = false
    var loadedSection = -1
    var diskCylinder = 0
    var diskRandState: UInt32 = 1
    var musicPlaying = false
    var cpuBusy = false
    var irqDepth = 0
    var irqPreempted = 0
    var irqBusyUntil = 0
    // verification aids of section 2 (process globals, only used with S2PACE/S2PACEPL)
    var s2PaceIndex = 0
    var s2PacePlayerIndex = 0
    // enhancement host state (Enhance/*.swift, core): F4 run marks, S5 per-mode hiscore tables, F2 flags
    var runAssist: [String] = []
    var hsSavedOriginal: [UInt8]?
    var hsActiveMode: String?
    var hsPristine: [UInt8]?
    var hsModeTables: [String: [UInt8]] = [:]
    var inF10 = false
    var textScreenPending = false
    /// Extension area for host state added later (key -> bytes), see SnapshotResume.swift.
    var extras: [String: [UInt8]] = [:]

    func encode(into w: inout SnapWriter) {
        w.int(cpuCycles); w.u32(interruptedD1); w.bool(startSectionDone); w.int(loadedSection); w.int(diskCylinder)
        w.u32(diskRandState); w.bool(musicPlaying); w.bool(cpuBusy); w.int(irqDepth); w.int(irqPreempted); w.int(irqBusyUntil)
        w.int(s2PaceIndex); w.int(s2PacePlayerIndex)
        w.u32(UInt32(runAssist.count)); for r in runAssist { w.string(r) }
        func opt(_ b: [UInt8]?) { w.bool(b != nil); if let b { w.bytes(b) } }
        opt(hsSavedOriginal); w.bool(hsActiveMode != nil); w.string(hsActiveMode ?? ""); opt(hsPristine)
        w.u32(UInt32(hsModeTables.count)); for k in hsModeTables.keys.sorted() { w.string(k); w.bytes(hsModeTables[k]!) }
        w.bool(inF10); w.bool(textScreenPending)
        w.u32(UInt32(extras.count))
        for k in extras.keys.sorted() { w.string(k); w.bytes(extras[k]!) }
    }
    static func decode(_ r: inout SnapReader) throws -> PlatoonHostState {
        var h = PlatoonHostState()
        h.cpuCycles = try r.int(); h.interruptedD1 = try r.u32(); h.startSectionDone = try r.bool(); h.loadedSection = try r.int()
        h.diskCylinder = try r.int(); h.diskRandState = try r.u32(); h.musicPlaying = try r.bool(); h.cpuBusy = try r.bool()
        h.irqDepth = try r.int(); h.irqPreempted = try r.int(); h.irqBusyUntil = try r.int()
        h.s2PaceIndex = try r.int(); h.s2PacePlayerIndex = try r.int()
        for _ in 0..<Int(try r.u32()) { h.runAssist.append(try r.string()) }
        func opt() throws -> [UInt8]? { try r.bool() ? try r.bytes() : nil }
        h.hsSavedOriginal = try opt()
        let hasMode = try r.bool(), mode = try r.string(); h.hsActiveMode = hasMode ? mode : nil
        h.hsPristine = try opt()
        for _ in 0..<Int(try r.u32()) { let k = try r.string(); h.hsModeTables[k] = try r.bytes() }
        h.inF10 = try r.bool(); h.textScreenPending = try r.bool()
        let n = Int(try r.u32())
        for _ in 0..<n { let k = try r.string(); h.extras[k] = try r.bytes() }
        return h
    }
}

/// A complete loop-head snapshot of a running game.
public struct GameSnapshot {
    public static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("PLTSNAP".utf8) + [0]

    public var info: SnapshotInfo
    public var machine: MachineState
    var host: PlatoonHostState

    public enum Failure: Error, CustomStringConvertible {
        case notASnapshot, unsupportedVersion(UInt32), corrupt, wrongDisk
        public var description: String {
            switch self {
            case .notASnapshot: return "This is not a Platoon saved game."
            case .unsupportedVersion(let v): return "This saved game uses an unsupported format (version \(v))."
            case .corrupt: return "The saved game is damaged."
            case .wrongDisk: return "This saved game was made with a different Platoon disk image."
            }
        }
    }

    // MARK: encoding

    public func encoded() -> Data {
        var h = SnapWriter()
        Self.encodeInfo(info, into: &h)
        var p = SnapWriter()
        machine.encode(into: &p)
        host.encode(into: &p)
        machine.chip.paula.encodeA500(into: &p)          // optional trailer (older files end before it)
        let payload = (try? (p.data as NSData).compressed(using: .zlib) as Data) ?? Data()
        var out = Data(Self.magic)
        var v = SnapWriter(); v.u32(Self.formatVersion); v.u32(UInt32(h.data.count))
        out.append(v.data); out.append(h.data); out.append(payload)
        return out
    }

    public static func decode(_ d: Data) throws -> GameSnapshot {
        let (info, payloadStart) = try decodeHeader(d)
        guard let raw = try? (d.subdata(in: payloadStart..<d.count) as NSData).decompressed(using: .zlib) as Data else {
            throw Failure.corrupt
        }
        do {
            var r = SnapReader(raw)
            var m = try MachineState.decode(&r)
            let h = try PlatoonHostState.decode(&r)
            if !r.atEnd { try m.chip.paula.decodeA500(&r) }
            return GameSnapshot(info: info, machine: m, host: h)
        } catch { throw Failure.corrupt }
    }

    /// Reads only the header (for slot menus).
    public static func readInfo(_ d: Data) throws -> SnapshotInfo { try decodeHeader(d).0 }

    static func decodeHeader(_ d: Data) throws -> (SnapshotInfo, Int) {
        let b = [UInt8](d.prefix(16))
        guard b.count == 16, Array(b[0..<8]) == magic else { throw Failure.notASnapshot }
        var r = SnapReader(Array(b[8..<16]))
        let ver = try r.u32(), hlen = Int(try r.u32())
        guard ver == formatVersion else { throw Failure.unsupportedVersion(ver) }
        guard 16 + hlen <= d.count else { throw Failure.corrupt }
        var hr = SnapReader(d.subdata(in: 16..<(16 + hlen)))
        do { return (try decodeInfo(&hr), 16 + hlen) } catch { throw Failure.corrupt }
    }

    static func encodeInfo(_ i: SnapshotInfo, into w: inout SnapWriter) {
        w.u32(i.loop.rawValue); w.u64(i.frame); w.f64(i.created.timeIntervalSince1970); w.u32(i.scoreBCD)
        w.u16(i.morale); w.u16(i.manIndex); w.string(i.buildTag); w.u64(i.adfTag); w.bool(i.assisted)
        w.raw(i.thumbnailPNG); w.string(i.label)
    }
    static func decodeInfo(_ r: inout SnapReader) throws -> SnapshotInfo {
        guard let loop = SnapshotLoop(rawValue: try r.u32()) else { throw Failure.corrupt }
        return SnapshotInfo(loop: loop, frame: try r.u64(), created: Date(timeIntervalSince1970: try r.f64()),
                            scoreBCD: try r.u32(), morale: try r.u16(), manIndex: try r.u16(), buildTag: try r.string(),
                            adfTag: try r.u64(), assisted: try r.bool(), thumbnailPNG: try r.raw(), label: try r.string())
    }

    // MARK: files

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
    public static func read(from url: URL) throws -> GameSnapshot { try decode(try Data(contentsOf: url)) }

    // MARK: compatibility tags

    /// FNV-1a of the disk image (a snapshot only makes sense with the disk the game data came from: later
    /// sections are loaded from it).
    public static func adfTag(_ disk: Disk) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        disk.data.withUnsafeBufferPointer { for b in $0 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        return h
    }

    /// Tag of the running build: FNV-1a of the executable (a snapshot from another build is allowed but flagged,
    /// because the translated code and its host variables may differ).
    public static let buildTag: String = {
        guard let url = Bundle.main.executableURL, let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return "unknown" }
        var h: UInt64 = 0xcbf29ce484222325
        d.withUnsafeBytes { p in for b in p.bindMemory(to: UInt8.self) { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        return String(format: "%016llx", h)
    }()

    /// Checks that this snapshot can be loaded with `disk`; returns a warning for a different build.
    public func compatibility(with disk: Disk) throws -> String? {
        if info.adfTag != GameSnapshot.adfTag(disk) { throw Failure.wrongDisk }
        return info.buildTag == GameSnapshot.buildTag ? nil : "This game was saved by a different build of Platoon."
    }

    // MARK: thumbnail

    /// Half-size lowres PNG of the game window area of the canvas (x from DIW $71, 336 x 145).
    static func thumbnail(_ canvas: UnsafePointer<UInt32>) -> Data {
        let x0 = (0x71 - Chipset.canvasH0) * 2, w = 168, h = Chipset.canvasHeight / 2
        return ImageIO.png(width: w, height: h) { x, y in canvas[(y * 2) * Chipset.canvasWidth + x0 + x * 4] }
    }
    static func thumbnail(_ canvas: [UInt32]) -> Data { canvas.withUnsafeBufferPointer { thumbnail($0.baseAddress!) } }
}
