// Load section 0 "THE JUNGLE & VILLAGE SECTIONS" — code $17000-$19fc7, loaded by the kernel to $17000.
// Spec: re/jungle/NOTES.md (shared engine + jungle), re/village/NOTES.md (village, huts, trap door).
//
// This file: section entry/init ($17000-$17184), the main loop ($17186-$1734e), exit, input ($19f34),
// the player/enemy state-table dispatch and the frame pacing that reproduces the A500 game speed.
// Other routines live in Section0Player/Enemy/Objects/Render/Village/ManSelect.swift.
//
// Frame pacing (host-side, documented deviation from "no timing"): the original main loop is CPU-bound.
// Measured in tools/amiga/emu (6000 frames of random play + idle): from the return of k_wait_swap (the
// level-6 IRQ latched the previous swap at line $cc) to the k_swap call the 68000 needs 357..514 raster
// lines, i.e. the swap always lands in the next frame after line $cc, so the loop runs at exactly one tick
// per 2 frames (25 Hz). Here all logic runs instantly, and `s0Pace(from:lines:)` then waits until
// origin + 362 lines (the typical idle value) before the swap, which gives the same 2-frame period and
// samples the joystick at the same point of the frame. Same method for the trap-door prompt loop (360
// lines), each dissolve step (1912 lines = 7 frames per step) and the section init (see §timing below).

import Foundation

/// Host-side timing origin used by the section-0 pacing (not game state; see file comment).
private var s0TimingOrigin = 0

extension Platoon {
    // MARK: data addresses (section 0 data block $19fd8-$1ab49)

    static let s0PalPlayfield: UInt32 = 0x19ff8   // 16 words, colour 6 patched per level at $1a004
    static let s0PalHud: UInt32 = 0x1a018
    static let s0PalBlack: UInt32 = 0x1a038
    static let s0JumpArc: UInt32 = 0x1a194        // 16 words
    static let s0GrenadeArc: UInt32 = 0x1a1b4     // 9 words
    static let s0StartPos: UInt32 = 0x1a6da       // long T<<16 | level
    static let s0PlayerStateTable: UInt32 = 0x1aaa4
    static let s0EnemyStateTable: UInt32 = 0x1aad0
    /// BCD score constants; kernel $f80c takes the address AFTER the 4 bytes.
    static let s0Score300End: UInt32 = 0x1a6d2
    static let s0Score500End: UInt32 = 0x1a6d6
    static let s0Score10000End: UInt32 = 0x1a6da

    // MARK: timing helpers (host side)

    /// Absolute beam position in lines since power-on (game-thread view).
    var s0Now: Int { Int(m.frameCount) * Chipset.linesPerFrame + m.beamLine }

    /// Marks the current beam position as the start of a CPU-bound stretch of original code.
    func s0MarkTiming() { s0TimingOrigin = s0Now }

    /// Waits until `lines` raster lines after the last `s0MarkTiming()` (no wait if already later):
    /// reproduces the time the original 68000 code needed for the stretch (see file comment).
    func s0Pace(lines: Int) {
        let target = s0TimingOrigin + lines
        let tf = target / Chipset.linesPerFrame, tl = target % Chipset.linesPerFrame
        while Int(m.frameCount) < tf { m.waitVBlank() }
        if Int(m.frameCount) == tf && m.beamLine < tl { m.waitLine(tl) }
    }

    // MARK: small 68k helpers

    /// `move.w idx,d0; lsl.w #2,d0; movea.l (base,d0.w),a0` — long table entry with a word index.
    @inline(__always) func s0TableLong(_ base: UInt32, _ index: UInt16) -> UInt32 {
        let off = Int16(bitPattern: index &<< 2)
        return mem.r32(base &+ UInt32(bitPattern: Int32(off)))
    }
    /// `adda.w dN,aN`: sign-extended word added to an address.
    @inline(__always) func s0AddW(_ a: UInt32, _ w: UInt16) -> UInt32 { a &+ UInt32(bitPattern: Int32(Int16(bitPattern: w))) }
    /// Map row pointer of `level`: `$5f89c[level]` (longs filled at init).
    @inline(__always) func s0MapLevel(_ level: UInt16) -> UInt32 { s0TableLong(0x5f89c, level) }
    /// $1884a abs_d0 (word; $8000 stays $8000).
    @inline(__always) func s0Abs(_ d0: UInt16) -> UInt16 { Int16(bitPattern: d0) < 0 ? 0 &- d0 : d0 }
    /// Current man record (a5 = $1e(a6)): +0 grenades, +2 ammo, +4 hits.
    var s0Man: UInt32 { v0.manPtr }
    /// $19f82 sfx: jmp kernel $f86c.
    @inline(__always) func s0Sfx(_ d0: UInt16) { k_fx(d0) }

