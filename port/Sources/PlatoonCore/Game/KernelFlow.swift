import Foundation

// Kernel game flow: section loading (jt29), section start, game over (jt25), hiscore name entry, disk
// retry wrappers and hiscore persistence.
// Spec: re/kernel/NOTES.md §(b) "k_section_start", "k_next_section", "k_game_over", "Name entry",
// "k_load_retry"; listing re/kernel/kernel.s $fcc8-$fd4c, $fee8-$1028a, $11076-$11164.

extension Platoon {
    /// `jmp k_init` from kernel code (k_init starts with `lea $400,a7`): continue on a fresh game thread.
    func k_jump_init() -> Never {
        m.jump { [unowned self] in self.k_init_impl() }
    }

    // MARK: - section loading (jt29)

    /// $11076 k_next_section (jt29): loading tune, LOADING screen with the section name and logo, load section
    /// $6e(a6) to $17000 through the loader table $11166, $6e += 1, then k_section_start. Never returns.
    func k_next_section_impl() -> Never {
        tickPoint(0x11076)
        k_music_impl(3)
        mem.w32(a6 + KV.textTable, KA.kernelTexts)
        mem.w16(a6 + KV.textN, 0)
        tickPoint(0x1108a)
        k_fade_out_both()
        tickPoint(0x1108e)
        k_set_split_impl(0x2f)
        mem.w16(KA.copHudBplcon1, 0)
        k_set_top_pal_impl(KA.palBlack)
        k_set_hud_pal_impl(KA.palBlack)
        tickPoint(0x110aa)
        k_clear_screens_impl()
        tickPoint(0x110ae)
        r_print(KA.strLoading)
        tickPoint(0x110ba)
        let idx = UInt32(mem.r16(a6 + KV.section) << 2)                // lsl.w #2 ; (a0,d0.w)
        r_print(mem.r32(KA.secNames &+ idx))
        tickPoint(0x110d0)
        k_show_logo()
        tickPoint(0x110d4)
        k_fade_in_impl(target: KA.palText, palVar: a6 + KV.hudPalPtr, setter: .hud)
        tickPoint(0x110e8)
        call(mem.r32(KA.secLoaders &+ UInt32(mem.r16(a6 + KV.section) << 2)))   // jsr (a0)
        mem.w16(a6 + KV.section, mem.r16(a6 + KV.section) &+ 1)
        k_section_start()
    }

    /// $11102 k_load_sec0: tracks $15.. ($38 tracks) "THE JUNGLE & VILLAGE SECTIONS." to $17000.
    func k_load_sec0() {
        let d0 = k_load_retry(track: 0x15, count: 0x38, dest: KA.sectionEntry, name: KA.strSec0)
        loadedSection = 0
        if d0 != 0 { k_load_fail() }
    }

    /// $1112a k_load_sec1: tracks $54.. ($1b tracks) "THE TUNNEL & FLARE SECTIONS.".
    func k_load_sec1() {
        let d0 = k_load_retry(track: 0x54, count: 0x1b, dest: KA.sectionEntry, name: KA.strSec1)
        loadedSection = 1
        if d0 != 0 { k_load_fail() }
    }

    /// $11148 k_load_sec2: tracks $6f.. ($30 tracks) "THE JUNGLE & FOXHOLE SECTIONS.".
    func k_load_sec2() {
        let d0 = k_load_retry(track: 0x6f, count: 0x30, dest: KA.sectionEntry, name: KA.strSec2)
        loadedSection = 2
        if d0 != 0 { k_load_fail() }
    }

    /// $11120 k_load_fail: st.b $6e(a6); jmp $f800 (warm restart).
    func k_load_fail() -> Never {
        mem.w8(a6 + KV.section, 0xff)
        k_jump_init()
    }

    // MARK: - section start

    /// $fcc8 k_section_start: "ENTERING THE COMBAT ZONE...." (fire skips), game display (split $8f), timer off,
    /// man 0, then `jmp $17000` into the section just loaded. Starts with `lea $400,a7` -> fresh game thread.
    func k_section_start() -> Never {
        m.jump { [unowned self] in self.k_section_start_body() }
    }

