// TEMPORARY stubs for the kernel/resident API. The kernel translation replaces this file.

extension Platoon {
    func k_init_impl() -> Never { fatalError("k_init_impl not translated yet") }
    func k_hud_compass_impl() { fatalError("k_hud_compass_impl not translated yet") }
    func k_hud_icons_impl() { fatalError("k_hud_icons_impl not translated yet") }
    func k_add_score_impl(after a0: UInt32) { fatalError("k_add_score_impl not translated yet") }
    func k_print_hiscore1_impl() { fatalError("k_print_hiscore1_impl not translated yet") }
    func k_print_score_impl() { fatalError("k_print_score_impl not translated yet") }
    func k_hud_wounds_impl() { fatalError("k_hud_wounds_impl not translated yet") }
    func k_hex32_impl(_ d0: UInt32) { fatalError("k_hex32_impl not translated yet") }
    func k_hex16_impl(_ d0: UInt16) { fatalError("k_hex16_impl not translated yet") }
    func k_hex8_impl(_ d0: UInt8) { fatalError("k_hex8_impl not translated yet") }
    func k_hex4_impl(_ d0: UInt8) { fatalError("k_hex4_impl not translated yet") }
    func k_queue_text_impl(_ d0: UInt16) { fatalError("k_queue_text_impl not translated yet") }
    func k_hud_init_impl() { fatalError("k_hud_init_impl not translated yet") }
    func k_hud_update_impl() { fatalError("k_hud_update_impl not translated yet") }
    func k_draw_bar_impl(value d0: UInt16, gfx a0: UInt32, dest a1: UInt32) { fatalError("k_draw_bar_impl not translated yet") }
    func k_draw_cell_impl(gfx a0: UInt32, dest a1: UInt32, mask d2: UInt8) { fatalError("k_draw_cell_impl not translated yet") }
    func k_clear_screens_impl() { fatalError("k_clear_screens_impl not translated yet") }
    func k_wait_frames_impl(_ d0: UInt16) { fatalError("k_wait_frames_impl not translated yet") }
    func k_wait_vbl_impl() { fatalError("k_wait_vbl_impl not translated yet") }
    func k_swap_impl() { fatalError("k_swap_impl not translated yet") }
    func k_random_impl() -> UInt32 { fatalError("k_random_impl not translated yet") }
    func k_fill_longs_impl(dest a0: UInt32, start d0: UInt32, countMinus1 d1: UInt16, step d2: UInt32) -> (a0: UInt32, d0: UInt32) { fatalError("k_fill_longs_impl not translated yet") }
    func k_wait_swap_impl() { fatalError("k_wait_swap_impl not translated yet") }
    func k_display_init_impl() { fatalError("k_display_init_impl not translated yet") }
    func k_game_over_impl() -> Never { fatalError("k_game_over_impl not translated yet") }
    func k_music_impl(_ d0: UInt16) { fatalError("k_music_impl not translated yet") }
    func k_fx_impl(_ d0: UInt16) { fatalError("k_fx_impl not translated yet") }
    func k_fade_in_impl(target a0: UInt32, palVar a3: UInt32, setter a4: PaletteSetter) { fatalError("k_fade_in_impl not translated yet") }
    func k_next_section_impl() -> Never { fatalError("k_next_section_impl not translated yet") }
    func k_set_top_pal_impl(_ a0: UInt32) { fatalError("k_set_top_pal_impl not translated yet") }
    func k_set_hud_pal_impl(_ a0: UInt32) { fatalError("k_set_hud_pal_impl not translated yet") }
    func k_set_split_impl(_ d0: UInt8) { fatalError("k_set_split_impl not translated yet") }
    func r_putchar_impl(_ d0: UInt8) { fatalError("r_putchar_impl not translated yet") }
    func r_print_impl(_ a0: UInt32) -> UInt32 { fatalError("r_print_impl not translated yet") }
    func r_keytest_impl(_ code: UInt8) -> Bool { fatalError("r_keytest_impl not translated yet") }
    func r_joystick_impl() -> UInt8 { fatalError("r_joystick_impl not translated yet") }
    func r_getkey_impl() -> UInt8? { fatalError("r_getkey_impl not translated yet") }
}