    // MARK: dispatch table (code addresses stored in RAM at $1aaa4 / $1aad0)

    func s0RegisterDispatch() {
        // player states (table $1aaa4)
        register(0x177ca) { [unowned self] in self.s0PlSt0Walk() }
        register(0x17918) { [unowned self] in self.s0PlSt1Jump() }
        register(0x17986) { [unowned self] in self.s0PlSt2Down() }
        register(0x179e6) { [unowned self] in self.s0PlSt3Up() }
        register(0x17abc) { [unowned self] in self.s0PlSt4EnterHut() }
        register(0x17bc4) { [unowned self] in self.s0PlSt5InHut() }
        register(0x17e72) { [unowned self] in self.s0PlSt6LeaveHut() }
        register(0x17ee8) { [unowned self] in self.s0PlSt7Throw() }
        register(0x17f56) { [unowned self] in self.s0PlSt8Hit() }
        register(0x18050) { [unowned self] in self.s0PlSt9Blocked() }
        register(0x18076) { [unowned self] in self.s0PlSt10Plant() }
        // enemy states (table $1aad0)
        register(0x180da) { [unowned self] in self.s0EnSt0Spawn() }
        register(0x182c0) { [unowned self] in self.s0EnSt1Drop() }
        register(0x182f2) { [unowned self] in self.s0EnSt2Walk() }
        register(0x1856e) { [unowned self] in self.s0EnSt3JumpDown() }
        register(0x1864c) { [unowned self] in self.s0EnSt4InHut() }
        register(0x18696) { [unowned self] in self.s0EnSt5Trap() }
        register(0x18706) { [unowned self] in self.s0EnSt6CrouchFire() }
        register(0x18722) { [unowned self] in self.s0EnSt7Blown() }
        register(0x187c6) { [unowned self] in self.s0EnSt8Runner() }
    }

    // MARK: entry

    /// $17000-$1706c sec0_start: section entry (the kernel's k_section_start does `jmp $17000`).
    func section0_start() -> Never {
        // lea $400,a7: the kernel enters through m.jump, i.e. with a fresh game-thread stack.
        if config.deterministicRNG { mem.w32(0x12d70, 0x31415926) }   // lockstep seed (emu: at PC $17000)
        s0RegisterDispatch()
        s0MarkTiming()
        mem.w16(mem.r32(0xf888), 0x3c81)     // DIWSTRT of the game window in the shared copper tail
        mem.w16(mem.r32(0xf88c), 0x0088)     // BPLCON1 of the HUD part
        mem.fill(0x5f880, count: 0x1762)     // clr.b (a0)+ x $1762: all section variables
        s0Pace(lines: 297)                   // the 68000 clear loop takes ~1 frame (emu: $17000 -> $17070)
        v0.scrollcnt = 8
        mem.w8(0x1b209, 0x8c)                // repair the bridge in the map (level 1 row 2 cols $47/$48)
        mem.w8(0x1b20a, 0x8d)
        v0.espeed = 6
        mem.w32(a6 + 0x34, 0x19fd8)          // message colour-fade table
        mem.w32(a6 + 0x4a, 0x1a6de)          // message text pointer table
        mem.w16(a6 + 0x24, 0)
        mem.w16(a6 + 0x26, 0)
        mem.w16(a6 + 0x2c, 0)
        mem.w16(a6 + 0x28, 0)
        mem.w16(a6 + 0x54, 0)
        while true {
            s0RestartInit()
            s0MainLoop()     // returns only when an F1-F4 cheat warp does `bra sec0_restart`
        }
    }

    /// $17070-$17184 sec0_restart: (re)start at the position long $1a6da; also the F1-F4 warp target.
    func s0RestartInit() {
        mem.w32(0x60c24, mem.r32(Platoon.s0StartPos))
        k_set_split(0x8f)
        k_set_top_pal(Platoon.s0PalPlayfield)
        k_set_hud_pal(Platoon.s0PalBlack)
        v0.manPtr = a6
        v0.manIndex = 0
        var a0 = a6
        for _ in 0...4 {                     // 5 men: grenades 9, ammo $90, hits 0
            mem.w16(a0 + 0, 9)
            mem.w16(a0 + 2, 0x90)
            mem.w16(a0 + 4, 0)
            a0 &+= 6
        }
        k_fill_longs(dest: 0x60cc2, start: 0, countMinus1: 0xc7, step: 0x28)          // y*40 row table
        k_fill_longs(dest: 0x5f89c, start: 0x1b000, countMinus1: 5, step: 0x10e)       // map level pointers
        k_fill_longs(dest: 0x5f8b4, start: 0x1c000, countMinus1: 0x97, step: 0x600)    // tile gfx pointers
        k_fill_longs(dest: 0x5fcb4, start: 0x5dc00, countMinus1: 0x97, step: 0x30)     // tile attr pointers
        k_clear_screens()
        k_swap()
        k_hud_init()
        k_fade_in(target: Platoon.s0PalHud, palVar: a6 + 0x5e, setter: .hud)
        k_set_top_pal(Platoon.s0PalPlayfield)
        s0LevelEnter()
        k_wait_swap()
        s0MarkTiming()
        let a1 = s0DrawTiles()
        s0Pace(lines: 344)                   // draw_tiles CPU clear + blits (emu: $17170 -> $17174)
        s0CopyBackbufTo68000()
        // dissolve source registers as left by draw_tiles: a1 = back buffer + $1680, d4 = $780
        s0DissolveIn(a1: a1, d4: 0x780)
        k_music(2)
    }

