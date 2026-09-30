// Section 0 rendering: tile background ($18cf4), bob renderer ($1920a) with the foreground-priority
// mask, animation frames, attribute window / collision, screen copies and the dissolve transition.
// All blits write the same custom registers in the same order as the original (BLTSIZE last); the
// virtual blitter performs them immediately, so the `btst #14,$dff002` waits are dropped.
// Spec: re/jungle/NOTES.md §f, §b.9, §b.11.

extension Platoon {
    static let s0BobBuf: UInt32 = 0x604a4      // bob work buffer (mask + 4 planes, rows of W+1 words)
    static let s0BgMask: UInt32 = 0x60864      // background-priority mask buffer
    static let s0AttrWin: UInt32 = 0x600b4     // attribute window 18 rows x $38 bytes

    // MARK: attribute map / collision

    /// $18c86 build_attr_map: 7 tile columns x 3 rows from map[level] + T.
    func s0BuildAttrMap() {
        let a1 = s0AddW(s0MapLevel(v0.level), v0.T)
        s0AttrCopyCols(dest: Platoon.s0AttrWin, map: a1, colsRows: 0x0007_0003)
    }

    /// $18caa attr_copy_cols: a0 dest, a1 map, d0 = cols<<16 | rows. Copies each tile's 6x8 attribute
    /// bytes into the window (dest stride $38); per row dest += $150, map += $5a.
    func s0AttrCopyCols(dest a0in: UInt32, map a1in: UInt32, colsRows d0in: UInt32) {
        let d0 = d0in &- 0x0001_0001
        var a0 = a0in, a1 = a1in
        var rows = UInt16(truncatingIfNeeded: d0)
        let cols = UInt16(d0 >> 16)
        while true {
            let rowA0 = a0, rowA1 = a1
            var c = cols
            while true {
                let colA0 = a0
                cpu(Platoon.s0CyclesAttrTile)
                let tile = UInt16(mem.r8(a1)); a1 &+= 1
                var a2 = s0TableLong(0x5fcb4, tile)
                for _ in 0...5 {
                    mem.w32(a0, mem.r32(a2)); a0 &+= 4; a2 &+= 4
                    mem.w32(a0, mem.r32(a2)); a0 &+= 4; a2 &+= 4
                    a0 = s0AddW(a0, 0x30)
                }
                a0 = colA0 &+ 8
                if c == 0 { break }
                c &-= 1
            }
            a0 = s0AddW(rowA0, 0x150)
            a1 = s0AddW(rowA1, 0x5a)
            if rows == 0 { break }
            rows &-= 1
        }
    }

    /// $19ed2 solid_at: attribute cell at ($60c94,$60c96) is solid ($b0, $da, $c0..$d0). No bounds checks.
    func s0SolidAt() -> Bool {
        cpu(Platoon.s0CyclesSolidAt)
        let row = UInt32(v0.probeY >> 3) * 0x38 &+ Platoon.s0AttrWin
        let d0 = (v0.probeX >> 3) &+ 8 &+ v0.c34
        let cell = mem.r8(s0AddW(row, d0))
        if cell == 0xb0 || cell == 0xda { return true }
        return cell >= 0xc0 && cell < 0xd1
    }

    // MARK: background

