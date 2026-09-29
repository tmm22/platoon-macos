// Kernel ($f800 jump table) and resident ($400 jump table) API used by the section code.
// Spec: re/kernel/NOTES.md §(b). Section modules call these Swift functions where the original
// does `jsr $f8xx` / `jsr $40x`. The kernel module implements them (Kernel*.swift / Resident.swift);
// until then the stubs trap. Do NOT change these signatures without updating every caller.
//
// Conventions: all routines assume a6 = $12dde (`Platoon.a6`). Register inputs are parameters, register
// outputs are return values. Routines that never return (`jmp` targets) are `-> Never` and are
// implemented with `m.jump { ... }` so the Swift stack does not grow across sections/games.

extension Platoon {
    /// Global variable block base (a6).
    public static let a6: UInt32 = 0x12dde
    @inline(__always) var a6: UInt32 { Platoon.a6 }

    // MARK: kernel jump table $f800

    /// jt00 $f800 -> $f890 k_init: cold/warm restart to the title loop. Never returns.
    func k_init() -> Never { k_init_impl() }
    /// jt01 $f804 -> $104c6: compass icon from $26(a6)/$2a(a6).
    func k_hud_compass() { k_hud_compass_impl() }
    /// jt02 $f808 -> $1058a: gun/map/TNT icons ($2c/$24/$28) + compass.
    func k_hud_icons() { k_hud_icons_impl() }
    /// jt03 $f80c -> $10638: score += 4-byte BCD value that ENDS at `after` (a0 = address after the value).
    func k_add_score(after a0: UInt32) { k_add_score_impl(after: a0) }
    /// jt04 $f810 -> $106a0: print best score.
    func k_print_hiscore1() { k_print_hiscore1_impl() }
    /// jt05 $f814 -> $106b8: print score if changed.
    func k_print_score() { k_print_score_impl() }
    /// jt06 $f818 -> $10656: wound icons for the current man.
    func k_hud_wounds() { k_hud_wounds_impl() }
    /// jt07-jt10 $f81c-$f828: print hex digits at the text cursor.
    func k_hex32(_ d0: UInt32) { k_hex32_impl(d0) }
    func k_hex16(_ d0: UInt16) { k_hex16_impl(d0) }
    func k_hex8(_ d0: UInt8) { k_hex8_impl(d0) }
    func k_hex4(_ d0: UInt8) { k_hex4_impl(d0) }
    /// jt11 $f82c -> $1070c: queue message d0 (index into text table ($4a)). NB: original masks d0.w & $ff.
    func k_queue_text(_ d0: UInt16) { k_queue_text_impl(d0) }
    /// jt12 $f830 -> $1084a: HUD init.
    func k_hud_init() { k_hud_init_impl() }
    /// jt13 $f834 -> $108a0: HUD update, once per game frame (blocks while the game is paused).
    func k_hud_update() { k_hud_update_impl() }
    /// jt14 $f838 -> $10968: 9-cell bar. d0 = value, a0 = 8x8 cell gfx, a1 = destination byte.
    func k_draw_bar(value d0: UInt16, gfx a0: UInt32, dest a1: UInt32) { k_draw_bar_impl(value: d0, gfx: a0, dest: a1) }
    /// jt15 $f83c -> $109be: one 8x8 4-plane cell, a0 gfx, a1 dest, d2 = AND mask byte.
    func k_draw_cell(gfx a0: UInt32, dest a1: UInt32, mask d2: UInt8) { k_draw_cell_impl(gfx: a0, dest: a1, mask: d2) }
    /// jt16 $f840 -> $104aa: clear both screen buffers $70000-$7ffff.
    func k_clear_screens() { k_clear_screens_impl() }
    /// jt17 $f844 -> $10acc: wait d0+1 vblanks.
    func k_wait_frames(_ d0: UInt16) { k_wait_frames_impl(d0) }
    /// jt18 $f848 -> $10ad6: wait for the next vblank.
    func k_wait_vbl() { k_wait_vbl_impl() }
    /// jt19 $f84c -> $10ae2: flip draw buffer $62(a6) and schedule the other copper list.
    func k_swap() { k_swap_impl() }
    /// jt20 $f850 -> $10bcc: random byte 0..255 (returned as d0.l).
    func k_random() -> UInt32 { k_random_impl() }
    /// jt21 $f854 -> $11062: fill longs: (a0)+ = d0, d0 += d2, d1+1 times. Returns final (a0, d0).
    @discardableResult func k_fill_longs(dest a0: UInt32, start d0: UInt32, countMinus1 d1: UInt16, step d2: UInt32) -> (a0: UInt32, d0: UInt32) {
        k_fill_longs_impl(dest: a0, start: d0, countMinus1: d1, step: d2)
    }
    /// jt23 $f85c -> $10b14: wait until the level-6 handler latched the scheduled copper swap.
    func k_wait_swap() { k_wait_swap_impl() }
    /// jt24 $f860 -> $10b1e: full display/copper init.
    func k_display_init() { k_display_init_impl() }
    /// jt25 $f864 -> $fee8: game over (never returns).
    func k_game_over() -> Never { k_game_over_impl() }
    /// jt26 $f868 -> $10c00: play tune d0.
    func k_music(_ d0: UInt16) { k_music_impl(d0) }
    /// jt27 $f86c -> $10c50: sound effect d0.
    func k_fx(_ d0: UInt16) { k_fx_impl(d0) }
    /// jt28 $f870 -> fade_in: fade palette from black to `target` (16 words), 16 steps x 2 vblanks.
    /// `palVar` = address of the palette-pointer variable ($5a(a6) or $5e(a6)); `setter` = which palette setter.
    func k_fade_in(target a0: UInt32, palVar a3: UInt32, setter a4: PaletteSetter) { k_fade_in_impl(target: a0, palVar: a3, setter: a4) }
    /// jt29 $f874 -> $11076: load and start section $6e(a6). Never returns.
    func k_next_section() -> Never { k_next_section_impl() }
    /// jt30 $f878 -> $11010: top (game window) palette := 16 words at a0.
    func k_set_top_pal(_ a0: UInt32) { k_set_top_pal_impl(a0) }
    /// jt31 $f87c -> $11000: HUD palette := 16 words at a0.
    func k_set_hud_pal(_ a0: UInt32) { k_set_hud_pal_impl(a0) }
    /// jt32 $f880 -> $fd4e: split line (last game-window line; $8f in game).
    func k_set_split(_ d0: UInt8) { k_set_split_impl(d0) }

