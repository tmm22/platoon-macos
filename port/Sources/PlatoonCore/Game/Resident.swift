// Boot chain and resident code ($400-$2534). Spec: re/kernel/NOTES.md §(e) "Boot chain", §Resident, §(g).
// Listing: re/kernel/kernel.s (part1 = resident, part2 = relocator, part4 = boot loader at $76000).
//
// Not translated: the debug monitor ("CBM Amiga Monitor V2.0") and the exception handlers that enter it
// (they only run on CPU exceptions); the port installs fatalError handlers instead.

/// Resident RAM addresses.
enum RA {
    static let fontPtr: UInt32 = 0x418       // l
    static let curCol: UInt32 = 0x41c        // w
    static let curRow: UInt32 = 0x41e        // w
    static let savedSP: UInt32 = 0xd16       // l  (disk save stub)
    static let monDrive: UInt32 = 0x922      // w
    static let monTrap14: UInt32 = 0x10a4    // w
    static let goAddr: UInt32 = 0x10d6       // l  = $f800
    static let serialFlag: UInt32 = 0x1188   // b
    static let keymapNormal: UInt32 = 0x179a // 128 b, shifted map at +$80
    static let monFont: UInt32 = 0x2094      // 96 chars 8x8 1bpp
    static let colourBits: UInt32 = 0x2394   // 16 x 4 b
    static let monActive: UInt32 = 0x23e2    // w
    static let keyBuf: UInt32 = 0x23e4       // count + 16 ascii
    static let textColour: UInt32 = 0x2404   // [plane*4 + slot]
    static let rowTab: UInt32 = 0x2434       // 25 l
    static let keyMatrix: UInt32 = 0x2498    // 16 b
    static let shiftKeys: UInt32 = 0x24a4    // matrix byte of codes $60-$67
    static let joy: UInt32 = 0x24a8          // w
    static let savedPC: UInt32 = 0x24fc      // l
    static let bootDrive: UInt32 = 0x766f2   // w (boot loader)
    static let bootPalette: UInt32 = 0x766d2
    static let bootCopper: UInt32 = 0x766ae
}

extension Platoon {
    // MARK: - boot ($76000 boot loader)

    /// Power-on: Kickstart state + the cracked bootblock (HLE, like tools/amiga/emu), then the boot loader.
    func boot() {
        k_registerDispatch()
        // Kickstart leaves CIA-A DDRA = $03 (LED/OVL outputs) and CIA-B port B (drive control) all outputs, high.
        chip.ciaA.write(2, 0x03); chip.ciaB.write(3, 0xff); chip.ciaB.write(1, 0xff)
        // Bootblock (crack): loads $2c00 bytes from ADF offset $70c00 to $76000 and jumps to $7613a.
        mem.load(disk.bytes(at: 0x70c00, count: 0x2c00), at: 0x76000)
        boot_entry()
    }

    /// $7613a boot_entry: privilege-violation vector := $76148, SR = $2700; falls into boot_main.
    func boot_entry() {
        mem.w32(0x20, UInt32(0x76148))
        chip.ipl = 7
        boot_main()
    }

    /// $76148 boot_main: display init, drive select, load + show the Ocean loading picture, load the main
    /// program (tracks 1-17) to $400 and jump to it.
    func boot_main() {
        tickPoint(0x76148)
        cpu(24)
        boot_display_init()
        mem.w16(RA.bootDrive, 1); boot_drive_select()
        mem.w16(RA.bootDrive, 0); boot_drive_select()
        boot_load(track: 0x12, count: 3, dest: 0x70000)
        boot_decode_picture()
        for i in 0..<32 {                                   // 32 words (only 16 are colours): move.w (a0)+,(a1)+ ; dbra
            cpu(22); settleCPU()
            chip.write(0x180 + 2 * i, mem.r16(RA.bootPalette &+ UInt32(2 * i)))
        }
        tickPoint(0x76198)
        boot_load(track: 1, count: 0x11, dest: 0x400)
        // jmp $400: the image starts with bra $253c (reloc_stub)
        reloc_stub()
    }

