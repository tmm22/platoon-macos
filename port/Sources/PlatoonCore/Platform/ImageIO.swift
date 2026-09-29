import Foundation
import zlib

/// Minimal PNG / WAV writers used by the headless runner and tests (no AppKit dependency).
public enum ImageIO {
    public static func png(width w: Int, height h: Int, rgb: (Int, Int) -> UInt32) -> Data {
        var raw = [UInt8](); raw.reserveCapacity((w * 3 + 1) * h)
        for y in 0..<h {
            raw.append(0)
            for x in 0..<w { let p = rgb(x, y); raw.append(UInt8((p >> 16) & 0xff)); raw.append(UInt8((p >> 8) & 0xff)); raw.append(UInt8(p & 0xff)) }
        }
        var clen = compressBound(uLong(raw.count))
        var comp = [UInt8](repeating: 0, count: Int(clen))
        _ = compress2(&comp, &clen, raw, uLong(raw.count), 6)
        comp.removeLast(comp.count - Int(clen))
        var out = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        func chunk(_ type: String, _ d: [UInt8]) {
            var len = UInt32(d.count).bigEndian; out.append(Data(bytes: &len, count: 4))
            let t = Array(type.utf8); out.append(contentsOf: t); out.append(contentsOf: d)
            var crc = crc32(0, t, 4); crc = crc32(crc, d, uInt(d.count))
            var c = UInt32(crc).bigEndian; out.append(Data(bytes: &c, count: 4))
        }
        let ihdr: [UInt8] = [UInt8(w >> 24), UInt8((w >> 16) & 0xff), UInt8((w >> 8) & 0xff), UInt8(w & 0xff),
                             UInt8(h >> 24), UInt8((h >> 16) & 0xff), UInt8((h >> 8) & 0xff), UInt8(h & 0xff), 8, 2, 0, 0, 0]
        chunk("IHDR", ihdr); chunk("IDAT", comp); chunk("IEND", [])
        return out
    }

    /// Canvas (768 hires wide) -> 384x290 lowres PNG, same framing as tools/amiga/emu screenshots.
    public static func canvasPNG(_ chip: Chipset) -> Data {
        png(width: Chipset.canvasWidth / 2, height: Chipset.canvasHeight) { x, y in chip.canvas[y * Chipset.canvasWidth + x * 2] }
    }

    public final class WAVWriter {
        let handle: FileHandle; var frames: UInt32 = 0; let rate: UInt32
        public init?(path: String, sampleRate: Int) {
            FileManager.default.createFile(atPath: path, contents: Data(count: 44))
            guard let h = FileHandle(forWritingAtPath: path) else { return nil }
            handle = h; rate = UInt32(sampleRate); h.seek(toFileOffset: 44)
        }
        public func write(_ s: UnsafeBufferPointer<Float>) {
            var d = Data(capacity: s.count * 2)
            for v in s { var i = Int16(max(-32768, min(32767, v * 32767))).littleEndian; d.append(Data(bytes: &i, count: 2)) }
            handle.write(d); frames += UInt32(s.count / 2)
        }
        public func close() {
            var h = Data()
            func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
            func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
            h.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 4); h.append(contentsOf: Array("WAVEfmt ".utf8))
            u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
            h.append(contentsOf: Array("data".utf8)); u32(frames * 4)
            handle.seek(toFileOffset: 0); handle.write(h); handle.closeFile()
        }
    }
}