    func k_section_start_body() -> Never {
        tickPoint(0xfcc8)
        k_fade_out_both()
        mem.w32(a6 + KV.textTable, KA.kernelTexts)
        k_clear_screens_impl()
        k_set_top_pal_impl(KA.palText)
        k_set_hud_pal_impl(KA.palText)
        mem.w32(a6 + KV.textRamp, KA.rampRed)
        k_queue_text_impl(2)
        repeat {
            k_wait_vbl_impl(); k_wait_vbl_impl()
            k_text_tick()
            if r_joystick() & 0x80 != 0 { break }
        } while mem.r16(a6 + KV.textN) != 0
        tickPoint(0xfd1a)
        k_set_split_impl(0x8f)
        mem.w16(a6 + KV.timerOn, 0)
        k_set_top_pal_impl(KA.palBlack)
        k_set_hud_pal_impl(KA.palBlack)
        k_clear_screens_impl()
        k_display_init_impl()
        mem.w32(a6 + KV.curMan, a6)                                     // lea 0(a6),a5 ; move.l a5,$1e(a6)
        mem.w16(a6 + KV.manIndex, 0)
        settleCPU()
        tickPoint(KA.sectionEntry)
        switch loadedSection {                                          // jmp $17000
        case 0: section0_start()
        case 1: section1_start()
        case 2: section2_start()
        default: fatalError("k_section_start: no section loaded at $17000")
        }
    }

    // MARK: - disk wrappers

    /// $101d0 k_load_retry: up to 5 tries of the resident loader ($420); on error "DISK ERROR #nn, PRESS FIRE"
    /// on row 22, then "THERE HAS BEEN A FATAL DISK ERROR!" and d0 = $fffa. Returns d0 (0 = ok).
    func k_load_retry(track d0: UInt32, count d1: UInt32, dest a0: UInt32, name a1: UInt32) -> UInt16 {
        mem.w16(KA.retryCount, 5)
        k_save_retry_args(d0, d1, a0, a1)
        repeat {
            let r = UInt16(truncatingIfNeeded: diskLoad(track: mem.r32(KA.retryArgs), count: mem.r32(KA.retryArgs + 4),
                                                        dest: mem.r32(KA.retryArgs + 8)))
            if r == 0 { return 0 }
            k_disk_error(r)
            mem.w16(KA.retryCount, mem.r16(KA.retryCount) &- 1)
        } while mem.r16(KA.retryCount) != 0
        mem.w8(a6 + KV.section, 0xff)
        r_print(KA.strFatal)
        k_wait_fire_click()
        return 0xfffa
    }

    /// $1013c k_save_hiscores: the same retry loop around the resident save entry $424 (a crack stub that returns
    /// 0 - the port persists the table there), reprinting the a1 string after an error.
    func k_save_hiscores(track d0: UInt32, count d1: UInt32, src a0: UInt32, name a1: UInt32) -> UInt16 {
        mem.w16(KA.retryCount, 5)
        k_save_retry_args(d0, d1, a0, a1)
        repeat {
            mem.w16(KA.junk, mem.r16(KA.fadeBufHud + 30) & 0x0f00)        // move.w d3,$12d60 (d3 left by k_fade_in)
            let r = UInt16(truncatingIfNeeded: res_disksave(track: mem.r32(KA.retryArgs), count: mem.r32(KA.retryArgs + 4),
                                                            src: mem.r32(KA.retryArgs + 8)))
            if r == 0 { return 0 }
            k_disk_error(r)
            r_print(mem.r32(KA.retryArgs + 12))                            // exg a1,a0 ; print the name string
            mem.w16(KA.retryCount, mem.r16(KA.retryCount) &- 1)
        } while mem.r16(KA.retryCount) != 0
        r_print(KA.strFatal)
        k_wait_fire_click()
        return 0xfffa
    }

