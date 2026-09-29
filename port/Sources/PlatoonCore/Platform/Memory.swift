// 512 KB Amiga chip RAM image. The translated game code keeps the original memory layout, so
// tables, graphics and variables live at their original addresses and are accessed big-endian.

public final class Memory {
    public static let size = 0x80000
    public static let mask: UInt32 = 0x7FFFF
    public let bytes: UnsafeMutablePointer<UInt8>

    public init() {
        bytes = .allocate(capacity: Memory.size)
        bytes.initialize(repeating: 0, count: Memory.size)
    }
    deinit { bytes.deallocate() }

    @inline(__always) public func r8(_ a: UInt32) -> UInt8 { bytes[Int(a & Memory.mask)] }
    @inline(__always) public func r16(_ a: UInt32) -> UInt16 {
        let i = Int(a & Memory.mask)
        return UInt16(bytes[i]) << 8 | UInt16(bytes[(i + 1) & 0x7FFFF])
    }
    @inline(__always) public func r32(_ a: UInt32) -> UInt32 { UInt32(r16(a)) << 16 | UInt32(r16(a &+ 2)) }
    @inline(__always) public func s8(_ a: UInt32) -> Int8 { Int8(bitPattern: r8(a)) }
    @inline(__always) public func s16(_ a: UInt32) -> Int16 { Int16(bitPattern: r16(a)) }
    @inline(__always) public func s32(_ a: UInt32) -> Int32 { Int32(bitPattern: r32(a)) }

    @inline(__always) public func w8(_ a: UInt32, _ v: UInt8) { bytes[Int(a & Memory.mask)] = v }
    @inline(__always) public func w16(_ a: UInt32, _ v: UInt16) {
        let i = Int(a & Memory.mask)
        bytes[i] = UInt8(v >> 8); bytes[(i + 1) & 0x7FFFF] = UInt8(truncatingIfNeeded: v)
    }
    @inline(__always) public func w32(_ a: UInt32, _ v: UInt32) { w16(a, UInt16(v >> 16)); w16(a &+ 2, UInt16(truncatingIfNeeded: v)) }
    @inline(__always) public func w8(_ a: UInt32, _ v: Int) { w8(a, UInt8(truncatingIfNeeded: v)) }
    @inline(__always) public func w16(_ a: UInt32, _ v: Int) { w16(a, UInt16(truncatingIfNeeded: v)) }
    @inline(__always) public func w32(_ a: UInt32, _ v: Int) { w32(a, UInt32(truncatingIfNeeded: v)) }

    public func copy(from src: UInt32, to dst: UInt32, count: Int) {
        for i in 0..<count { w8(dst &+ UInt32(i), r8(src &+ UInt32(i))) }
    }
    public func fill(_ a: UInt32, count: Int, value: UInt8 = 0) {
        for i in 0..<count { w8(a &+ UInt32(i), value) }
    }
    public func load(_ data: [UInt8], at a: UInt32) {
        for (i, b) in data.enumerated() { w8(a &+ UInt32(i), b) }
    }
    public func slice(_ a: UInt32, _ count: Int) -> [UInt8] { (0..<count).map { r8(a &+ UInt32($0)) } }
    public func snapshot() -> [UInt8] { Array(UnsafeBufferPointer(start: bytes, count: Memory.size)) }
    public func restore(_ data: [UInt8]) { data.withUnsafeBufferPointer { bytes.update(from: $0.baseAddress!, count: min($0.count, Memory.size)) } }

    /// FNV-1a hash of a region, used for lockstep comparisons with the reference emulator.
    public func hash(_ a: UInt32, _ count: Int) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for i in 0..<count { h ^= UInt64(r8(a &+ UInt32(i))); h = h &* 0x100000001b3 }
        return h
    }
}
