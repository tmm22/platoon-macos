import Foundation

// Savestate service (roadmap L1 quick save/load, M8 auto-checkpoints, M9 rewind).
//
// The host owns one SnapshotController and attaches it to every Machine it runs (`attach(_:)`, i.e.
// `machine.loopHeadService = controller`). The translated game calls `loopHead` at each of its four main-loop
// heads (game thread). There the controller
//   - takes snapshots the host requested (quick save: "at the next opportunity"),
//   - keeps the rewind ring (M9): one snapshot every `rewindIntervalFrames` emulated frames,
//   - detects checkpoint beats from RAM (M8: explosives, bridge, village, huts, tunnel rooms and pickups, flare
//     night, final-jungle rooms, bunker) and keeps the section-start snapshot plus a ring of the latest beats,
//   - notices deaths (for a "retry from checkpoint" prompt).
// All of that only READS game state; with no controller attached (the default) nothing happens at all.
// Results are handed to the host in `drain()`, which the host calls on its own thread after `runFrame`.
//
// Threading: the game thread and the host never run at the same time (Machine hands control back and forth),
// the lock only guards against misuse from other threads (e.g. a UI thread reading the rings).

public final class SnapshotController {
    public init() {}

    // MARK: options

    /// M9: keep a ring of loop-head snapshots (off by default).
    public var rewindEnabled = false
    /// Emulated frames between rewind snapshots (50 = one per second).
    public var rewindIntervalFrames: UInt64 = 50
    /// Number of rewind snapshots kept (30 = 30 s at the default interval; ~1.4 MB each).
    public var rewindCapacity = 30
    /// M8: take automatic checkpoints (off by default).
    public var checkpointsEnabled = false
    /// Number of beat checkpoints kept in addition to the section start.
    public var checkpointCapacity = 3
    /// The current run is assisted/tainted (recorded in the snapshots' info).
    public var assisted = false
    /// No automatic captures (rewind ring, checkpoints) while set - e.g. while the host is scrubbing.
    public var suspended = false
    /// Test aid (headless round trip): after a requested snapshot is delivered, the machine is abandoned at the
    /// capture point (Machine.detach) so a restored copy can continue from exactly there.
    public var detachAfterRequestedCapture = false

    // MARK: events for the host

    public enum Event {
        /// A checkpoint was taken (label, e.g. "Bridge blown").
        case checkpoint(String)
        /// The current soldier died or morale ran out (loop, frame).
        case death(SnapshotLoop, UInt64)
        /// A new section run started at its first main-loop head.
        case sectionStart(SnapshotLoop)
    }
    /// Called from `drain()` on the host thread.
    public var onEvent: ((Event) -> Void)?

    // MARK: state

    private let lock = NSLock()
    private var requests: [(label: String, done: (GameSnapshot) -> Void)] = []
    private var delivered: [() -> Void] = []
    public private(set) var rewindRing: [GameSnapshot] = []
    public private(set) var sectionStart: GameSnapshot?
    public private(set) var checkpoints: [GameSnapshot] = []
    /// The most recent loop head the game passed (nil: not in a section main loop since attach/reset).
    public private(set) var lastLoop: SnapshotLoop?
    public private(set) var lastLoopFrame: UInt64 = 0
    private var lastRewindFrame: UInt64?
    private var beat: Beat?
    private var deadLatched = false
    private var lastDeaths = Int.max

    /// Attaches the controller to a machine (do this for every new Machine).
    public func attach(_ m: Machine) { m.loopHeadService = self }

    /// True while a requested snapshot has not been taken yet.
    public var hasPendingRequest: Bool { lock.lock(); defer { lock.unlock() }; return !requests.isEmpty }

    /// Asks for a snapshot at the next main-loop head. `done` runs on the host thread in `drain()`.
    public func requestSnapshot(label: String = "Quick save", _ done: @escaping (GameSnapshot) -> Void) {
        lock.lock(); requests.append((label, done)); lock.unlock()
    }
    public func cancelRequests() { lock.lock(); requests.removeAll(); lock.unlock() }

    /// Delivers captured snapshots and events (host thread, after runFrame).
    public func drain() {
        lock.lock(); let d = delivered; delivered.removeAll(); lock.unlock()
        for f in d { f() }
    }

    /// Forgets everything about the current run (new game / reset / slot loaded from elsewhere).
    public func resetRun() {
        lock.lock(); defer { lock.unlock() }
        rewindRing.removeAll(); checkpoints.removeAll(); sectionStart = nil
        lastLoop = nil; lastRewindFrame = nil; beat = nil; deadLatched = false; lastDeaths = .max
    }