    /// movem.l d0-d1/a0-a1,$12d20
    func k_save_retry_args(_ d0: UInt32, _ d1: UInt32, _ a0: UInt32, _ a1: UInt32) {
        mem.w32(KA.retryArgs, d0); mem.w32(KA.retryArgs + 4, d1)
        mem.w32(KA.retryArgs + 8, a0); mem.w32(KA.retryArgs + 12, a1)
    }

    /// $101f4-$10224 (and $1016e-$1019e): "DISK ERROR #nn, PRESS FIRE" (nn = -d0), wait for a click, blank row 22.
    func k_disk_error(_ d0: UInt16) {
        r_print(KA.strBlank22)
        r_print(KA.strDiskError)
        k_hex8_impl(UInt8(truncatingIfNeeded: 0 &- d0))
        k_wait_fire_click()
        r_print(KA.strBlank22)
    }

    // MARK: - game over (jt25) and hiscore entry

    /// $fee8 k_game_over (jt25): "GAME OVER." with the music fading out; if the score reaches the table (ties
    /// rank above) the entry is inserted, the name entered, the table shown and saved; then k_init.
    func k_game_over_impl() -> Never {
        tickPoint(0xfee8)
        k_fade_out_both()
        k_clear_screens_impl()
        k_display_reset()
        k_show_logo()
        k_queue_text_impl(4)
        repeat {
            k_music_fade_step(); k_wait_vbl_impl()
            k_music_fade_step(); k_wait_vbl_impl()
            k_text_tick()
        } while mem.r16(a6 + KV.textN) != 0
        k_music_stop()
        k_clear_both_lower()
        // rank search: cmp.l (a1)+,d6 ; dbcc d1
        let d6 = mem.r32(a6 + KV.score)
        var a1 = KA.hsScores
        var d1: UInt16 = 9
        var carry = true
        while true {
            let v = mem.r32(a1); a1 &+= 4
            carry = d6 < v
            if !carry { break }
            d1 &-= 1
            if d1 == 0xffff { break }
        }
        if carry { k_jump_init() }                                      // bcs k_init: not in the table
        k_music_impl(1)
        let d0 = UInt16(9) &- d1                                        // rank k
        if d0 != 9 { k_hs_shift(count: d1) }
        a1 &-= 4
        mem.w32(a1, d6)                                                 // move.l d6,-(a1)
        let nameAddr = mem.r32(KA.hsOffsets &+ UInt32(d0 << 2)) &+ KA.hsNames
        mem.copy(from: KA.hsNameBuf, to: nameAddr, count: 16)
        k_set_hud_pal_impl(KA.palText)
        mem.w32(a6 + KV.textRamp, KA.rampRed)
        k_name_entry(name: nameAddr)
        // $100a2 k_name_done
        r_print(KA.hsNameLine)
        k_fade_out_hud()
        k_set_hud_pal_impl(KA.palBlack)
        k_clear_both_lower()
        r_print(KA.hiscoreTrack)
        k_print_hs_entries()
        r_print(KA.strSaving)
        k_fade_in_impl(target: KA.palCredits, palVar: a6 + KV.hudPalPtr, setter: .hud)
        _ = k_save_hiscores(track: 0x4d, count: 1, src: KA.hiscoreTrack, name: KA.strSaving)
        k_fade_out_both()
        k_jump_init()
    }

    /// $ff54-$ff9c k_hs_shift: move scores/names down one entry from the end ($1182c/$117c3 backwards), d1+1
    /// times (the last iteration copies entry k-1 over entry k, which is overwritten afterwards).
    func k_hs_shift(count d1: UInt16) {
        var a2: UInt32 = 0x1182c, a3: UInt32 = KA.hsNameLine, a4: UInt32 = 0x117c3, a5: UInt32 = 0x117dc
        var d2 = d1
        while true {
            a2 &-= 4; a3 &-= 4; mem.w32(a3, mem.r32(a2))
            for _ in 0..<16 { a4 &-= 1; a5 &-= 1; mem.w8(a5, mem.r8(a4)) }
            a4 &-= 9; a5 &-= 9
            d2 &-= 1
            if d2 == 0xffff { break }
        }
        cpu((Int(d1) + 1) * 320)
    }