    /// $761c6 boot_load: boot_diskload; on error (never with the crack's loader) it would jmp $f80000.
    func boot_load(track: UInt32, count: UInt32, dest: UInt32) {
        let d0 = diskLoad(track: track, count: count, dest: dest)
        if Int16(bitPattern: UInt16(truncatingIfNeeded: d0)) < 0 { fatalError("boot: disk load failed (jmp $f80000)") }
    }

    /// $761dc boot_decode_picture: ByteRun1 from $70022 into 4 bitplanes at $78000, rows interleaved
    /// (row y plane p -> $78000 + p*$2000 + y*40); stops after 200 rows (the original pops the return address
    /// of boot_putbyte). The 34-byte header (IFF-like, palette unused) is skipped.
    func boot_decode_picture() {
        tickPoint(0x761dc)
        var a1: UInt32 = 0x78000, a2: UInt32 = 0x78000
        var d5: UInt32 = 0, d6: UInt8 = 0, d7: UInt8 = 0
        var a0: UInt32 = 0x70022
        var cycles = 0                                     // 68000 cycles of the original loop (Musashi timing)
        /// $76224 boot_putbyte; returns true when the 200th row is complete.
        func putbyte(_ d1: UInt8) -> Bool {
            mem.w8(a1, d1); a1 &+= 1
            let wasSet = d5 & 0x8000 != 0
            d5 ^= 0x8000                                   // bchg #15,d5
            if !wasSet { cycles += 18 + 46; return false }   // bsr + body up to the rts
            cycles += 18 + 70
            d5 = (d5 & 0xffffff00) | UInt32(UInt8(truncatingIfNeeded: d5) &+ 2)
            if UInt8(truncatingIfNeeded: d5) != 0x28 { return false }
            d5 &= 0xffffff00
            a2 &+= 0x2000; a1 = a2
            d6 = (d6 &+ 1) & 3
            cycles += 36
            if d6 != 0 { return false }
            a2 = a2 &- 0x7fd8; a1 = a2
            d7 &+= 1
            cycles += 28
            return d7 == 0xc8
        }
        decode: while true {
            let d0 = mem.r8(a0); a0 &+= 1
            if d0 & 0x80 == 0 {                              // literal run of d0+1 bytes
                cycles += 50
                for _ in 0...Int(d0 & 0x7f) {
                    let d1 = mem.r8(a0); a0 &+= 1
                    cycles += 18                             // move.b (a0)+,d1 ; dbra
                    if putbyte(d1) { break decode }
                }
            } else if d0 != 0x80 {                           // repeat next byte 1+(-d0 & $7f) times
                cycles += 76
                let n = Int(UInt8(truncatingIfNeeded: 0 &- d0) & 0x7f)
                let d1 = mem.r8(a0); a0 &+= 1
                for _ in 0...n { cycles += 10; if putbyte(d1) { break decode } }
            } else {
                cycles += 34                                 // $80: no-op code
            }
        }
        cpu(cycles * 10058 / 10000)                        // (calibrated: emu 6855 lines)
    }

    /// $76614 boot_display_init: interrupts/DMA off, 4 lowres planes at $78000 via the boot copper list,
    /// clear $78000-$7ffff, sprites off, colours black, keyboard off, SR = $2000.
    func boot_display_init() {
        chip.write(0x09a, 0x7fff); chip.write(0x096, 0x7fff)
        chip.write(0x100, 0x4200); chip.write(0x102, 0); chip.write(0x108, 0); chip.write(0x10a, 0)
        chip.write(0x092, 0x38); chip.write(0x094, 0xd0)
        chip.write(0x08e, 0x3c81); chip.write(0x090, 0x04c1)
        chip.writeL(0x080, RA.bootCopper)
        chip.write(0x088, 0)                                 // move.w $88(a0),d0 = COPJMP1 strobe
        mem.fill(0x78000, count: 0x8000)
        cpu(240_170)                                         // clr.l (a1)+ ; dbra (emu: 529 lines)
        for s in 0..<8 { chip.write(0x142 + 8 * s, 0) }
        for i in 0..<32 { chip.write(0x180 + 2 * i, 0) }
        boot_kbd_off()
        chip.ipl = 0; chip.checkInterrupts()
    }

