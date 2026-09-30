import AppKit
import AVFoundation
import CoreMedia
import PlatoonCore

// OWNER: [presentation]. M24 gameplay video / GIF capture, host-only.
//
// Frames come from the emulated canvas at the start of every emulated frame (AppServices.onFrame, where the
// canvas holds the frame that was just completed), so a recording has exactly 50 frames per emulated second
// whatever the display does: fast-forward records at normal speed, pauses are cut out. Audio is Paula's output
// stream (tapped in front of the host's audio path, so fast-forward ducking / decimation doesn't affect it).
// Recordings show the plain game image (no CRT or upscaler filters, no overlays), nearest-neighbour scaled.

final class VideoRecorder {
    static let shared = VideoRecorder()
    enum Kind { case movie, gif
        var title: String { self == .movie ? "Video" : "GIF" } }

    private(set) var kind: Kind?
    private(set) var url: URL?
    private(set) var framesRecorded = 0
    var isRecording: Bool { kind != nil }
    var seconds: Double { Double(framesRecorded) / 50 }
    /// GIFs stop by themselves after this many seconds (they get large).
    static let gifLimit = 60.0

    private var movie: MovieWriter?
    private var gif: GIFWriter?
    private let gifQueue = DispatchQueue(label: "platoon.gif")
    private var crop = (x: 34, y: 20, w: 640, h: 256)
    private var gifScale = 1
    private var gifEvery = 2
    private var audioBuf: [Float] = []
    private weak var tappedMachine: Machine?
    private weak var tappedPaula: Paula?
    private var onStop: [(URL?, String?) -> Void] = []

    /// The folder recordings (and M24 screenshots) go to.
    static var folder: URL {
        if let d = ProcessInfo.processInfo.environment["PLATOON_RECORD_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let fm = FileManager.default
        switch Prefs.int(VideoKeys.recordFolder) {
        case 1: return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case 2: return fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Platoon", isDirectory: true)
        default: return fm.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Platoon", isDirectory: true)
        }
    }

    static func fileName(_ ext: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Platoon \(f.string(from: Date())).\(ext)"
    }

    /// Starts a recording; returns an error message on failure.
    @discardableResult func start(_ k: Kind, crop c: (x: Int, y: Int, w: Int, h: Int), sampleRate: Double) -> String? {
        guard kind == nil else { return "Already recording" }
        let dir = VideoRecorder.folder
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return error.localizedDescription }
        crop = c
        framesRecorded = 0
        audioBuf.removeAll()
        switch k {
        case .movie:
            let u = dir.appendingPathComponent(VideoRecorder.fileName("mov"))
            let scale = max(1, min(4, Prefs.int(VideoKeys.recordScale)))
            do {
                movie = try MovieWriter(url: u, lowWidth: c.w / 2, height: c.h, scale: scale, palAspect: Prefs.bool(VideoKeys.recordAspect), sampleRate: sampleRate)
            } catch { return "Could not start the recording: \(error.localizedDescription)" }
            url = u
        case .gif:
            let u = dir.appendingPathComponent(VideoRecorder.fileName("gif"))
            gifScale = max(1, min(2, Prefs.int(VideoKeys.gifScale)))
            gifEvery = Prefs.int(VideoKeys.gifRate) == 50 ? 1 : 2
            guard let g = GIFWriter(url: u, width: c.w / 2 * gifScale, height: c.h * gifScale) else { return "Could not create \(u.path)" }
            gif = g; url = u
        }
        kind = k
        return nil
    }