    /// $18cf4 draw_tiles: clear the back buffer playfield and blit 3 rows of 64x48 tiles, with partial
    /// edge tiles for the coarse scroll $60c34. Returns the final a1 (= back buffer + $1680), which the
    /// dissolve uses as its source pointer when it follows (d4 = $780 then).
    @discardableResult
    func s0DrawTiles() -> UInt32 {
        cpu(Platoon.s0CyclesClearPlayfield + Platoon.s0CyclesDrawTiles)
        var a0 = v0.backBuf
        for _ in 0...0x59f {
            mem.w32(a0 &+ 0x2000, 0); mem.w32(a0 &+ 0x4000, 0); mem.w32(a0 &+ 0x6000, 0); mem.w32(a0, 0)
            a0 &+= 4
        }
        let savedC34 = v0.c34
        v0.c34 &= 0xfffe
        let c34 = v0.c34
        let d5 = UInt16(bitPattern: Int16(bitPattern: c34) >> 1)     // asr.w #1
        let d5neg = Int16(bitPattern: d5) < 0
        var d0: UInt32 = 0x0005_0003
        a0 = s0AddW(s0MapLevel(v0.level), v0.T)
        if !d5neg { a0 &+= 1 }
        var a1 = v0.backBuf
        let d1: UInt16 = 0x55
        let d4: UInt16 = 0x780
        d0 &-= 0x0001_0001
        chip.write(0x064, 0)
        chip.write(0x066, 0x20)
        chip.write(0x040, 0x09f0)
        chip.write(0x042, 0)
        var d3: UInt16 = 0x0c04
        var rows = UInt16(truncatingIfNeeded: d0)
        while true {
            let rowA1 = a1
            var cols = UInt16(d0 >> 16)
            if d5 != 0 {
                // first, partial tile
                cols &-= 1
                let t = UInt16(mem.r8(a0)); a0 &+= 1
                var a2 = s0TableLong(0x5f8b4, t)
                var d7: UInt16, d6: UInt16, next: UInt32
                if !d5neg {
                    d7 = 8 &- c34
                    next = UInt32(bitPattern: Int32(Int16(bitPattern: d7))) &+ a1
                    d7 = c34
                    a2 = s0AddW(a2, d7)
                    d3 = 0x0c04 &- d5
                    d6 = 0x20 &+ d7
                } else {
                    d7 = 0 &- c34
                    next = UInt32(bitPattern: Int32(Int16(bitPattern: d7))) &+ a1
                    d7 = 8 &+ c34                           // moveq #8 (long) + add.w: small positive
                    a2 &+= UInt32(d7)
                    d3 = (0 &- d5) &+ 0x0c00
                    d6 = 0x28 &+ c34
                }
                chip.write(0x064, d7)
                chip.write(0x066, d6)
                chip.writeL(0x050, a2)
                chip.writeL(0x054, a1)
                chip.write(0x058, d3)
                for _ in 0..<3 {
                    a1 &+= 0x2000
                    chip.writeL(0x054, a1)
                    chip.write(0x058, d3)
                }
                d3 = 0x0c04
                a1 = next
            }
            // full tiles
            while true {
                let t = UInt16(mem.r8(a0)); a0 &+= 1
                let a2 = s0TableLong(0x5f8b4, t)
                chip.write(0x064, 0)
                chip.write(0x066, 0x20)
                chip.writeL(0x050, a2)
                chip.writeL(0x054, a1)
                chip.write(0x058, d3)
                for _ in 0..<3 {
                    a1 &+= 0x2000
                    chip.writeL(0x054, a1)
                    chip.write(0x058, d3)
                }
                a1 = a1 &- 0x5ff8                            // lea -$5ff8(a1): plane 0, next tile column
                if cols == 0 { break }
                cols &-= 1
            }
            if d5 != 0 {
                // last, partial tile (the map byte is not consumed)
                let t = UInt16(mem.r8(a0))
                let a2 = s0TableLong(0x5f8b4, t)
                var d7: UInt16, d6: UInt16
                var skip = false
                if !d5neg {
                    d7 = 8 &- c34
                    d3 = d5 &+ 0x0c00
                    d6 = 0x28 &- c34
                } else {
                    d7 = 0 &- c34
                    d3 = (4 &+ d5) &+ 0x0c00
                    d6 = 8 &+ c34
                    if d6 == 0 { skip = true }
                    d6 = (0 &- d6) &+ 0x28
                }
                if !skip {
                    chip.write(0x064, d7)
                    chip.write(0x066, d6)
                    chip.writeL(0x050, a2)
                    chip.writeL(0x054, a1)
                    chip.write(0x058, d3)
                    for _ in 0..<3 {
                        a1 &+= 0x2000
                        chip.writeL(0x054, a1)
                        chip.write(0x058, d3)
                    }
                }
            }
            a1 = s0AddW(rowA1, d4)
            a0 = s0AddW(a0, d1)
            if rows == 0 { break }
            rows &-= 1
        }
        v0.c34 = savedC34
        return a1
    }

