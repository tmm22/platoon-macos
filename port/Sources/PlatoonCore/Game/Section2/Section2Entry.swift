// Entry point of load section 2 (code at $17000 after the kernel loaded it). Called by the kernel's
// section start (k_section_start $fcc8 does jmp $17000). Never returns: it ends with k_next_section()
// or k_game_over(). The Section2 translation replaces this stub file.
extension Platoon {
    func section2_start() -> Never { fatalError("section 2 not translated yet") }
}