    /// After travelling back to `frame` (rewind or checkpoint retry): drops rewind snapshots and checkpoints of
    /// the abandoned future, and re-arms beat detection from the restored snapshot.
    public func truncate(after snapshot: GameSnapshot) {
        lock.lock(); defer { lock.unlock() }
        let f = snapshot.info.frame
        rewindRing.removeAll { $0.info.frame > f }
        checkpoints.removeAll { $0.info.frame > f }
        if let s = sectionStart, s.info.frame > f { sectionStart = nil }
        lastRewindFrame = rewindRing.last?.info.frame
        lastLoop = snapshot.info.loop; lastLoopFrame = f
        beat = nil          // re-read at the next loop head without triggering (the restored state is the base)
        rearmBeat = true
        deadLatched = false
        lastDeaths = .max
    }
    private var rearmBeat = false

    /// Makes `snapshot` the base checkpoint of a new run (after loading a saved game).
    public func adoptLoaded(_ snapshot: GameSnapshot) {
        resetRun()
        lock.lock(); sectionStart = snapshot; rearmBeat = true; lastLoop = snapshot.info.loop; lastLoopFrame = snapshot.info.frame; lock.unlock()
    }

    /// The checkpoint "Retry from checkpoint" goes back to: the latest beat, else the section start.
    public var latestCheckpoint: GameSnapshot? { lock.lock(); defer { lock.unlock() }; return checkpoints.last ?? sectionStart }

    // MARK: game thread

    /// Called by the translated game at a main-loop head (`Platoon.snapshotPoint`), before its tickPoint.
    func loopHead(_ p: Platoon, pc: UInt32) {
        guard let loop = SnapshotLoop(rawValue: pc) else { return }
        let frame = p.m.frameCount
        lock.lock()
        let req = requests
        let newSection = lastLoop == nil || lastLoop!.section != loop.section || (lastLoop != loop && loop == .flare)
        lastLoop = loop; lastLoopFrame = frame
        lock.unlock()
        guard p.snapshotSafe else { return }
        // one capture per loop head, relabelled for each use (the arrays are shared copy-on-write)
        var base: GameSnapshot?
        func snap(_ label: String) -> GameSnapshot? {
            if base == nil { base = p.captureSnapshot(pc: pc, label: label, assisted: assisted) }
            guard var s = base else { return nil }
            s.info.label = label
            return s
        }

        // 1. requested snapshots (quick save)
        if !req.isEmpty, let s = snap(req[0].label) {
            lock.lock()
            let rs = requests; requests.removeAll()
            for r in rs { let done = r.done; delivered.append { done(s) } }
            lock.unlock()
            if detachAfterRequestedCapture { p.m.detach() }
        }
        guard !suspended else { return }

        // 2. death notice (for a retry prompt): a soldier record reached 4 hits, or morale ran out
        let dead = p.snapshotManDead(loop)
        let deaths = p.snapshotDeathCount()
        if deaths > lastDeaths && !deadLatched { post(.death(loop, frame)) }
        lastDeaths = deaths
        deadLatched = dead

        // 3. checkpoints (M8)
        if checkpointsEnabled {
            let now = Beat(p, loop).merged(with: beat)
            if rearmBeat {
                rearmBeat = false; beat = now
            } else if newSection || beat == nil {
                beat = Beat(p, loop)
                if !dead, let s = snap("Start: \(loop.title)") {
                    lock.lock()
                    sectionStart = s
                    checkpoints.removeAll { $0.info.section != loop.section }
                    lock.unlock()
                    post(.sectionStart(loop))
                }
            } else if let old = beat, let label = now.advance(from: old) {
                beat = now
                if !dead, let s = snap(label) {
                    lock.lock()
                    checkpoints.append(s)
                    if checkpoints.count > checkpointCapacity { checkpoints.removeFirst(checkpoints.count - checkpointCapacity) }
                    lock.unlock()
                    post(.checkpoint(label))
                }
            } else {
                beat = now
            }
        }

        // 4. rewind ring (M9)
        if rewindEnabled, lastRewindFrame.map({ frame >= $0 &+ rewindIntervalFrames || frame < $0 }) ?? true,
           let s = snap("Rewind") {
            lock.lock()
            rewindRing.append(s)
            if rewindRing.count > rewindCapacity { rewindRing.removeFirst(rewindRing.count - rewindCapacity) }
            lastRewindFrame = frame
            lock.unlock()
        }
    }

    private func post(_ e: Event) {
        lock.lock(); delivered.append { [weak self] in self?.onEvent?(e) }; lock.unlock()
    }

    // MARK: tags