    /// $fffc k_name_loop: 16 characters, LEFT/RIGHT cycle the letter through $40..$5f, FIRE accepts (DEL glyph
    /// $5d = back one, END glyph $5e = fill the rest with spaces). a1 = name in the table, a2 = buffer $11836
    /// (not reset: the next entry starts with the previous name).
    func k_name_entry(name a1start: UInt32) {
        var a1 = a1start, a2 = KA.hsNameBuf
        var d1: UInt16 = 0x0f
        while true {
            let col = UInt8(truncatingIfNeeded: 0x16 &- d1)
            mem.w8(KA.hsCursorCol, col)
            r_print(KA.hsNameLine)
            mem.w8(KA.hsEraseCol, col)
            k_hex32_impl(mem.r32(a6 + KV.score))
            let d0 = k_wait_joy_input()
            if d0 & 0x80 != 0 {                                         // k_name_fire
                let c = mem.r8(a1)
                if c == 0x5d {
                    if d1 == 0x0f { continue }
                    mem.w8(a1, 0x5f); mem.w8(a2, 0x5f)
                    a1 &-= 1; a2 &-= 1
                    d1 &+= 1
                    continue
                }
                if c == 0x5e {
                    while true {
                        mem.w8(a1, 0x20); a1 &+= 1; mem.w8(a2, 0x20); a2 &+= 1
                        d1 &-= 1
                        if d1 == 0xffff { break }
                    }
                    return
                }
                a1 &+= 1; a2 &+= 1
                d1 &-= 1
                if d1 == 0xffff { return }
                continue
            }
            let dir = d0 & 0x0a
            if dir == 0 || dir == 0x0a { continue }
            var c = mem.r8(a1)
            if dir & 0x02 == 0 { c &-= 2 }                              // LEFT: subq.b #2 then addq.b #1
            c &+= 1
            c = (c & 0x1f) | 0x40
            mem.w8(a1, c); mem.w8(a2, c)
        }
    }

    /// $1025a k_wait_joy_input: wait until the joystick is released, then return the first nonzero state;
    /// every poll is k_name_tick.
    func k_wait_joy_input() -> UInt8 {
        repeat { k_name_tick() } while r_joystick() != 0             // k_wait_joy_release
        var d0: UInt8
        repeat { k_name_tick(); d0 = r_joystick() } while d0 == 0
        return d0
    }

    /// $1026e k_name_tick: 2 vblanks, text tick; re-queue "ENTER YOUR NAME:" whenever the queue is empty.
    func k_name_tick() {
        k_wait_vbl_impl(); k_wait_vbl_impl()
        k_text_tick()
        if mem.r16(a6 + KV.textN) != 0 { return }
        k_queue_text_impl(3)
    }

    /// $1028a k_print_hs_table_unused (dead code in the original): black HUD palette, hiscore table.
    func k_print_hs_table_unused() {
        k_set_hud_pal_impl(KA.palBlack)
        r_print(KA.hiscoreTrack)
        k_print_hs_entries()
    }

    // MARK: - hiscore persistence (port)

    /// Port: after the first-boot load of track 77, replace the table with the persisted one if present.
    func loadHiscores() {
        guard let url = config.hiscoreURL, let d = try? Data(contentsOf: url), d.count == Disk.trackSize else { return }
        mem.load([UInt8](d), at: KA.hiscoreTrack)
        log("hiscores loaded from \(url.path)")
    }

    /// Port: the $424 disk save of track 77 (a no-op stub in the crack) writes the table image to hiscoreURL.
    func saveHiscores() {
        guard let url = config.hiscoreURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Data(mem.slice(KA.hiscoreTrack, Disk.trackSize)).write(to: url) } catch { log("hiscore save failed: \(error)") }
    }
}