    /// $765d8 boot_kbd_off.
    func boot_kbd_off() {
        chip.ciaA.write(13, 0x7f)
        chip.ciaA.write(14, chip.ciaA.read(14) & ~0x40)
        chip.write(0x09c, 0x7fff)
        _ = chip.ciaA.read(13); _ = chip.ciaA.read(12)
        chip.write(0x09e, 0x7f00); chip.write(0x09e, 0x9100)
        chip.write(0x096, 0x8380)
    }

    /// $7629c boot_drive_select (same as resident drv_select with drive word $766f2).
    func boot_drive_select() { driveSelect(drive: mem.r16(RA.bootDrive)) }

    /// $8f8 drv_select / $7629c: deselect all drives + motor bit high, then pulse SELx of `drive`.
    func driveSelect(drive: UInt16) {
        let b = chip.ciaB
        b.write(1, b.read(1) | 0x78)
        b.write(1, b.read(1) | 0x80)
        let bit = UInt8(1) << UInt8((drive &+ 3) & 7)
        b.write(1, b.read(1) & ~bit)
        b.write(1, b.read(1) | bit)
    }

    /// $253c reloc_stub: INTENA off; move $404..$2537 down to $400 ($84d longs); jmp $400 (now bra $566).
    func reloc_stub() {
        tickPoint(0x253c)
        chip.write(0x09a, 0x7fff)
        for i in 0..<0x84d { mem.w32(0x400 + UInt32(4 * i), mem.r32(0x404 + UInt32(4 * i))) }
        cpu(62_650)                                         // $84d x move.l (a0)+,(a1)+ ; dbra (emu: 138 lines)
        if enhancements.originalCredits { restoreOriginalCredits() }   // ENHANCEMENT hook (default on)
        res_init()
    }

    /// ENHANCEMENT (enhancements.originalCredits): the Darc crack replaced two lines of the credits page
    /// ($114a1: `[7,11] "GAME DESIGN (C)1988 OCEAN." [10,13] slot1=5 slot2=6 "CONVERSION BY CHOICE"`) with
    /// `"CRACKED BY HANSWURST OF 68 DARC"` + 22 spaces - the same 53 bytes. This puts the original bytes (as on
    /// re/platoon_b.adf, whose own crack line is elsewhere) back at $114e9; nothing else moves. Only done if the
    /// image holds exactly the Darc text.
    func restoreOriginalCredits() {
        let at: UInt32 = 0x114e9
        let crack = Array("CRACKED BY HANSWURST OF 68 DARC".utf8) + [UInt8](repeating: 0x20, count: 22)
        guard mem.slice(at, crack.count) == crack else { return }
        let original = Array("GAME DESIGN (C)1988 OCEAN.".utf8) + [0x00, 0x0a, 0x0d, 0x02, 0x05, 0x03, 0x06]
            + Array("CONVERSION BY CHOICE".utf8)
        mem.load(original, at: at)
    }

    // MARK: - resident init

    /// $566 res_init: INTENA off, vector $20 := $582, SR $2700; falls into res_restart.
    func res_init() {
        tickPoint(0x566)
        chip.write(0x09a, 0x7fff)
        mem.w32(0x20, UInt32(0x582))
        chip.ipl = 7
        res_restart()
    }

    /// $582 res_restart: SP = $400, row table $2434, exception vectors, drive select, then mon_restart.
    func res_restart() {
        var d0: UInt32 = 0
        for i in 0..<25 { mem.w32(RA.rowTab + UInt32(4 * i), d0); d0 &+= 0x140 }
        chip.ipl = 7
        // exception vectors -> debug monitor entry points (not translated: fatalError handlers below)
        let vectors: [(UInt32, UInt32)] = [(0x08, 0x1af0), (0x0c, 0x1b40), (0x10, 0x1b68), (0x14, 0x1b9a), (0x18, 0x1baa),
                                           (0x1c, 0x1bba), (0x20, 0x1bca), (0x2c, 0x1bda), (0x3c, 0x1bea), (0x60, 0x1bfa),
                                           (0x64, 0x1bea), (0x6c, 0x1bea), (0x70, 0x1bea), (0x74, 0x1bea), (0x78, 0x1bea),
                                           (0x7c, 0x1bea)]
        for (v, a) in vectors { mem.w32(v, a) }
        for t in 0..<16 { mem.w32(0x80 + UInt32(4 * t), t == 14 ? 0x1c1a : 0x1c0a) }
        for lvl in [1, 3, 4, 5, 6, 7] {
            chip.interruptHandlers[lvl] = { fatalError("Uninitialised interrupt (level \(lvl)) - debug monitor not translated") }
        }
        mem.w16(RA.monDrive, 0); driveSelect(drive: mem.r16(RA.monDrive))
        mem.w16(RA.monDrive, 0); driveSelect(drive: mem.r16(RA.monDrive))
        mem.w16(RA.monTrap14, 0)
        cpu(120 * 20)
        mon_restart()
    }