    private static var adfTags: [ObjectIdentifier: UInt64] = [:]
    private static let tagLock = NSLock()
    /// Cached `GameSnapshot.adfTag(disk)`.
    public static func adfTag(for disk: Disk) -> UInt64 {
        tagLock.lock(); defer { tagLock.unlock() }
        if let t = adfTags[ObjectIdentifier(disk)] { return t }
        let t = GameSnapshot.adfTag(disk); adfTags[ObjectIdentifier(disk)] = t; return t
    }
}

// MARK: - checkpoint beats (read-only RAM probes, M8)

/// Progress markers of a section run. A checkpoint is taken at the first loop head after one of them advanced.
struct Beat: Equatable {
    var loop: SnapshotLoop
    // section 0
    var explosives = false, bridgeBlown = false, torch = false, map = false, village = false
    var hutsVisited: UInt8 = 0
    // section 1
    var inRoom = false, room: UInt16 = 0, pickups = 0
    // section 2
    var s2Room: UInt8 = 0, bunker = false

    init(_ p: Platoon, _ loop: SnapshotLoop) {
        self.loop = loop
        let mem = p.mem, a6 = p.a6
        switch loop {
        case .jungle:
            explosives = mem.r16(0x12e06) != 0
            bridgeBlown = mem.r16(0x60c9c) == 2
            torch = mem.r8(0x60cbd) != 0
            map = mem.r16(a6 + KV.mapIcon) != 0
            let plevel = mem.r16(0x60c2a), pworld = mem.r16(0x60c30)
            village = plevel == 0 && pworld >= 0x181 && pworld < 0x2aa
            if mem.r16(0x5f89a) == 5 { hutsVisited |= UInt8(1) << UInt8(mem.r16(0x60c40) & 7) }   // pstate 5: in hut
        case .tunnels, .flare:
            inRoom = mem.r8(S1.inRoom) != 0
            room = mem.r16(S1.roomIndex2)
            pickups = Int(mem.r16(a6 + KV.gunCount)) + Int(mem.r16(a6 + KV.compassOn) != 0 ? 1 : 0)
                + Int(mem.r16(a6 + KV.mapIcon) != 0 ? 1 : 0)
        case .finalJungle:
            s2Room = mem.r8(Platoon.S2.vRoom)
            bunker = mem.r8(Platoon.S2.vExits) == 0
        }
    }

    /// Label of the beat reached since `old`, nil when nothing advanced. Hut visits are cumulative (a bit set
    /// is kept by `merge`).
    func advance(from old: Beat) -> String? {
        guard loop == old.loop else { return nil }
        switch loop {
        case .jungle:
            if explosives && !old.explosives { return "Explosives found" }
            if bridgeBlown && !old.bridgeBlown { return "Bridge blown" }
            if torch && !old.torch { return "Torch found" }
            if map && !old.map { return "Map found" }
            if village && !old.village { return "Village" }
            if hutsVisited & ~old.hutsVisited != 0 {
                let fresh = hutsVisited & ~old.hutsVisited
                var n = 0
                while n < 7 && fresh & (UInt8(1) << UInt8(n)) == 0 { n += 1 }
                return "Hut " + String(n + 1)
            }
        case .tunnels:
            if inRoom && !old.inRoom { return "Tunnel room" }
            if pickups > old.pickups { return "Item found" }
        case .flare:
            return nil
        case .finalJungle:
            if bunker && !old.bunker { return "Bunker" }
            if s2Room != old.s2Room { return "Jungle room" }
        }
        return nil
    }
}

extension Beat {
    /// Keeps cumulative markers (visited huts, village seen) so walking back out does not re-trigger them.
    func merged(with old: Beat?) -> Beat {
        guard let o = old, o.loop == loop else { return self }
        var b = self
        b.hutsVisited |= o.hutsVisited
        b.village = b.village || o.village
        return b
    }
}

extension Platoon {
    /// Soldiers killed (records with 4 hits) plus 1 when morale is 0 (read-only; for the retry prompt).
    func snapshotDeathCount() -> Int {
        var n = mem.r16(a6 + KV.morale) == 0 ? 1 : 0
        for i in 0..<5 where mem.r16(a6 + UInt32(6 * i) + 4) >= 4 { n += 1 }
        return n
    }

    /// The current soldier is dead (4 hits) or morale ran out (read-only; for the retry prompt).
    func snapshotManDead(_ loop: SnapshotLoop) -> Bool {
        if mem.r16(a6 + KV.morale) == 0 { return true }
        let man = mem.r32(a6 + KV.curMan)
        guard man >= a6, man <= a6 + 24 else { return false }
        return mem.r16(man + 4) >= 4
    }
}