    // MARK: objects

    /// $19102 draw_enemy: hut-1 trap-door prop, or the enemy (scrolls with the world; contact kill).
    func s0DrawEnemy() {
        if (v0.pstate == 5 || v0.pstate == 6) && v0.hut == 1 {
            v0.hutPropX = v0.hutPropX &+ v0.dx
            v0.flip = 0
            s0DrawBob(mem.r32(0x60c72), 0x3b)
            return
        }
        // de_normal
        if v0.eframe == 0 { return }
        v0.flip = v0.efacing
        v0.ex = v0.ex &+ v0.dx
        if v0.pstate == 0 && v0.evillager == 0 && (v0.estate == 2 || v0.estate == 5)
            && v0.ex >= 0x80 && v0.ex < 0xa8
            && !enhancements.cheats.invincible {   // ENHANCEMENT CHEAT-INV (default off)
            s0PlayerHit()                          // bodily contact kills
        }
        s0DrawFrame(mem.r32(0x5f88a), v0.eframe)
    }

    /// $191be draw_player.
    func s0DrawPlayer() {
        v0.flip = v0.pfacing
        s0DrawFrame(mem.r32(0x5f880), v0.pframe)
    }

    /// $191d4 draw_frame: d0 = x<<16|y, d1 = frame (+$40 when $60c36 set); draws its $ff-terminated bob list.
    func s0DrawFrame(_ d0: UInt32, _ frame: UInt16) {
        cpu(Platoon.s0CyclesDrawFrame)
        var d1 = frame
        if v0.flip != 0 { d1 = d1 &+ 0x40 }
        var a4 = s0TableLong(0x1a1c6, d1)
        while true {
            let b = UInt16(mem.r8(a4)); a4 &+= 1
            if b == 0xff { return }
            s0DrawBob(d0, b)
        }
    }