    /// $6c6 mon_restart: SP = $400, keyboard init, then jmp ($10d6) = $f800 (kernel k_init).
    func mon_restart() {
        kbd_init()
        mon_jump_goaddr()
    }

    /// $10b8 mon_jump_goaddr: jmp ($10d6).
    func mon_jump_goaddr() -> Never {
        call(mem.r32(RA.goAddr))
        fatalError("go address returned")
    }

    /// $13b0 kbd_init: level-2 vector := $169c, CIA-A serial-port interrupt, INTENA $c008, ADKCON, DMACON $8380.
    func kbd_init() {
        mem.w32(0x68, UInt32(0x169c))
        chip.interruptHandlers[2] = { [unowned self] in self.level2_handler() }
        chip.ciaA.write(13, 0x7f)
        chip.ciaA.write(13, 0x88)
        chip.ciaA.write(14, chip.ciaA.read(14) & ~0x40)
        chip.write(0x09c, 0x7fff)
        chip.write(0x09a, 0xc008)
        _ = chip.ciaA.read(13); _ = chip.ciaA.read(12)
        chip.write(0x09e, 0x7f00); chip.write(0x09e, 0x9100)
        chip.write(0x096, 0x8380)
    }

    // MARK: - level 2 (keyboard)

    /// $169c level2_handler: CIA-A SP -> key matrix / ASCII buffer; FLG -> serial flag; DEL -> warm restart.
    func level2_handler() {
        irqDepth += 1; defer { irqDepth -= 1 }
        irqCharge(200)
        chip.write(0x09c, 0x0008)
        let icr = chip.ciaA.read(13)
        if icr & 0x08 != 0 { l2_key(); return }
        if icr & 0x10 != 0 { mem.w8(RA.serialFlag, 0xff) }
    }

    /// $16c6 l2_key.
    func l2_key() {
        let sdr = chip.ciaA.read(12)
        chip.ciaA.write(14, chip.ciaA.read(14) | 0x40)          // handshake (SP output)
        var d0 = ~((sdr >> 1) | (sdr << 7))                    // ror.b #1 ; not.b
        let released = d0 & 0x80 != 0
        d0 &= 0x7f
        let byteAddr = RA.keyMatrix + UInt32(d0 >> 3), bit = UInt8(1) << (d0 & 7)
        if released {
            mem.w8(byteAddr, mem.r8(byteAddr) & ~bit)
        } else {
            // $1744 l2_keydown
            var map = RA.keymapNormal
            if mem.r8(RA.shiftKeys) & 0x03 != 0 { map &+= 0x80 }   // LSHIFT/RSHIFT held
            let ch = mem.r8(map + UInt32(d0))
            if ch != 0 {
                if ch == 0x7f { l2_del_break(); return }
                let n = mem.r8(RA.keyBuf)
                if n < 0x10 { mem.w8(RA.keyBuf + 1 + UInt32(n), ch); mem.w8(RA.keyBuf, n &+ 1) }
            }
            mem.w8(byteAddr, mem.r8(byteAddr) | bit)
        }
        chip.ciaA.write(14, chip.ciaA.read(14) & ~0x40)
    }

    /// $1706 l2_del_break: DEL pressed -> save registers and jmp ($10d6) = $f800 (warm restart to the title).
    /// The original leaves the interrupt without RTE; here the jump is performed on the game thread when it
    /// next resumes (m.requestJump), which starts k_init on a fresh stack.
    func l2_del_break() {
        chip.ciaA.write(14, chip.ciaA.read(14) & ~0x40)
        driveSelect(drive: mem.r16(RA.monDrive))
        let target = mem.r32(RA.goAddr)
        m.requestJump { [unowned self] in self.call(target) }
    }

    // MARK: - input API ($40c, $410, $42e)

