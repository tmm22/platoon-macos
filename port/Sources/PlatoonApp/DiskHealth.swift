import Foundation
import CryptoKit
import PlatoonCore

// M23 disk health check and repair. Identifies a user-supplied Platoon .adf by per-track fingerprints of every
// track the port reads (1-77 and 82-158) against the verified image, and rebuilds a working image from several
// dumps when each of them has part of the good data (e.g. the [cr 68 Darc] crack, whose track 77 is blank and
// track 127 corrupt, plus the original [b] dump or the LFC trainer for those two tracks). No game data is
// embedded except the default high-score table (track 77, 398 bytes), used when no supplied dump has one.

enum DiskHealth {
    enum Area: String {
        case main = "main program", logo = "loading picture", section0 = "Jungle & Village data", hiscores = "high-score table",
             loader = "boot loader", section1 = "Tunnels & Flare data", section2 = "Final Jungle & Foxhole data",
             section2Pictures = "final jungle room pictures"
        /// A mismatch here means the port can't run the image (different crack / encrypted original).
        var critical: Bool { self == .main || self == .loader }
    }
    static func area(of t: Int) -> Area {
        switch t {
        case 1...17: return .main
        case 18...20: return .logo
        case 21...76: return .section0
        case 77: return .hiscores
        case 82...83: return .loader
        case 84...110: return .section1
        case 127: return .section2Pictures
        default: return .section2
        }
    }
    static let neededTracks = Array(1...77) + Array(82...158)
    static let imageSize = 160 * Disk.trackSize

