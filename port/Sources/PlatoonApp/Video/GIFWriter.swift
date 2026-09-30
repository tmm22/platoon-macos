import Foundation

// OWNER: [presentation]. Streaming animated-GIF encoder for M24 (exact Amiga colours, no dithering).
// Each frame gets its own local colour table (a Platoon frame has far fewer than 256 colours); only the rectangle
// that changed since the previous frame is stored, and unchanged pixels inside it are transparent, so files stay
// small. Frames identical to the previous one just extend its delay.

final class GIFWriter {
    let width: Int, height: Int
    private let handle: FileHandle
    private var previous: [UInt32]?
    /// The encoded frame waiting for its delay (known when the next different frame arrives).
    private var pending: (body: [UInt8], transparent: Int?, delay: Int)?
    private(set) var frameCount = 0
    private var closed = false

    init?(url: URL, width: Int, height: Int) {
        self.width = width; self.height = height
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        var head = [UInt8]("GIF89a".utf8)
        head += le16(width) + le16(height) + [0x00, 0x00, 0x00]              // no global colour table
        head += [0x21, 0xff, 0x0b] + [UInt8]("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]   // loop forever
        handle.write(Data(head))
    }

    /// Adds a frame (0x..RRGGBB pixels, width*height) shown for `delay` hundredths of a second.
    func add(_ px: [UInt32], delay: Int) {
        guard !closed, px.count >= width * height else { return }
        // changed rectangle
        var x0 = 0, y0 = 0, x1 = width - 1, y1 = height - 1
        if let prev = previous {
            x0 = width; y0 = height; x1 = -1; y1 = -1
            for y in 0..<height {
                let row = y * width
                var any = false
                for x in 0..<width where (px[row + x] ^ prev[row + x]) & 0xffffff != 0 {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    any = true
                }
                if any { if y < y0 { y0 = y }; y1 = y }
            }
            if x1 < 0 { pending?.delay += delay; return }        // identical frame
        }
        flushPending()
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        // palette of the rectangle; index 0 is reserved for "unchanged" (transparent) when there is a previous frame
        let useTransparency = previous != nil
        var map: [UInt32: UInt8] = [:]
        var palette: [UInt32] = useTransparency ? [0] : []
        var idx = [UInt8](repeating: 0, count: w * h)
        var overflow = false
        for y in 0..<h {
            let row = (y0 + y) * width + x0
            for x in 0..<w {
                let c = px[row + x] & 0xffffff
                if useTransparency, let prev = previous, prev[row + x] & 0xffffff == c { idx[y * w + x] = 0; continue }
                if let i = map[c] { idx[y * w + x] = i; continue }
                if palette.count < 256 {
                    map[c] = UInt8(palette.count); idx[y * w + x] = UInt8(palette.count); palette.append(c)
                } else { overflow = true; idx[y * w + x] = nearest(c, palette, from: useTransparency ? 1 : 0) }
            }
        }
        _ = overflow
        var bits = 1
        while (1 << bits) < max(2, palette.count) { bits += 1 }
        var body: [UInt8] = [0x2c] + le16(x0) + le16(y0) + le16(w) + le16(h) + [0x80 | UInt8(bits - 1)]
        for i in 0..<(1 << bits) {
            let c = i < palette.count ? palette[i] : 0
            body += [UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
        }
        let minCode = max(2, bits)
        body.append(UInt8(minCode))
        let data = GIFWriter.lzw(idx, litWidth: minCode)
        var o = 0
        while o < data.count {
            let n = min(255, data.count - o)
            body.append(UInt8(n)); body += data[o..<(o + n)]; o += n
        }
        body.append(0)
        pending = (body, useTransparency ? 0 : nil, delay)
        previous = px
        frameCount += 1
    }

    func finish() {
        guard !closed else { return }
        flushPending()
        handle.write(Data([0x3b]))
        try? handle.close()
        closed = true
    }

    private func flushPending() {
        guard let p = pending else { return }
        // graphic control extension: disposal 1 (keep), optional transparent index
        let packed: UInt8 = (1 << 2) | (p.transparent != nil ? 1 : 0)
        var out: [UInt8] = [0x21, 0xf9, 0x04, packed] + le16(max(2, p.delay)) + [UInt8(p.transparent ?? 0), 0x00]
        out += p.body
        handle.write(Data(out))
        pending = nil
    }

    private func nearest(_ c: UInt32, _ pal: [UInt32], from: Int) -> UInt8 {
        var best = from, bd = Int.max
        for i in from..<pal.count {
            let p = pal[i]
            let dr = Int((c >> 16) & 255) - Int((p >> 16) & 255), dg = Int((c >> 8) & 255) - Int((p >> 8) & 255), db = Int(c & 255) - Int(p & 255)
            let d = dr * dr + dg * dg + db * db
            if d < bd { bd = d; best = i }
        }
        return UInt8(best)
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

    /// GIF-flavoured LZW (LSB-first codes, clear/EOI, 12-bit maximum), following Go's compress/lzw writer.
    static func lzw(_ input: [UInt8], litWidth: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count / 2)
        var bits: UInt32 = 0, nBits: UInt32 = 0
        var width = UInt32(litWidth + 1)
        let clear = UInt32(1) << UInt32(litWidth), eof = clear + 1
        var hi = eof, overflow = clear << 1
        let maxCode: UInt32 = 4095
        let tableSize = 1 << 13, tableMask = UInt32(tableSize - 1)
        let invalid: UInt32 = 0
        var table = [UInt32](repeating: invalid, count: tableSize)
        func write(_ c: UInt32) {
            bits |= c << nBits; nBits += width
            while nBits >= 8 { out.append(UInt8(bits & 0xff)); bits >>= 8; nBits -= 8 }
        }
        /// Returns false when the table was reset (out of codes).
        func incHi() -> Bool {
            hi += 1
            if hi == overflow { width += 1; overflow <<= 1 }
            if hi == maxCode {
                write(clear)
                width = UInt32(litWidth + 1); hi = clear + 1; overflow = clear << 1
                for i in 0..<tableSize { table[i] = invalid }
                return false
            }
            return true
        }
        guard !input.isEmpty else { write(clear); write(eof); if nBits > 0 { out.append(UInt8(bits & 0xff)) }; return out }
        write(clear)
        var code = UInt32(input[0])
        var i = 1
        outer: while i < input.count {
            let literal = UInt32(input[i]); i += 1
            let key = code << 8 | literal
            var hash = (key >> 12 ^ key) & tableMask
            var h = hash, t = table[Int(h)]
            while t != invalid {
                if key == t >> 12 { code = t & maxCode; continue outer }
                h = (h + 1) & tableMask; t = table[Int(h)]
            }
            write(code)
            code = literal
            if !incHi() { continue }
            while table[Int(hash)] != invalid { hash = (hash + 1) & tableMask }
            table[Int(hash)] = (key << 12) | hi
        }
        write(code)
        _ = incHi()
        write(eof)
        if nBits > 0 { out.append(UInt8(bits & 0xff)) }
        return out
    }
}