    /// $1c30 res_joystick_impl: JOY1DAT decoded to b0 down, b1 right, b2 up, b3 left; b7 fire (CIA-A PRA b7 low).
    func r_joystick_impl() -> UInt8 {
        var d0 = chip.read(0x00c) & 0x303
        var d2 = (d0 >> 1) & 0x101
        d0 ^= d2
        d2 = d0 >> 6
        d0 = (d0 & 3) | d2
        mem.w16(RA.joy, d0)
        if chip.ciaA.read(0) & 0x80 == 0 { d0 |= 0x80 }
        mem.w16(RA.joy, d0)
        return UInt8(truncatingIfNeeded: d0)
    }

    /// $1c6c res_getkey_impl: lowest raw keycode held (the original returns Z for none; code 0 looks like none).
    func r_getkey_impl() -> UInt8? {
        var d0: UInt16 = 0
        for i in 0..<16 {
            let b = mem.r8(RA.keyMatrix + UInt32(i))
            if b != 0 {
                var d1 = b
                while d1 & 1 == 0 { d1 >>= 1; d0 &+= 1 }
                return d0 == 0 ? nil : UInt8(truncatingIfNeeded: d0)
            }
            d0 &+= 8
        }
        return nil
    }

    /// $1ca6 res_keytest_impl: true (-1) if raw key `code` is held.
    func r_keytest_impl(_ code: UInt8) -> Bool {
        let byte = (code >> 3) & 0x0f, bit = code & 7
        return mem.r8(RA.keyMatrix + UInt32(byte)) & (1 << bit) != 0
    }

    // MARK: - text output ($404, $408)

    /// $1a5c res_print_impl: control-coded string: [col,row], 0 -> new [col,row], 1..4 -> colour slot, $ff end,
    /// $80-$fe -> last char (b & $7f). Returns the address after the terminator.
    func r_print_impl(_ a0in: UInt32) -> UInt32 {
        tickPoint(0x1a5c)
        if config.probe != nil { probePrint(a0in) }                      // F2 text-screen capture (read-only)
        var a0 = a0in
        cpu(40)
        newPos: while true {
            mem.w8(RA.curCol + 1, mem.r8(a0)); a0 &+= 1          // low bytes of the cursor words
            mem.w8(RA.curRow + 1, mem.r8(a0)); a0 &+= 1
            cpu(24)
            while true {
                let d0 = mem.r8(a0); a0 &+= 1
                cpu(Platoon.printLoopCycles)
                if d0 == 0 { continue newPos }
                if d0 & 0x80 != 0 {
                    if d0 != 0xff { res_putchar_impl(d0 & 0x7f) }
                    cpu(40)
                    return a0
                }
                if d0 < 5 {                                          // $1aa2 res_print_colour
                    let d1 = mem.r8(a0); a0 &+= 1
                    let slot = UInt32((d0 &- 1) & 3), n = UInt32(d1 & 0x0f)
                    for p in 0..<4 { mem.w8(RA.textColour + slot + UInt32(4 * p), mem.r8(RA.colourBits + n * 4 + UInt32(p))) }
                    cpu(Platoon.printColourCycles)
                    continue
                }
                res_putchar_impl(d0)
            }
        }
    }

    func r_putchar_impl(_ d0: UInt8) { res_putchar_impl(d0) }