    /// Exported pointers at $f884/$f888/$f88c.
    static let hudCellGfx: UInt32 = 0x13254
    static let copGameDIWSTRT: UInt32 = 0x115f6
    static let copHudBPLCON1: UInt32 = 0x1165e

    public enum PaletteSetter { case top, hud   // jt30 / jt31 (a4 = $f878 / $f87c)
    }

    // MARK: resident jump table $400

    /// $404 putchar d0.
    func r_putchar(_ d0: UInt8) { r_putchar_impl(d0) }
    /// $408 print string with control codes at a0. Returns a0 after the terminator.
    @discardableResult func r_print(_ a0: UInt32) -> UInt32 { r_print_impl(a0) }
    /// $40c key test: true if raw key `code` is held (original: d0 = -1 / 0).
    func r_keytest(_ code: UInt8) -> Bool { r_keytest_impl(code) }
    /// $410 joystick: bit0 down, bit1 right, bit2 up, bit3 left, bit7 fire. (Original clobbers d2.)
    func r_joystick() -> UInt8 { r_joystick_impl() }
    /// $42e getkey: lowest held raw keycode, nil if none.
    func r_getkey() -> UInt8? { r_getkey_impl() }
    /// Text cursor ($41c column, $41e row).
    var r_cursorCol: UInt16 { get { mem.r16(0x41c) } set { mem.w16(0x41c, newValue) } }
    var r_cursorRow: UInt16 { get { mem.r16(0x41e) } set { mem.w16(0x41e, newValue) } }
}