    // MARK: main loop

    /// $17186-$1734e main_loop: one tick per 2 frames. Returns only for a cheat warp (F1-F4).
    func s0MainLoop() {
        while true {
            tickPoint(0x17186)
            v0.tick = v0.tick &+ 1
            s0ReadInput()
            if v0.noise < 8 { v0.noise = 8 }
            v0.noise = v0.noise &- 1                 // spawn chance decays to minimum 7
            if r_keytest(0x64) && v0.estate == 0 {   // Left-Alt: voluntary change of soldier
                s0DissolveOut(a1: 0x79e0d, d4: 0xff) // a1/d4 as observed at this call site in the emulator
                s0ManSelect()
            }
            if v0.cheat != 0 {                       // ml_cheat_keys: F1-F6 only with MEGA CHEAT
                if r_keytest(0x50) { mem.w32(Platoon.s0StartPos, 0x0005_0001); return }
                if r_keytest(0x51) { mem.w32(Platoon.s0StartPos, 0x002d_0004); return }
                if r_keytest(0x52) { mem.w32(Platoon.s0StartPos, 0x0041_0001); return }
                if r_keytest(0x53) { mem.w32(Platoon.s0StartPos, 0x0041_0000); return }
                if r_keytest(0x54) { mem.w8(0x60ca0, 0xff) }   // st.b v_invincible
                if r_keytest(0x55) { v0.invincible = 0 }
            }
            // ml_frame $17266
            r_print(0x1a967)                          // text attribute reset string
            k_wait_swap()
            s0MarkTiming()
            v0.dx = 0
            call(s0TableLong(Platoon.s0PlayerStateTable, v0.pstate))
            s0PlayerFireInput()
            call(s0TableLong(Platoon.s0EnemyStateTable, v0.estate))
            // priority line: legs hidden behind foreground scenery below this y
            var d2: UInt16 = 0x60
            let lvl = v0.plevel, w = v0.pworld
            if lvl == 1 {
                if w >= 0x1d0 && w < 0x2b1 { d2 = 0x80 }         // level 1 river/bridge stretch
            } else if lvl == 0 {
                if w >= 0x181 && w < 0x2aa { d2 = 0x70 }         // level 0 village street
            }
            v0.prioLine = d2
            _ = s0DrawTiles()
            s0TrapSpawn()
            s0ExplosivesPickup()
            s0BridgeLogic()
            s0CrateOpen()
            s0TrapUpdate()
            s0BombUpdate()
            s0CrateUpdate()
            s0DrawEnemy()
            s0BulletsUpdate()
            s0ExplosionUpdate()
            s0DrawPlayer()
            s0Pace(lines: 362)                        // CPU time of the tick on the A500 (see file comment)
            k_swap()
            v0.bplcon1 = (v0.hscroll &<< 4) | v0.hscroll
            if v0.morale == 0 { s0Exit() }
            v0.morale = v0.morale &- 1
            if v0.morale == 0 { s0Exit() }
        }
    }

    /// $17350 sec0_exit: clear invincibility, game over (kernel $f864).
    func s0Exit() -> Never {
        v0.invincible = 0
        k_game_over()
    }

    /// $1735c morale_sub: morale -= d0, clamped at 0.
    func s0MoraleSub(_ d0: UInt16) {
        let m0 = v0.morale
        if d0 > m0 { v0.morale = 0 } else { v0.morale = m0 &- d0 }
    }

    // MARK: input

    /// $19f34 read_input: HUD tick, joystick -> $60cc1 (& $8f), SPACE -> bit 4, "CHEAT!" message.
    func s0ReadInput() {
        k_hud_update()
        v0.input = r_joystick() & 0x8f
        if r_keytest(0x40) { v0.input |= 0x10 }
        guard v0.cheat != 0, v0.invincible != 0, v0.msgCount == 0 else { return }
        k_queue_text(0x16)
    }
}