    /// $1e46 res_putchar_impl: 8x8 2bpp glyph from the font at ($418) into both screen buffers ($70000 and
    /// $78000) at the cursor; pixel value v -> colour of slot v ($2404 table). Then advance the cursor.
    func res_putchar_impl(_ c: UInt8) {
        tickPoint(0x1e46)
        let col = UInt32(mem.r16(RA.curCol) & 0x3f), row = UInt32(mem.r16(RA.curRow) & 0x1f)
        if Int8(bitPattern: c) < 0x20 { res_putchar_ctrl(c); return }   // cmpi.b #$20 / blt (signed)
        settleCPU()
        // CPU time: setup, then each glyph row is written at the end of its (8-pixel) computation, so the glyph
        // appears row by row with the beam as on the A500.
        let rowCycles = 900, setupCycles = 300
        cpu(setupCycles)
        var glyph = mem.r32(RA.fontPtr) &+ UInt32(c &- 0x20) * 16
        let d2 = mem.r32(RA.rowTab + row * 4) &+ col &+ 0x70000
        var a1 = d2, a2 = d2 ^ 0x8000
        var tc = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { tc[i] = mem.r8(RA.textColour + UInt32(i)) }
        for _ in 0..<8 {
            var w = mem.r16(glyph); glyph &+= 2
            var p0: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0
            for _ in 0..<8 {
                w = (w << 2) | (w >> 14)                               // rol.w #2
                let v = Int(w & 3)
                p0 = (p0 << 1) | tc[v]; p1 = (p1 << 1) | tc[4 + v]
                p2 = (p2 << 1) | tc[8 + v]; p3 = (p3 << 1) | tc[12 + v]
            }
            cpu(rowCycles); settleCPU()
            mem.w8(a1, p0); mem.w8(a2, p0)
            mem.w8(a1 &+ 0x2000, p1); mem.w8(a2 &+ 0x2000, p1)
            mem.w8(a1 &+ 0x4000, p2); mem.w8(a2 &+ 0x4000, p2)
            mem.w8(a1 &+ 0x6000, p3); mem.w8(a2 &+ 0x6000, p3)
            a1 &+= 0x28; a2 &+= 0x28
        }
        cpu(Platoon.putcharCycles - setupCycles - 8 * rowCycles)       // movem back, cursor update
        mem.w16(RA.curCol, mem.r16(RA.curCol) &+ 1)
        res_putchar_advance()
    }

    /// $1fdc res_putchar_advance: wrap the cursor at column 40 / row 25.
    func res_putchar_advance() {
        if Int16(bitPattern: mem.r16(RA.curCol)) < 0x28 { return }
        mem.w16(RA.curCol, 0)
        mem.w16(RA.curRow, mem.r16(RA.curRow) &+ 1)
        if Int16(bitPattern: mem.r16(RA.curRow)) < 0x19 { return }
        mem.w16(RA.curRow, 0)
    }

    /// $200e res_putchar_ctrl: CR ($0d) -> column 0, next row; BS ($08) -> back one column (wrapping) and blank
    /// it with the monitor font; anything else only re-checks the cursor wrap.
    func res_putchar_ctrl(_ c: UInt8) {
        if c == 0x0d {
            mem.w16(RA.curCol, 0)
            mem.w16(RA.curRow, mem.r16(RA.curRow) &+ 1)
        } else if c == 0x08 {
            mem.w16(RA.curCol, mem.r16(RA.curCol) &- 1)
            if Int16(bitPattern: mem.r16(RA.curCol)) < 0 {
                mem.w16(RA.curCol, 0x27)
                mem.w16(RA.curRow, mem.r16(RA.curRow) &- 1)
                if Int16(bitPattern: mem.r16(RA.curRow)) < 0 { mem.w16(RA.curRow, 0x18) }
            }
            let col = mem.r16(RA.curCol), row = mem.r16(RA.curRow)
            mon_putchar(0x20)
            mem.w16(RA.curRow, row); mem.w16(RA.curCol, col)
        }
        res_putchar_advance()
    }

    /// $1d0a mon_putchar: monitor 1bpp 8x8 font ($2094) into plane 0 of $78000 (used by the resident BS code).
    func mon_putchar(_ c: UInt8) {
        let col = UInt32(mem.r16(RA.curCol) & 0x3f), row = UInt32(mem.r16(RA.curRow) & 0x1f)
        if Int8(bitPattern: c) < 0x20 {
            switch c {
            case 0x0d: mem.w16(RA.curCol, 0)
            case 0x0a: mem.w16(RA.curRow, mem.r16(RA.curRow) &+ 1); mem.w16(RA.curCol, 0)
            case 0x08:
                let saved = mem.r32(RA.curCol)
                mon_putchar(0x20)
                mem.w32(RA.curCol, saved)
                mem.w16(RA.curCol, mem.r16(RA.curCol) &- 1)
                if Int16(bitPattern: mem.r16(RA.curCol)) < 0 {
                    mem.w16(RA.curCol, 0x27)
                    mem.w16(RA.curRow, mem.r16(RA.curRow) &- 1)
                    if Int16(bitPattern: mem.r16(RA.curRow)) < 0 { mem.w16(RA.curRow, 0x18) }
                }
                let c2 = mem.r16(RA.curCol), r2 = mem.r16(RA.curRow)
                mon_putchar(0x20)
                mem.w16(RA.curRow, r2); mem.w16(RA.curCol, c2)
            default: break
            }
        } else {
            let src = RA.monFont &+ (UInt32(c) &- 0x20) << 3
            let dst = mem.r32(RA.rowTab + (row << 2)) &+ col &+ 0x78000
            for y in 0..<8 { mem.w8(dst &+ UInt32(y * 0x28), mem.r8(src &+ UInt32(y))) }
            mem.w16(RA.curCol, mem.r16(RA.curCol) &+ 1)
        }
        res_putchar_advance()
    }

