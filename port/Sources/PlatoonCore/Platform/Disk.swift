import Foundation

/// The original Platoon disk (ADF, 880 KB). All game data is read from it at runtime, exactly
/// like the original track loader did (DOS-format tracks of 11*512 bytes).
public final class Disk {
    public static let trackSize = 11 * 512
    public let data: [UInt8]

    public init(data: [UInt8]) throws {
        guard data.count >= 160 * Disk.trackSize else { throw DiskError.badSize(data.count) }
        self.data = data
    }
    public convenience init(contentsOf url: URL) throws {
        try self.init(data: [UInt8](try Data(contentsOf: url)))
    }

    public enum DiskError: Error { case badSize(Int), notPlatoon }

    /// Equivalent of the resident loader at $d1a: d0 = first track, d1 = track count, a0 = destination.
    public func loadTracks(first: Int, count: Int, to address: UInt32, memory: Memory) {
        for t in 0..<count {
            let off = (first + t) * Disk.trackSize
            for i in 0..<Disk.trackSize { memory.w8(address &+ UInt32(t * Disk.trackSize + i), data[off + i]) }
        }
    }

    public func bytes(at offset: Int, count: Int) -> [UInt8] { Array(data[offset..<(offset + count)]) }

    /// Checks that this is a Platoon disk we know how to use (main program + all three sections present).
    public func validate() throws {
        // main program starts with bra.w at track 1; section 0 code begins with lea $400,a7
        let t1 = Disk.trackSize, t21 = 21 * Disk.trackSize
        guard data[t1] == 0x60, data[t21] == 0x4f, data[t21 + 1] == 0xf9 else { throw DiskError.notPlatoon }
    }
}
