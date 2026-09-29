import Foundation

// F1 CONTEXT PROBE (owner: core): a read-only description of what the game is showing, for host features
// (controller context, overlays, objectives, maps, captions, practice, speedrun).
//
// Built from RAM plus a few host-side facts the kernel reports (screen phase, loaded section, the last main-loop
// head reached - `tickPoint` PCs, so section code needs no changes). Get it with `GameProbe.context` (refreshed by
// `GameProbe.poll(machine)` in Machine.frameHook, where the game thread is parked and RAM reads don't race) or
// `GameProbe.snapshot(machine)`. Nothing here writes RAM.

public struct GameContext: Equatable {
    /// What kind of screen is up.
    public enum Screen: String {
        case boot            // power-on until the title loop
        case title           // credits / hiscore page / attract picture
        case loading         // "LOADING..." (k_next_section)
        case entering        // "ENTERING THE COMBAT ZONE...." (k_section_start)
        case playing         // a section's main loop (incl. its HUD messages and dissolves)
        case textScreen      // a section's full-screen text (ONE MORE CHANCE, intro texts, endings)
        case manSelect       // section 0 "CHOOSE YOUR MAN"
        case trapDoorPrompt  // section 0 hut 1: "DO YOU WANT TO GO DOWN THE TRAP DOOR? Y/N"
        case gameOver        // "GAME OVER." / hiscore table / SAVING
        case nameEntry       // hiscore name entry
    }
    /// Where the player is (sub-mode of the loaded section).
    public enum Area: String {
        case none, jungle, village, hut, tunnels, flare, finalJungle, bunker
    }
    public struct Man: Equatable {
        public var grenades: Int, ammo: Int, hits: Int
        public var alive: Bool { hits < 4 }
    }
    /// Section 0 view (jungle, village, huts).
    public struct Jungle: Equatable {
        /// Map strip 0..5 ($60c26; 0 = rearmost incl. the village street, 5 = hut interiors).
        public var level: Int
        /// Player map column ($60c28, 64-px tiles) and world x in 8-px units ($60c30).
        public var column: Int, worldX: Int
        /// Hut number 0..5 ($60c40) when inside a hut.
        public var hut: Int?
        /// Bridge 0 intact / 1 charge set / 2 blown ($60c9c).
        public var bridge: Int
        /// Torch found ($60cbd != 0).
        public var torch: Bool
        /// Player state ($5f89a) and enemy state ($5f888).
        public var playerState: Int, enemyState: Int
    }
    /// Section 1 view (tunnels; flare night uses only `flare`).
    public struct Tunnels: Equatable {
        /// Maze cell ($1a0b0/$1a0b1), heading $2a(a6) 0 N 1 E 2 S 3 W.
        public var x: Int, y: Int, heading: Int
        /// Inside a room ($3b230) and which of the 10 rooms ($19aec index) if known.
        public var inRoom: Bool, room: Int?
    }
    /// Section 2 view (final jungle, bunker).
    public struct FinalJungle: Equatable {
        /// Current room (byte $18f1c; 105 = start), heading long ($18f40), exit mask ($57f44, 0 = bunker room), room type ($57f45).
        public var room: Int, dirs: UInt32, exits: Int, roomType: Int
        /// Barnes' hit points (byte 0 of slot 4, $57e6a) - meaningful in the bunker.
        public var barnesHP: Int
    }