    /// $1920a draw_bob: d0 = x<<16|y (object position), d1 = bob number. Cookie-cut blit into the back
    /// buffer; pixels below the priority line $60cba are only drawn over background colours 0/1.
    func s0DrawBob(_ pos: UInt32, _ bob: UInt16) {
        var d1 = bob &<< 2
        var d0 = pos &+ s0TableLong(0x1a536, bob)          // add.l bob offset (x.w, y.w)
        var d6 = UInt16(truncatingIfNeeded: d0)             // ytop
        let xs = UInt16(d0 >> 16) &- v0.hscroll
        d0 = UInt32(xs) << 16 | (d0 & 0xffff)
        if d0 >= 0x0140_0000 { return }                     // x' outside 0..319 (unsigned)
        cpu(Platoon.s0CyclesBobDrawn)
        let savedD0 = d0
        // 1: clear the bob work buffer (160 rows x 6 words)
        chip.write(0x040, 0x0100)
        chip.write(0x042, 0)
        chip.write(0x064, 0)
        chip.write(0x062, 0)
        chip.write(0x060, 0)
        chip.write(0x066, 0)
        chip.writeL(0x050, 0)
        chip.writeL(0x04c, 0)
        chip.writeL(0x048, 0)
        chip.writeL(0x054, Platoon.s0BobBuf)
        chip.write(0x058, 0x2806)
        // 2: copy mask + 4 planes (5H rows x W words) into rows of W+1 words
        d1 = d1 &<< 1
        var a1 = mem.r32(0x55000 &+ UInt32(bitPattern: Int32(Int16(bitPattern: d1)))) &+ 0x55400
        var hdr = mem.r32(a1); a1 &+= 4
        hdr = hdr &+ 0x0001_0001                            // W<<16 | H
        let h = UInt16(truncatingIfNeeded: hdr)
        let d5 = h
        var size = (h &+ h &+ h &+ h &+ h) &<< 6            // 5H rows
        size |= UInt16(hdr >> 16) & 0x3f
        chip.write(0x066, 2)
        chip.write(0x040, 0x09f0)
        chip.writeL(0x050, a1)
        chip.writeL(0x054, Platoon.s0BobBuf)
        chip.write(0x058, size)
        d0 = savedD0
        // screen address
        let y4 = Int16(bitPattern: UInt16(truncatingIfNeeded: d0) &<< 2)
        var a0 = mem.r32(0x60cc2 &+ UInt32(bitPattern: Int32(y4))) &+ v0.backBuf
        let x = UInt16(d0 >> 16)
        var d7 = (x & 0xf) &<< 12
        a0 = s0AddW(a0, (x >> 3) & 0xfe)
        var d1l = mem.r32(a1 &- 4) &+ 0x0002_0001          // (W+1)<<16 | H
        let hh = UInt16(truncatingIfNeeded: d1l)
        var bsize = UInt16(truncatingIfNeeded: UInt32(hh) << 6)
        d1l = (d1l >> 16) | (d1l << 16)                     // swap
        let w1 = UInt16(truncatingIfNeeded: d1l)            // W+1
        var d2 = UInt16(truncatingIfNeeded: UInt32(hh) * UInt32(w1))   // mulu.w (low word used)
        d2 = d2 &+ d2                                       // bytes per plane in the work buffer
        let w1m = w1 & 0x3f
        bsize |= w1m
        let d3 = (0 &- (w1m &+ w1m)) &+ 0x28                // screen modulo 40 - 2(W+1)
        let scr = a0
        // 3-5: background mask = plane1 | plane2 | plane3 under the bob
        let a1b = Platoon.s0BgMask
        a0 &+= 0x2000
        chip.write(0x064, d3)
        chip.write(0x066, 0)
        chip.write(0x060, 0)
        chip.write(0x040, 0x09f0)
        chip.writeL(0x050, a0)
        chip.writeL(0x054, a1b)
        chip.write(0x058, bsize)
        a0 &+= 0x2000
        chip.write(0x040, 0x0bfa)
        chip.writeL(0x050, a0)
        chip.writeL(0x048, a1b)
        chip.writeL(0x054, a1b)
        chip.write(0x058, bsize)
        a0 &+= 0x2000
        chip.writeL(0x050, a0)
        chip.writeL(0x048, a1b)
        chip.writeL(0x054, a1b)
        chip.write(0x058, bsize)
        // 6: priority vs line $60cba
        var am = Platoon.s0BgMask            // a0
        var ab = Platoon.s0BobBuf            // a1
        let prio = v0.prioLine
        var con: UInt16
        var lower = false
        var sz = bsize
        if d6 >= prio {
            lower = true                     // whole bob at/below the line
        } else {
            d6 = d6 &+ d5                    // ytop + H
            if d6 == prio || d6 < prio {
                con = d7 | 0x0fca            // entirely above: cookie with A shift
                s0DrawBobCookie(con: con, shift: d7, size: bsize, screen: scr, planeBytes: d2, mod: d3)
                return
            }
            // straddling: rows above the line get the plain (pre-shifted) mask
            cpu(Platoon.s0CyclesBobStraddle)
            let top = d6 &- d5
            var s = bsize & 0x3f
            let above = (0 &- (top &- prio)) &<< 6
            s |= above
            chip.write(0x064, 0)
            chip.write(0x066, 0)
            chip.writeL(0x050, ab)
            chip.writeL(0x054, am)
            chip.write(0x040, d7 | 0x09f0)
            chip.write(0x058, s)
            chip.write(0x040, 0x09f0)
            chip.writeL(0x050, am)
            chip.writeL(0x054, ab)
            chip.write(0x058, s)
            // rows below
            var w = bsize & 0x3f
            let rowsBelow = (d5 &+ top) &- prio
            sz = w | (rowsBelow &<< 6)
            let rowsAbove = 0 &- (top &- prio)
            w = w &<< 1
            let off = UInt16(truncatingIfNeeded: UInt32(rowsAbove) * UInt32(w))
            am = s0AddW(am, off)
            ab = s0AddW(ab, off)
            lower = true
        }
        if lower {
            // db_lower: mask = shift(mask) & ~bg
            cpu(Platoon.s0CyclesBobLower)
            d7 |= 0x0d30
            chip.write(0x064, 0)
            chip.write(0x066, 0)
            chip.write(0x062, 0)
            chip.writeL(0x050, ab)
            chip.writeL(0x04c, am)
            chip.writeL(0x054, ab)
            chip.write(0x040, d7)
            chip.write(0x058, sz)
            con = 0x0fca
            s0DrawBobCookie(con: con, shift: d7, size: bsize, screen: scr, planeBytes: d2, mod: d3)
        }
    }

