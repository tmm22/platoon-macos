import Foundation
import PlatoonCore

// Savestate test modes of the headless runner (roadmap F5/L1, M8, M9). See port/verify/snapshot/README.md.
//
//   --snapshot-save N FILE   take a snapshot at the first main-loop head at/after frame N and write it to FILE
//                            (the run continues normally)
//   --snapshot-load FILE     start from a snapshot file instead of power-on (script events up to the snapshot's
//                            frame are skipped; --frames counts absolute frames)
//   --roundtrip N[,N...]     at the first loop head at/after each frame N: snapshot, encode+decode, abandon the
//                            machine there (Machine.detach) and continue in a FRESH Machine restored from the
//                            snapshot. Tick dumps / --hash output must equal an uninterrupted run byte for byte.
//   --roundtrip-every K      the same every K frames (K, 2K, ...)
//   --roundtrip-inplace      restore into the same Machine object (the app's path) instead of a fresh one
//   --rewind-ring            keep the M9 rewind ring (capture only; the run must stay identical)
//   --rewind-at N BACK       M9 test: at frame N go back BACK ring entries and replay the script from there (repeatable)
//   --checkpoints            M8: take automatic checkpoints, print them
//   --retry-at N             M8 test: at frame N restore the latest checkpoint and replay the script from there
final class HeadlessSnapshots {
    let controller = SnapshotController()
    var saveAt: (frame: Int, path: String)?
    var loadPath: String?
    var roundtripFrames: [Int] = []
    var roundtripEvery = 0
    var inPlace = false
    var rewindRing = false
    var rewindAt: [(frame: Int, back: Int)] = []
    var checkpoints = false
    var retryAt: [Int] = []
    private(set) var loaded: GameSnapshot?
    private var pendingRoundtrip = false
    private var captured: GameSnapshot?
    private var nextRoundtrip = 0

    var active: Bool {
        saveAt != nil || loadPath != nil || !roundtripFrames.isEmpty || roundtripEvery > 0 || rewindRing || !rewindAt.isEmpty
            || checkpoints || !retryAt.isEmpty
    }

    /// Parses one command-line option; returns false if it is not a snapshot option.
    func parse(_ a: String, _ next: () -> String) -> Bool {
        switch a {
        case "--snapshot-save": let n = Int(next()) ?? 0; saveAt = (n, next())
        case "--snapshot-load": loadPath = next()
        case "--roundtrip": roundtripFrames = next().split(separator: ",").compactMap { Int($0) }.sorted()
        case "--roundtrip-every": roundtripEvery = Int(next()) ?? 0
        case "--roundtrip-inplace": inPlace = true
        case "--rewind-ring": rewindRing = true
        case "--rewind-at": let n = Int(next()) ?? 0; rewindAt.append((n, Int(next()) ?? 1)); rewindRing = true
        case "--checkpoints": checkpoints = true
        case "--retry-at": retryAt = next().split(separator: ",").compactMap { Int($0) }.sorted(); checkpoints = true
        default: return false
        }
        return true
    }

    static let usage = """
      --snapshot-save N FILE / --snapshot-load FILE / --roundtrip N[,N..] / --roundtrip-every K / --roundtrip-inplace
      --rewind-ring / --rewind-at N BACK / --checkpoints / --retry-at N[,N..]   savestate tests (Snapshots.swift)
    """

    func log(_ s: String) { print("snapshot: \(s)"); fflush(stdout) }

    /// Loads --snapshot-load (before the machine starts). Returns the first frame to run.
    func prepare(_ m: Machine, disk: Disk) -> Int {
        guard active else { return 0 }
        controller.attach(m)
        controller.rewindEnabled = rewindRing
        controller.checkpointsEnabled = checkpoints
        controller.onEvent = { [unowned self] e in
            switch e {
            case .checkpoint(let l): self.log("checkpoint '\(l)' f\(m.frameCount)")
            case .sectionStart(let l): self.log("section start \(l.title) f\(m.frameCount)")
            case .death(let l, let f): self.log("death in \(l.title) at f\(f)")
            }
        }
        if let p = loadPath {
            do {
                let s = try GameSnapshot.read(from: URL(fileURLWithPath: p))
                if let w = try s.compatibility(with: disk) { log("warning: \(w)") }
                loaded = s
                log(String(format: "loaded %@: %@ frame %llu line %d score %@", p, s.info.loop.title, s.info.frame, s.machine.line, s.info.score))
                return Int(s.info.frame)
            } catch { print("cannot load snapshot \(p): \(error)"); exit(1) }
        }
        return 0
    }

