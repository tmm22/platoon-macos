// Section 0 enhancement helpers (owner: section0). Every hook in the translated section-0 code is marked
// `// ENHANCEMENT <ID>` and guarded by an option of Enhance/Section0Options.swift (default = original behaviour);
// the helpers they call live here so that the translated routines stay readable. None of these functions is
// reached with all options at their defaults.
//
//   S6   bridge failsafe            s0ScrollStep (Section0Player.swift)
//   S7   forgiving booby traps      s0TrapUpdate (Section0Objects.swift), s0ItemBoobyTrap (Section0Village.swift)
//   S9b  morale bonus clamp         s0CrateOpen, s0ItemTorch, s0ItemMap -> s0MoraleAdd
//   S9f  hut-1 dummy not shootable  s0HitPBullet
//   S9g  tripwire spawn x           s0TrapSpawn
//   S9k  trap-door bonus            s0TrapdoorYes
//   M10  difficulty knobs           main loop (spawn floor), sec0_restart (grenades/ammo), en_st2_walk (shoot mask),
//                                   ph_done (hit morale), enemy_score (villager morale), hit_pbullet (rifle vs
//                                   spider-hole VC), item_map (no map)
//   M14  explicit jump / crouch     s0PlSt0Walk -> s0M14Walk
//   L3   village randomiser         section0_start -> s0RandomiseVillage
//   L4   widescreen latch           main loop / trap-door loop after k_swap -> JungleWideLatch (host-only, no RAM)

import Foundation

// MARK: - M14 host buttons

/// Host-side jump/crouch buttons for M14 (explicit jump and crouch). The input layer sets them every frame (they are
/// NOT part of the Amiga joystick/keyboard and never written to RAM); the section-0 code reads them only when
/// `s0.explicitJumpCrouch` is on. Headless tests can use the Amiga keys `s0.jumpKey` / `s0.crouchKey` instead.
public final class Section0HostButtons {
    public var jump = false
    public var crouch = false
    init() {}

    private static let lock = NSLock()
    private final class Weak { weak var m: Machine?; let b: Section0HostButtons; init(_ m: Machine, _ b: Section0HostButtons) { self.m = m; self.b = b } }
    private static var table: [ObjectIdentifier: Weak] = [:]

    /// The buttons of `machine` (created on first use). Main/host thread; the game thread reads them in the tick.
    public static func of(_ machine: Machine) -> Section0HostButtons {
        lock.lock(); defer { lock.unlock() }
        let k = ObjectIdentifier(machine)
        if let w = table[k], w.m === machine { return w.b }
        table = table.filter { $0.value.m != nil }
        let b = Section0HostButtons()
        table[k] = Weak(machine, b)
        return b
    }

    static func existing(_ machine: Machine) -> Section0HostButtons? {
        lock.lock(); defer { lock.unlock() }
        guard let w = table[ObjectIdentifier(machine)], w.m === machine else { return nil }
        return w.b
    }
}

extension Platoon {
    // MARK: - M14 explicit jump / crouch

    /// M14 variant of pl_st0_walk after the align check: jump / crouch controls first; UP/DOWN only take paths and
    /// doors (UP/DOWN where there is none = plain horizontal movement). Mirrors $177ca otherwise.
    func s0M14Walk() {
        let o = enhancements.section0
        let host = Section0HostButtons.existing(m)
        let jump = (host?.jump ?? false) || (o.jumpKey.map { r_keytest(UInt8($0)) } ?? false)
        let crouch = (host?.crouch ?? false) || (o.crouchKey.map { r_keytest(UInt8($0)) } ?? false)
        if jump { s0PlStartJump(); return }                 // take-off direction from the held stick (jumpInput)
        if crouch { s0PlCrouch(); return }                  // re-asserted every tick while held
        let d0 = UInt16(v0.input) & 5
        if d0 == 0 || d0 == 5 { s0PlHorizontal(); return }
        let a0 = v0.pmapptr
        if d0 & 1 == 0 {
            // UP: hut doors on level 0, up-paths elsewhere; nothing else
            if v0.level == 0 {
                let (fail, d1) = s0HutDoorCheck()
                if fail { s0PlHorizontal(); return }
                v0.hut = d1
                v0.savefacing = v0.pfacing
                v0.pathofs = 0x18
                v0.pstate = 4
                return
            }
            let d = s0Abs(v0.c34)
            if mem.r8(a0) != 3 || (!(d < 3) && d < 6) { s0PlHorizontal(); return }
            v0.savefacing = v0.pfacing
            v0.pstate = 3
            v0.pathofs = 0xffff
            s0AlignClearC32()
            return
        }
        // DOWN: down-paths only
        let d = s0Abs(v0.c34)
        if mem.r8(a0) != 4 || (!(d < 3) && d < 6) { s0PlHorizontal(); return }
        v0.savefacing = v0.pfacing
        v0.pstate = 2
        v0.pathofs = 0
        v0.pcnt = 0
        s0AlignClearC32()
    }