    /// Stops the recording; `done` gets the file (or an error) on the main thread when it is complete.
    func stop(_ done: ((URL?, String?) -> Void)? = nil) {
        guard let k = kind else { done?(nil, "Not recording"); return }
        kind = nil
        let u = url
        if let d = done { onStop.append(d) }
        let finish: (String?) -> Void = { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                let cbs = self.onStop; self.onStop.removeAll()
                cbs.forEach { $0(err == nil ? u : nil, err) }
            }
        }
        switch k {
        case .movie:
            let m = movie; movie = nil
            m?.finish(finish) ?? finish("no writer")
        case .gif:
            let g = gif; gif = nil
            gifQueue.async { g?.finish(); finish(nil) }
        }
    }

    /// Makes sure Paula's output of `machine` reaches the recorder (idempotent per machine; a reset or a loaded
    /// game makes a new Machine, VideoFX calls this every emulated frame while recording).
    func tapAudio(_ machine: Machine) {
        guard tappedMachine !== machine || tappedPaula !== machine.chip.paula else { return }
        tappedMachine = machine
        let paula = machine.chip.paula
        tappedPaula = paula
        let prev = paula.output
        paula.output = { [weak self] buf in
            if let self, self.kind == .movie { self.audioBuf.append(contentsOf: buf) }
            prev?(buf)
        }
    }

    /// One emulated frame (called from onFrame with the machine parked; the canvas holds the finished frame).
    func frame(_ chip: Chipset) {
        guard let k = kind else { return }
        switch k {
        case .movie:
            movie?.append(canvas: chip.canvas, crop: crop, audio: audioBuf)
            audioBuf.removeAll(keepingCapacity: true)
            framesRecorded += 1
        case .gif:
            framesRecorded += 1
            if framesRecorded % gifEvery != 0 { return }
            let s = gifScale, w = crop.w / 2, h = crop.h
            var px = [UInt32](repeating: 0, count: w * s * h * s)
            let cv = chip.canvas
            for y in 0..<(h * s) {
                let src = cv + (crop.y + y / s) * Chipset.canvasWidth + crop.x
                let row = y * w * s
                for x in 0..<(w * s) { px[row + x] = src[(x / s) * 2] }
            }
            let delay = 2 * gifEvery
            let g = gif
            gifQueue.async { g?.add(px, delay: delay) }
            if seconds >= VideoRecorder.gifLimit {
                stop { u, _ in AppServices.shared.toast(u != nil ? "GIF saved (\(Int(VideoRecorder.gifLimit)) s limit)" : "GIF failed") }
            }
        }
    }
}

/// AVAssetWriter back end: H.264 video at 50 fps (nearest-neighbour scaled, optional PAL pixel aspect flag) and
/// AAC audio.
final class MovieWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let scale: Int, width: Int, height: Int
    private let sampleRate: Double
    private var frameIndex: Int64 = 0
    private var samples: Int64 = 0
    private var started = false
    private var audioFormat: CMAudioFormatDescription?
    private(set) var dropped = 0

    init(url: URL, lowWidth: Int, height lh: Int, scale: Int, palAspect: Bool, sampleRate: Double) throws {
        self.scale = scale; width = lowWidth * scale; height = lh * scale; self.sampleRate = sampleRate
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var vs: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000 * scale, AVVideoExpectedSourceFrameRateKey: 50,
                AVVideoMaxKeyFrameIntervalKey: 100, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        if palAspect {
            vs[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: 16, AVVideoPixelAspectRatioVerticalSpacingKey: 15]
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw NSError(domain: "Platoon", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported output settings"]) }
        writer.add(video); writer.add(audio)
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &audioFormat)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Platoon", code: 2) }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    func append(canvas: UnsafeMutablePointer<UInt32>, crop: (x: Int, y: Int, w: Int, h: Int), audio a: [Float]) {
        guard started, writer.status == .writing else { return }
        // the encoder can be briefly busy (other load): wait up to ~40 ms rather than leave a gap in the video
        var waits = 0
        while !video.isReadyForMoreMediaData && waits < 40 { usleep(1000); waits += 1 }
        if video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            if let pb = pbOut {
                CVPixelBufferLockBaseAddress(pb, [])
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
                let bpr = CVPixelBufferGetBytesPerRow(pb) / 4
                let lw = crop.w / 2
                for ly in 0..<crop.h {
                    let src = canvas + (crop.y + ly) * Chipset.canvasWidth + crop.x
                    let d0 = base + ly * scale * bpr
                    var o = 0
                    for x in 0..<lw {
                        let p = src[x * 2]
                        for _ in 0..<scale { d0[o] = p; o += 1 }
                    }
                    if scale > 1 { for r in 1..<scale { (d0 + r * bpr).update(from: d0, count: width) } }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                if !adaptor.append(pb, withPresentationTime: CMTime(value: frameIndex, timescale: 50)) { dropped += 1 }
            }
        } else { dropped += 1 }
        frameIndex += 1
        if !a.isEmpty { appendAudio(a) }
    }

    private func appendAudio(_ a: [Float]) {
        guard let fmt = audioFormat else { return }
        let n = a.count / 2
        guard n > 0 else { return }
        let pts = CMTime(value: samples, timescale: CMTimeScale(sampleRate))
        samples += Int64(n)
        var waits = 0
        while !audio.isReadyForMoreMediaData && waits < 20 { usleep(1000); waits += 1 }
        guard audio.isReadyForMoreMediaData else { return }
        let bytes = n * 8
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr,
              let block = bb else { return }
        _ = a.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: n,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr,
              let s = sb else { return }
        audio.append(s)
    }

    func finish(_ done: @escaping (String?) -> Void) {
        guard started else { done("not started"); return }
        video.markAsFinished(); audio.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frameIndex, timescale: 50))
        let w = writer
        w.finishWriting { done(w.status == .completed ? nil : (w.error?.localizedDescription ?? "failed")) }
    }
}