    // MARK: - disk ($420 load, $424 save stub)

    /// $d1a disk_load (via $420): d0 = first track, d1 = count, a0 = destination; returns d0 = 0.
    /// The port reads the ADF directly; the time the original loader takes (recalibration + stepping with its
    /// $2800-iteration step delay, MFM DMA + decoding per track) is charged to the CPU-time model.
    @discardableResult
    func diskLoad(track d0: UInt32, count d1: UInt32, dest a0: UInt32) -> UInt32 {
        cpu(Platoon.diskLoadOverheadCycles)
        let n = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: d1)))
        guard n > 0 else { return 0 }                       // subq.w #1,d1 ; bmi exit
        let first = Int(UInt8(truncatingIfNeeded: d0))
        // disk_seek: recalibrate (step out to track 0), then step in first>>1 cylinders
        cpu((diskCylinder + first >> 1) * Platoon.diskStepCycles + Platoon.diskSeekCycles)
        var t = first
        for i in 0..<n {
            cpu(Platoon.diskReadRawCycles + diskDecodeCycles())
            settleCPU()
            disk.loadTracks(first: t, count: 1, to: a0 &+ UInt32(i * Disk.trackSize), memory: mem)
            t += 1
            if t & 1 == 0 { cpu(Platoon.diskStepCycles) }    // disk_step_next steps in when the new track is even
        }
        diskCylinder = t >> 1
        chip.ciaA.write(0, chip.ciaA.read(0) & ~0x02)       // bclr #1,$bfe001 (power LED)
        return 0
    }

    /// Duration of the MFM decode of one track: 11 sectors + the `cmpi.w #$4489,(a2)+` sync searches, whose
    /// length depends on where in the track the disk DMA started (the reference emulator, like a real drive,
    /// starts at a pseudo-random position: `3 + (rand() % 11) * 581` words into its 6400-word track image,
    /// sectors 544 words apart, then after the next sync word). The port replays the emulator's rand() (macOS
    /// libc: x = x * 16807 mod (2^31 - 1), seed 1) so that load times match it exactly.
    func diskDecodeCycles() -> Int {
        diskRandState = UInt32((UInt64(diskRandState) * 16807) % 0x7fffffff)
        let r = Int(diskRandState % 11)
        let n = 6400
        func word(_ i: Int) -> Int {                        // 0 = other, 1 = sync
            let q = i % n
            if q >= 544 * 11 { return 0 }
            let o = q % 544
            return (o == 2 || o == 3) ? 1 : 0
        }
        var p = 3 + r * (n / 11)
        while word(p) == 0 { p += 1 }
        p += 1                                              // the DMA buffer starts after that sync word
        var a = 0, scans = 0
        for _ in 0..<11 {
            repeat { scans += 1; a += 1 } while word(p + a - 1) == 0
            if word(p + a) == 1 { a += 1 }                  // skip the second sync word
            a += 28 + 256                                   // header/label/checksums + odd data half
        }
        return Platoon.diskDecodeCycles + scans * Platoon.diskSyncScanCycles10 / 10
    }

    /// $a9a disksave_stub ($424, crack): saves SP at $d16 and returns d0 = 0 without writing. The port persists
    /// the hiscore track here (Platoon.saveHiscores) — the only caller is k_save_hiscores (track 77).
    func res_disksave(track d0: UInt32, count d1: UInt32, src a0: UInt32) -> UInt32 {
        mem.w32(RA.savedSP, 0x3f0)
        if d0 == 0x4d && d1 == 1 && a0 == KA.hiscoreTrack { saveHiscores() }
        return 0
    }
}