    // MARK: - S6 bridge failsafe

    /// S6: true if a step right must be refused because it would reach the doom column $4e of the unblown,
    /// un-mined bridge (level 1). pworld ($60c30) grows by 2 per 4-px scroll step pair and changes in the MIDDLE of
    /// an 8-px step (align 4), so the guard only refuses to START a step (align 0): standing aligned at pworld $270
    /// (column $4d) is the last position; the next step would end at $272 = column $4e. Refusing a step that is
    /// under way (align != 0) would leave the player stuck mid-step: pl_keep_walking ignores the stick until the
    /// step is finished, so he could never walk back for the explosives.
    func s0BridgeFailsafeBlocks() -> Bool {
        guard v0.level == 1, v0.bridge == 0, v0.align == 0, v0.pworld >= 0x270, v0.pcol < 0x4e else { return false }
        if v0.msgCount == 0 { k_queue_text(0x11) }          // SET THE EXPLOSIVES ON THE BRIDGE
        v0.pframe = 8                                       // stand, as when a tree blocks
        return true
    }

    // MARK: - S9 (b) morale clamp

    /// Morale bonus `add.w #d,$2e(a6)`: wraps like the original unless S9b is on (then clamped at $ffff).
    func s0MoraleAdd(_ d: UInt16) {
        if enhancements.section0.fixMoraleWrap {             // ENHANCEMENT S9b
            v0.morale = UInt16(min(0xffff, Int(v0.morale) + Int(d)))
        } else {
            v0.morale = v0.morale &+ d
        }
    }

    // MARK: - L3 village randomiser

    /// L3: moves the torch, the map and the two booby traps to other search spots of the huts. Only entries that
    /// can match a player position are used (the two dead entries #8/#14 stay); lo/hi (the spots) stay, the
    /// {msg, msg_after} pairs are swapped. Host PRNG (S0SplitMix64): the game's k_random() sequence is untouched.
    func s0RandomiseVillage(_ seed: Int) {
        let base = Platoon.s0VillageItems
        func pairAddr(_ i: Int) -> UInt32 { base &+ UInt32(4 * i + 2) }
        // spots a player can trigger: some odd d0 (pworld is even, d0 = pworld - $18f) with lo <= d0 <= hi, d0 != $ff
        let usable = (0..<20).filter { i in
            let lo = Int(mem.r8(base &+ UInt32(4 * i))), hi = Int(mem.r8(base &+ UInt32(4 * i + 1)))
            return lo <= hi && (lo...hi).contains { $0 & 1 == 1 && $0 != 0xff }
        }
        let special: Set<UInt8> = [0x10, 0x0f, 0x17]         // torch, booby trap, map
        let specials = usable.filter { special.contains(mem.r8(pairAddr($0))) }
        var pairs: [Int: UInt16] = [:]
        for i in usable { pairs[i] = mem.r16(pairAddr(i)) }
        var rng = S0SplitMix64(UInt64(truncatingIfNeeded: seed))
        func shuffled(_ a: [Int]) -> [Int] {
            var a = a
            if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, Int(rng.next() % UInt64(i + 1))) } }
            return a
        }
        let targets = Array(shuffled(usable).prefix(specials.count))
        let items = shuffled(specials)                        // which special item goes to which target
        var out = pairs
        for (t, s) in zip(targets, items) { out[t] = pairs[s] }
        // the flavour entries displaced from the targets move into the special spots that were vacated
        let vacated = specials.filter { !targets.contains($0) }
        let displaced = targets.filter { !specials.contains($0) }
        for (v, d) in zip(vacated, displaced) { out[v] = pairs[d] }
        for (i, v) in out { mem.w16(pairAddr(i), v) }
        log("section 0: village randomised (seed \(seed))")
    }

    // MARK: - L4 widescreen latch

    /// After k_swap in a section-0 render loop: remember the scroll state of the buffer just finished (host-only).
    @inline(__always) func s0WideLatch() {
        guard JungleWideLatch.anyActive, let l = JungleWideLatch.existing(m) else { return }
        l.record(JungleWideLatch.State(frame: m.frameCount, level: Int(v0.level), T: Int(Int16(bitPattern: v0.T)),
                                       c34: Int(Int16(bitPattern: v0.c34)), hscroll: Int(v0.hscroll & 0xf),
                                       palette: mem.r32(a6 + 0x5a), valid: true))
    }

    /// A section-0 transition (dissolve, man select, restart) starts: the side columns must not show stale scenery.
    @inline(__always) func s0WideInvalidate() {
        guard JungleWideLatch.anyActive, let l = JungleWideLatch.existing(m) else { return }
        l.record(JungleWideLatch.State(frame: m.frameCount, level: 0, T: 0, c34: 0, hscroll: 0, palette: 0, valid: false))
    }
}

/// S0SplitMix64 (host-side seeded PRNG for the randomiser).
struct S0SplitMix64 {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9e37_79b9_7f4a_7c15
        var z = s
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
