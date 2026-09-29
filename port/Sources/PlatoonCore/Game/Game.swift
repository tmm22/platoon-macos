/// Entry point of the translated game. Filled in by the translation of the resident code/kernel.
public enum PlatoonGame {
    /// Runs the whole game on the machine's game thread (never returns in normal play).
    public static func main(_ m: Machine) {
        // Placeholder until the kernel translation lands: idle with a black screen.
        while true { m.waitVBlank() }
    }
}