    /// $19462 db_cookie: D = A&B | ~A&C for the 4 planes (A = mask, B = colour planes, C = D = screen).
    private func s0DrawBobCookie(con d6: UInt16, shift d7in: UInt16, size d0: UInt16, screen a0in: UInt32,
                                 planeBytes d2: UInt16, mod d3: UInt16) {
        let d7 = d7in & 0xf000
        let a1 = Platoon.s0BobBuf
        // add.w d2,d1: word add to the low word of a1's value
        let d1 = (a1 & 0xffff_0000) | UInt32(UInt16(truncatingIfNeeded: a1) &+ d2)
        var a0 = a0in
        chip.write(0x060, d3)
        chip.write(0x066, d3)
        chip.write(0x064, 0)
        chip.write(0x040, d6)
        chip.write(0x042, d7)
        chip.writeL(0x050, a1)
        chip.writeL(0x04c, d1)
        chip.writeL(0x048, a0)
        chip.writeL(0x054, a0)
        chip.write(0x058, d0)
        for _ in 0..<3 {
            a0 &+= 0x2000
            chip.writeL(0x050, a1)
            chip.writeL(0x048, a0)
            chip.writeL(0x054, a0)
            chip.write(0x058, d0)
        }
    }

    // MARK: screen copies

    /// $194fa clear_buf_78000: clear the playfield part (4 x $1680 bytes) of buffer $78000.
    /// The buffer may be on display (choose-your-man screen), so the CPU clear is paced: 16 chunks, each
    /// cleared at the beam time the 68000 loop reaches it (the display is rendered line by line).
    func s0ClearBuf78000() {
        var a0: UInt32 = 0x78000
        for _ in 0..<16 {
            s0Settle()
            for _ in 0..<90 {                // 16 x 90 = $5a0 longs per plane
                mem.w32(a0 &+ 0x2000, 0); mem.w32(a0 &+ 0x4000, 0); mem.w32(a0 &+ 0x6000, 0); mem.w32(a0, 0)
                a0 &+= 4
            }
            cpu(Platoon.s0CyclesClearPlayfield / 16)
        }
    }