    public var frame: UInt64 = 0
    public var screen: Screen = .boot
    public var area: Area = .none
    /// The load section that is running (0 jungle & village, 1 tunnels & flare, 2 final jungle & foxhole);
    /// nil on boot/title/loading/game over.
    public var section: Int?
    /// The section code currently in memory at $17000 (-1 none). Unlike $6e(a6) (already the NEXT section while
    /// a section runs) this is the real one.
    public var loadedSection: Int = -1
    /// A game is running (from the start of a new game until its game over / DEL abort).
    public var inGame = false
    /// TAB pause active ($10eaa != 0).
    public var paused = false
    /// F10 mode $66(a6): bit0 music, bit1 fx.
    public var soundFlags: UInt8 = 3
    /// Score (8 BCD digits, $4e(a6)) and its value.
    public var scoreBCD: UInt32 = 0
    public var score: Int { Platoon.bcdValue(scoreBCD) }
    /// Morale $2e(a6) (8.8 fixed point; a new game starts at $9000).
    public var morale: Int = 0
    public var men: [Man] = []
    /// Current man index $22(a6) (0..4).
    public var currentMan: Int = 0
    /// Mission timer $6c/$6d(a6) (BCD minutes/seconds) and whether it runs ($68(a6)).
    public var timerMinutes: Int = 0, timerSeconds: Int = 0, timerRunning = false
    /// Items: map $24, compass $26 (+ heading $2a), explosives $28, gun/flares $2c (a6 words).
    public var map = false, compass = false, explosives = false, flares: Int = 0
    /// Message queue: pending count $48(a6), queue $3c(a6), current text table $4a(a6).
    public var messageCount: Int = 0, messageQueue: [Int] = [], messageTable: UInt32 = 0
    /// Original cheat flags $70(a6) (bit0 HAMBURGER, bit1 MEGA CHEAT).
    public var cheats: Int = 0
    public var jungle: Jungle?
    public var tunnels: Tunnels?
    public var finalJungle: FinalJungle?
    /// The full-screen text being shown (screen == .textScreen / .loading), decoded; nil otherwise.
    public var text: String?
    /// Difficulty preset of the run and the assisted (tainted) state (F4/S5).
    public var difficulty: DifficultyPreset = .original
    public var assisted = false
    public var assistReasons: [String] = []
    /// Hiscore table this run's score goes to ("original", "recruit", "veteran", "custom", "assisted").
    public var hiscoreMode = "original"

    /// The trap-door prompt is up (section 0, hut 1).
    public var trapDoorPrompt: Bool { screen == .trapDoorPrompt }
    /// The current man record.
    public var man: Man? { currentMan < men.count ? men[currentMan] : nil }
}

extension Platoon {
    /// Decimal value of 8 BCD digits.
    public static func bcdValue(_ v: UInt32) -> Int {
        var r = 0
        for i in stride(from: 28, through: 0, by: -4) { r = r * 10 + Int((v >> UInt32(i)) & 0xf) }
        return r
    }
}

/// Decoder for the resident print strings (res_print $1a5c control codes): [col,row] then characters; 0 = new
/// [col,row]; 1..4 + byte = colour slot; $0d = next row; $80..$fe = last character (b & $7f); $ff = end.
public enum PrintText {
    public struct Segment: Equatable { public var col: Int, row: Int, text: String }

    /// Segments of the string at `addr` (read-only).
    public static func segments(_ mem: Memory, _ addr: UInt32, limit: Int = 4000) -> [Segment] {
        var a = addr, out: [Segment] = []
        var col = Int(mem.r8(a)), row = Int(mem.r8(a &+ 1)); a &+= 2
        var cur = "", startCol = col
        func flush() { if !cur.isEmpty { out.append(Segment(col: startCol, row: row, text: cur)) }; cur = "" }
        var n = 0
        while n < limit {
            n += 1
            let b = mem.r8(a); a &+= 1
            if b == 0 {
                flush(); col = Int(mem.r8(a)); row = Int(mem.r8(a &+ 1)); a &+= 2; startCol = col; continue
            }
            if b & 0x80 != 0 {
                if b != 0xff { cur.append(glyph(b & 0x7f)) }
                flush(); return out
            }
            if b < 5 { a &+= 1; continue }
            if b == 0x0d { flush(); row += 1; col = 0; startCol = 0; continue }
            if b < 0x20 { continue }
            cur.append(glyph(b)); col += 1
        }
        flush()
        return out
    }

    /// Plain text: segments ordered by row then column; rows separated by newlines.
    public static func plain(_ segs: [Segment]) -> String {
        let rows = Dictionary(grouping: segs, by: { $0.row }).sorted { $0.key < $1.key }
        return rows.map { _, s in
            s.sorted { $0.col < $1.col }.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func decode(_ mem: Memory, _ addr: UInt32) -> String { plain(segments(mem, addr)) }

    /// Font glyph -> character ($5d/$5e are the DEL/END glyphs of the name entry).
    static func glyph(_ c: UInt8) -> Character {
        switch c {
        case 0x5d: return "\u{232B}"
        case 0x5e: return "\u{21B5}"
        case 0x20...0x7e: return Character(Unicode.Scalar(c))
        default: return "?"
        }
    }
}