    /// Before the frame `f` is emulated: issue snapshot requests that are due.
    func beforeFrame(_ f: Int) {
        guard active else { return }
        if let s = saveAt, s.frame == f {
            controller.requestSnapshot(label: "headless") { [unowned self] snap in
                do {
                    try snap.write(to: URL(fileURLWithPath: s.path))
                    self.log(String(format: "saved %@: %@ frame %llu line %d", s.path, snap.info.loop.title, snap.info.frame, snap.machine.line))
                } catch { self.log("save failed: \(error)") }
            }
        }
        var due = false
        while nextRoundtrip < roundtripFrames.count && roundtripFrames[nextRoundtrip] <= f { nextRoundtrip += 1; due = true }
        if roundtripEvery > 0 && f > 0 && f % roundtripEvery == 0 { due = true }
        if due && !pendingRoundtrip {
            pendingRoundtrip = true
            controller.detachAfterRequestedCapture = true
            controller.requestSnapshot(label: "roundtrip") { [unowned self] snap in self.captured = snap }
        }
    }

    /// After `runFrame` for frame `f`: performs round trips / rewinds. May replace `m` and move `f` / `ei` back.
    func afterFrame(_ m: inout Machine, _ f: inout Int, _ ei: inout Int, eventFrames: [Int], disk: Disk, config: GameConfig) {
        guard active else { return }
        controller.drain()
        if let snap = captured {
            captured = nil
            pendingRoundtrip = false
            controller.detachAfterRequestedCapture = false
            // through the file format
            let data = snap.encoded()
            let s: GameSnapshot
            do { s = try GameSnapshot.decode(data) } catch { print("snapshot decode failed: \(error)"); exit(1) }
            precondition(Int(s.info.frame) == f, "round trip: captured in frame \(s.info.frame), host at \(f)")
            let target = inPlace ? m : Machine(disk: disk)
            if !inPlace {
                target.frameHook = m.frameHook
                target.chip.paula.sampleRate = m.chip.paula.sampleRate
                target.chip.paula.filterEnabled = m.chip.paula.filterEnabled
                target.chip.paula.output = m.chip.paula.output
                m.chip.paula.output = nil
            }
            PlatoonGame.resume(target, from: s, config: config, assisted: nil)   // exact continuation
            controller.attach(target)
            m = target
            log(String(format: "round trip at %@ frame %d line %d (%d bytes)", s.info.loop.title, f, s.machine.line, data.count))
            m.runFrame()          // the rest of the captured frame
        }
        if let i = rewindAt.firstIndex(where: { $0.frame == f }) {
            let r = rewindAt.remove(at: i)
            let ring = controller.rewindRing
            guard ring.count >= r.back else { log("rewind: only \(ring.count) snapshots"); return }
            let s = ring[ring.count - r.back]
            log("rewind ring: " + ring.map { String($0.info.frame) }.joined(separator: " "))
            travel(to: s, &m, &f, &ei, eventFrames: eventFrames, config: config, what: "rewind \(r.back) back")
        }
        if let i = retryAt.firstIndex(of: f) {
            retryAt.remove(at: i)
            guard let s = controller.latestCheckpoint else { log("retry: no checkpoint"); return }
            travel(to: s, &m, &f, &ei, eventFrames: eventFrames, config: config, what: "retry checkpoint '\(s.info.label)'")
        }
    }

    /// Restores `s` in place (as the app does) and moves the script back to its frame.
    private func travel(to s: GameSnapshot, _ m: inout Machine, _ f: inout Int, _ ei: inout Int, eventFrames: [Int],
                        config: GameConfig, what: String) {
        PlatoonGame.resume(m, from: s, config: config, assisted: nil)
        controller.truncate(after: s)
        controller.attach(m)
        let from = f
        f = Int(s.info.frame)
        ei = eventFrames.firstIndex { $0 > f } ?? eventFrames.count
        log(String(format: "%@: frame %d -> %@ frame %d line %d", what, from, s.info.loop.title, f, s.machine.line))
        m.runFrame()              // the rest of the snapshot's frame
    }
}