    /// $1988a copy_backbuf_to_68000: 4 blits back buffer -> $68000 (200 rows x 20 words per plane).
    func s0CopyBackbufTo68000() {
        var a1 = v0.backBuf
        let d0: UInt16 = 0x3214
        chip.write(0x064, 0)
        chip.write(0x066, 0)
        chip.write(0x040, 0x09f0)
        chip.write(0x042, 0)
        chip.writeL(0x050, a1)
        chip.writeL(0x054, 0x68000)
        chip.write(0x058, d0)
        a1 &+= 0x2000
        chip.write(0x042, 0)
        chip.writeL(0x050, a1)
        chip.writeL(0x054, 0x6a000)
        chip.write(0x058, d0)
        a1 &+= 0x2000
        chip.writeL(0x050, a1)
        chip.writeL(0x054, 0x6c000)
        chip.write(0x058, d0)
        a1 &+= 0x2000
        chip.writeL(0x050, a1)
        chip.writeL(0x054, 0x6e000)
        chip.write(0x058, d0)
    }

    /// $188d6 (labelled save_backbuf_to_68000): the reverse copy, $68000 -> back buffer.
    func s0Restore68000ToBackbuf() {
        var a1 = v0.backBuf
        let d0: UInt32 = 0x3214
        chip.write(0x064, 0)
        chip.write(0x066, 0)
        chip.write(0x040, 0x09f0)
        chip.write(0x042, 0)
        for p in 0..<4 {
            chip.writeL(0x050, 0x68000 &+ UInt32(p) * 0x2000)
            chip.writeL(0x054, a1)
            chip.write(0x058, UInt16(d0))
            a1 &+= 0x2000
        }
    }

    // MARK: dissolve

    /// $19926 dissolve_in: masks from the all-zero group upwards.
    func s0DissolveIn(a1: UInt32, d4: UInt16) {
        s0Dbg("019926")
        s0Dissolve(masks: 0x1a138, step: 0xffff_ffe0, a1: a1, d4: d4)
    }

    /// $19936 dissolve_out: save the back buffer to $68000, masks from 7 bits set downwards.
    /// `a1`/`d4` are the caller's register values (the dissolve's "random" source; see s0Dissolve).
    func s0DissolveOut(a1: UInt32, d4: UInt16) {
        s0Dbg("019936")
        s0WideInvalidate()                                // L4 host latch (no-op unless a host attached one)
        s0CopyBackbufTo68000()
        s0Dissolve(masks: 0x1a058, step: 0x20, a1: a1, d4: d4)
    }

    /// $19946 dissolve: 8 steps; each rebuilds the back buffer from $68000 with a per-byte mask picked by
    /// a running sum of the words at a1 (the original just reads whatever memory a1 points at, wrapping
    /// inside the low 64K). The entry a1/d4 are the caller's registers: the call sites pass the values
    /// observed in the emulator. Each step is shown with a swap (7 frames per step like the A500).
    func s0Dissolve(masks a5in: UInt32, step d3: UInt32, a1 a1in: UInt32, d4 d4in: UInt16) {
        var a5 = a5in
        var a1 = a1in & 0xffff_fffe
        var d4 = d4in
        for _ in 0...7 {
            var a0 = v0.backBuf
            var a2: UInt32 = 0x68000
            for _ in 0...0x2cf {
                for _ in 0..<8 {
                    d4 = d4 &+ mem.r16(a1); a1 &+= 2
                    let mask = mem.r8(a5 &+ UInt32(d4 & 0x1c) &+ 3)   // low byte of the long
                    mem.w8(a0 &+ 0x2000, mem.r8(a2 &+ 0x2000) & mask)
                    mem.w8(a0 &+ 0x4000, mem.r8(a2 &+ 0x4000) & mask)
                    mem.w8(a0 &+ 0x6000, mem.r8(a2 &+ 0x6000) & mask)
                    mem.w8(a0, mem.r8(a2) & mask)
                    a0 &+= 1; a2 &+= 1
                }
                a1 &= 0xffff
            }
            cpu(Platoon.s0CyclesDissolveStep)
            s0Settle()
            s0Dbg("019af8")
            k_swap()
            s0ReadInput()
            k_wait_swap()
            a5 = a5 &+ d3
        }
        s0Restore68000ToBackbuf()
    }
}