    static func hash(_ d: some Collection<UInt8>) -> String {
        SHA256.hash(data: Data(d)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func track(_ d: [UInt8], _ t: Int) -> ArraySlice<UInt8> { d[(t * Disk.trackSize)..<((t + 1) * Disk.trackSize)] }
    static func trackIsGood(_ d: [UInt8], _ t: Int) -> Bool { d.count >= imageSize && hash(track(d, t)) == goodTracks[t] }
    /// Track 77 holds a usable high-score table (the verified one, or one with saved scores).
    static func hiscoreTableValid(_ d: [UInt8]) -> Bool {
        guard d.count >= imageSize else { return false }
        let t = Array(track(d, 77))
        return trackIsGood(d, 77) || Array(t[8..<24]) == Array("TEN BEST SCORES:".utf8) && t[0] == 0x0c
    }

    struct Report {
        var name: String?
        var sizeOK: Bool
        var badTracks: [Int]           // needed tracks that differ from the verified image (77 excluded if valid)
        var hiscoreValid: Bool
        var badAreas: [Area] { var s: [Area] = []; for t in badTracks { let a = DiskHealth.area(of: t); if !s.contains(a) { s.append(a) } }; return s }
        var verified: Bool { sizeOK && badTracks.isEmpty }
        /// Runs at all (main program + loader identical to the verified dump).
        var runnable: Bool { sizeOK && !badAreas.contains { $0.critical } }

        var summary: String {
            if !sizeOK { return "Not an 880 KB Amiga disk image." }
            if verified { return "Verified: every track the port reads matches the tested disk." }
            let crit = badAreas.filter(\.critical)
            if !runnable { return "Can't be used: its \(crit.map(\.rawValue).joined(separator: " and ")) \(crit.count > 1 ? "differ" : "differs") from the version this port runs." }
            return "Playable with problems: " + badAreas.map(\.rawValue).joined(separator: ", ") + "."
        }
        var details: [String] {
            var out: [String] = []
            out.append("Identified as: " + (name ?? "unknown dump"))
            for a in badAreas {
                let ts = badTracks.filter { DiskHealth.area(of: $0) == a }
                let list = ts.count > 6 ? "\(ts.count) tracks" : "track" + (ts.count > 1 ? "s " : " ") + ts.map(String.init).joined(separator: ", ")
                let why: String
                switch a {
                case .main, .loader: why = "this is a different release or crack (the port runs the [cr 68 Darc] main program)."
                case .hiscores: why = "the high-score table is blank; a default table can be restored."
                case .section2Pictures: why = "the final jungle's room pictures are corrupt (a known fault of the Darc and Beyonders dumps)."
                case .logo: why = "the Ocean loading picture differs (cosmetic)."
                default: why = "this section's data differs from the tested disk; it may glitch or crash."
                }
                out.append("• \(a.rawValue.prefix(1).uppercased() + a.rawValue.dropFirst()) (\(list)): \(why)")
            }
            return out
        }
    }

    static func check(_ d: [UInt8]) -> Report {
        guard d.count >= imageSize else { return Report(name: nil, sizeOK: false, badTracks: [], hiscoreValid: false) }
        let name = knownImages[hash(d.prefix(imageSize))]
        let hsValid = hiscoreTableValid(d)
        let bad = neededTracks.filter { t in t == 77 ? !hsValid : !trackIsGood(d, t) }
        return Report(name: name, sizeOK: true, badTracks: bad, hiscoreValid: hsValid)
    }

    struct Repair {
        var data: [UInt8]
        /// track -> index of the source image (or -1 = built-in default high-score table)
        var fixed: [Int: Int]
        var report: Report
    }

    /// Builds the best image from one or more dumps: every needed track is taken from the first dump that has
    /// the verified content; the high-score table from the first dump with a valid one, else the default table.
    /// Tracks the port doesn't read come from the dump with the good main program.
    static func repair(_ images: [[UInt8]]) -> Repair? {
        let imgs = images.filter { $0.count >= imageSize }
        guard !imgs.isEmpty else { return nil }
        let base = imgs.firstIndex { img in (1...17).allSatisfy { trackIsGood(img, $0) } } ?? 0
        var out = Array(imgs[base].prefix(imageSize))
        var fixed: [Int: Int] = [:]
        func copy(_ t: Int, from i: Int) {
            let r = (t * Disk.trackSize)..<((t + 1) * Disk.trackSize)
            out.replaceSubrange(r, with: imgs[i][r]); fixed[t] = i
        }
        for t in neededTracks where t != 77 && !trackIsGood(out, t) {
            if let i = imgs.firstIndex(where: { trackIsGood($0, t) }) { copy(t, from: i) }
        }
        if !trackIsGood(out, 77) {
            if let i = imgs.firstIndex(where: { trackIsGood($0, 77) }) { copy(77, from: i) }
            else if !hiscoreTableValid(out) {
                if let i = imgs.firstIndex(where: { hiscoreTableValid($0) }) { copy(77, from: i) }
                else {
                    var t = [UInt8](repeating: 0, count: Disk.trackSize)
                    t.replaceSubrange(0..<defaultHiscoreTable.count, with: defaultHiscoreTable)
                    out.replaceSubrange((77 * Disk.trackSize)..<(78 * Disk.trackSize), with: t); fixed[77] = -1
                }
            }
        }
        return Repair(data: out, fixed: fixed, report: check(out))
    }

    /// SHA-256 (first 8 bytes) of every track the port reads, from the verified image (re/platoon_port.adf).
    static let goodTracks: [Int: String] = [
        1: "a319d06da0868de6", 2: "6e9f158dcac9d711", 3: "59bc5b418b9271b9", 4: "447d7ff4cb4582e9",
        5: "74bff01e33889b21", 6: "6f735bb36470c78d", 7: "7bf54d29b988d4c2", 8: "9470d95c05d4868d",
        9: "46e71f9742d43fd2", 10: "4575ca73d84c14d1", 11: "9814e7447206a9ec", 12: "dd8946290503e4bd",
        13: "ceeff4ad901c0718", 14: "fa58dde64f6a9d04", 15: "bf8190c2c8f34f1b", 16: "e6a55bcef21710af",
        17: "4d92df5dd00670bf", 18: "00d4c19eaff7762c", 19: "d82d21b45b361d8e", 20: "682c7adfe6d2edd6",
        21: "9c4fb15e0539fe80", 22: "4bdb8d97e1bfb7bb", 23: "adec8be76483f703", 24: "27bd83d3cde1679e",
        25: "4b1b854d0a27a5fc", 26: "9196189cd50d38f6", 27: "b71e84ebdf6a3830", 28: "bbd064594b29cf56",
        29: "2c6a1f96eb05d713", 30: "287cfba3a60d10ef", 31: "48d527e3305a4641", 32: "56d083705fc04a0a",
        33: "cb12fa3b29e657c6", 34: "659c3e05b621c4b2", 35: "9590990d0baefc67", 36: "3ff91db2e42a3e0b",
        37: "8619ac7a7b904a16", 38: "44aeda172bb9fb71", 39: "07fa8a94dd06b17c", 40: "8378fbdfced2b111",
        41: "b10eefeb8e73a010", 42: "e76d7025a7e0a996", 43: "ed354b47602c30ce", 44: "e0b14545ce0beae3",
        45: "1a76541d6e8ae45f", 46: "0255787141f419e1", 47: "657de6c9a6fe2369", 48: "fc33b8dc10f074e8",
        49: "4fdcb22e9a608475", 50: "02d3aa87646004fb", 51: "44c9c414d07a811f", 52: "e9006fc6914b8569",
        53: "414ad5f0a243e0b7", 54: "8d6a1c91ab504c74", 55: "203e16be46c03f08", 56: "209177d4620f78d9",
        57: "de9be0cd7d22ce45", 58: "33e1a94cddd527fa", 59: "507738e6f7ce24ac", 60: "46630c3b8ebe36dc",
        61: "5d9af24288a89f4a", 62: "faf069409c1a9036", 63: "a6b287450beafd5d", 64: "57455a1edf79c600",
        65: "1c53510dbea3753a", 66: "9b71681f3c23d9c3", 67: "20dcefa285b68136", 68: "ededb32711a0c5fc",
        69: "5077cb0d9ef9ac41", 70: "fbf5028e039e1c84", 71: "b1dab233c043b8c7", 72: "e85492764b7a1d51",
        73: "6add292793af2897", 74: "60d6545213b2386d", 75: "07fa8a94dd06b17c", 76: "07fa8a94dd06b17c",
        77: "abb2fb043c61d3c5", 82: "cf3bb12a4d4fb25b", 83: "4c2a0ae3697157f9", 84: "d5e55a7d126cb78b",
        85: "6d05e188828e3695", 86: "6e2cd699ced77f32", 87: "3e24c6e5858c6f5f", 88: "e72e0a104427d140",
        89: "3c6fd4bea35547e3", 90: "d1dfc05c74810625", 91: "7d57c4bacbaf19cc", 92: "43bbd8756f6e8ea1",
        93: "4de1c8a6ab1b9673", 94: "28874c9edd4dfebc", 95: "9c40043fba051e39", 96: "07fa8a94dd06b17c",
        97: "12066ec4b4e564ab", 98: "2152d39e587217ad", 99: "05b90a4e322c6ef0", 100: "b29daf1452ea8358",
        101: "27efdd13145d92a6", 102: "d45bf25ba920a6f0", 103: "13955afb9fbafef1", 104: "643141ca794280a8",
        105: "2950d23b31083dbf", 106: "4e7d0b7dda4a2072", 107: "0b8ce498f0484a07", 108: "6b41f187145cdb40",
        109: "c9e8811813652231", 110: "07fa8a94dd06b17c", 111: "1c3df95433f9e8b1", 112: "cc76a9625e9d5170",
        113: "ef2c9dcd1c08ee08", 114: "646544ae21560ed7", 115: "314132e4229e8289", 116: "18bfdc9bb5a6fea2",
        117: "1ce612d5a486cba4", 118: "627e189b17511c4d", 119: "cd7413e157816d5e", 120: "1acd26cb65d2dc46",
        121: "89260bb8aed4f8ff", 122: "74f9d961be84edd4", 123: "0345690ee44b3d03", 124: "dc091965f4778bc1",
        125: "38ee95a9fb9304f0", 126: "514f5065e9400c69", 127: "84c5aa1433540675", 128: "5d4a8732092c5b54",
        129: "4d9f718a9bc8a6b6", 130: "c78dbab9104fb771", 131: "5ab0f9dd4232eb18", 132: "6ec7a4a65416107e",
        133: "3d743c7c3491a53b", 134: "08902112ae958a38", 135: "bc69f42403a5aa0f", 136: "6110320b444e3873",
        137: "8642db7f95e445e6", 138: "7de78a5271972162", 139: "ea95007fb6db3297", 140: "7eb5939e96dd0c7a",
        141: "4a1ce0f044c38c1e", 142: "d2eddfd12e371a02", 143: "ac2791c100219eb1", 144: "879548bb9dfa0e21",
        145: "4d726bb73946fb01", 146: "f3d177410a02c623", 147: "0a568e60772fa95a", 148: "e337d762a106496d",
        149: "479835aa7e8161bf", 150: "3004f765d241f712", 151: "ec7d180afd70f218", 152: "8c85ce00e31506c4",
        153: "f6ef600bb4661a34", 154: "e468d9da6265abfc", 155: "3b6c30ec59aee020", 156: "ce676b3a262cd7a4",
        157: "e9dc69e08567f392", 158: "279f021e18b12085",
    ]
    /// Whole-image SHA-256 (first 8 bytes) of known dumps.
    static let knownImages: [String: String] = [
        "9b4a6b8be0d9c068": "Platoon (port image: [cr 68 Darc] + tracks 77/127 from the original)",
        "6d09c7f08a484508": "Platoon (1988)(Ocean)[b] — original, protected",
        "efec5e8bb1759d1a": "Platoon (1988)(Ocean)[cr 68 Darc]",
        "89a93af185766c0f": "Platoon (1988)(Ocean)[cr VF - Beyonders]",
        "5d0a7f197f2027d4": "Platoon (1988)(Ocean)[cr VF - Beyonders][t +5 LFC]",
    ]
    /// Default high-score table (track 77 of the original disk, 398 bytes, rest zero) for dumps whose table is blank.
    static let defaultHiscoreTable: [UInt8] = [
        0x0c, 0x09, 0x01, 0x00, 0x02, 0x01, 0x03, 0x02, 0x54, 0x45, 0x4e, 0x20, 0x42, 0x45, 0x53, 0x54, 0x20, 0x53, 0x43, 0x4f, 0x52, 0x45, 0x53, 0x3a,
        0xff, 0x07, 0x0b, 0x02, 0x03, 0x03, 0x04, 0x4d, 0x50, 0x55, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x20,
        0x20, 0xff, 0x07, 0x0c, 0x02, 0x05, 0x03, 0x06, 0x43, 0x49, 0x41, 0x20, 0x41, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x20, 0x20, 0xff, 0x07, 0x0d, 0x02, 0x07, 0x03, 0x08, 0x43, 0x49, 0x41, 0x20, 0x42, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x20, 0x20, 0xff, 0x07, 0x0e, 0x02, 0x09, 0x03, 0x0a, 0x49, 0x4b, 0x42, 0x44, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x20, 0x20, 0xff, 0x07, 0x0f, 0x02, 0x0b, 0x03, 0x0c, 0x41, 0x4e, 0x47, 0x55, 0x53, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x2e, 0x20, 0x20, 0xff, 0x07, 0x10, 0x02, 0x0d, 0x03, 0x0e, 0x42, 0x4c, 0x49, 0x54, 0x54, 0x45, 0x52, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x2e, 0x2e, 0x20, 0x20, 0xff, 0x07, 0x11, 0x02, 0x03, 0x03, 0x04, 0x43, 0x4f, 0x50, 0x50, 0x45, 0x52, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x20, 0x20, 0xff, 0x07, 0x12, 0x02, 0x05, 0x03, 0x06, 0x44, 0x45, 0x4e, 0x49, 0x53, 0x45, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x20, 0x20, 0xff, 0x07, 0x13, 0x02, 0x07, 0x03, 0x08, 0x44, 0x4d, 0x41, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x20, 0x20, 0xff, 0x07, 0x14, 0x02, 0x09, 0x03, 0x0a, 0x50, 0x41, 0x55, 0x4c, 0x41, 0x2e, 0x2e, 0x2e,
        0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x20, 0x20, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x19, 0x00, 0x00, 0x00, 0x32,
        0x00, 0x00, 0x00, 0x4b, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x00, 0x96, 0x00, 0x00, 0x00, 0xaf, 0x00, 0x00, 0x00, 0xc8,
        0x00, 0x00, 0x00, 0xe1, 0x00, 0x06, 0x80, 0x00, 0x00, 0x00, 0x85, 0x20, 0x00, 0x00, 0x85, 0x20, 0x00, 0x00, 0x65, 0x02, 0x00, 0x00, 0x50, 0x40,
        0x00, 0x00, 0x07, 0x20, 0x00, 0x00, 0x01, 0x20, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x02, 0x07, 0x0d, 0x02, 0x02,
        0x03, 0x0a, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x5f, 0x02, 0x08, 0x03, 0x09, 0x00, 0x00,
        0x0e, 0x20, 0x00, 0x00, 0x0e, 0x25, 0x00, 0x19, 0x0d, 0x02, 0x02, 0x03, 0x0a, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
}
