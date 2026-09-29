import AVFoundation
import os

/// Streams Paula's output to the default device through a small ring buffer.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private var ring = [Float](repeating: 0, count: 48000 * 2)   // 0.5 s stereo
    private var readPos = 0, writePos = 0, fill = 0
    private var lock = os_unfair_lock()
    let sampleRate: Double = 48000
    var targetFill: Int { Int(sampleRate * 0.06) * 2 }         // ~60 ms latency

    init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            os_unfair_lock_lock(&self.lock)
            for i in 0..<Int(frameCount) {
                if self.fill >= 2 {
                    l[i] = self.ring[self.readPos]; r[i] = self.ring[self.readPos + 1]
                    self.readPos = (self.readPos + 2) % self.ring.count; self.fill -= 2
                } else { l[i] = 0; r[i] = 0 }
            }
            os_unfair_lock_unlock(&self.lock)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        do { try engine.start() } catch { NSLog("audio start failed: \(error)") }
    }

    /// Called from the emulation (main thread) with interleaved stereo samples.
    func push(_ s: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(&lock)
        // drift control: drop input when far ahead of target
        if fill > targetFill * 3 { os_unfair_lock_unlock(&lock); return }
        for v in s {
            ring[writePos] = v; writePos = (writePos + 1) % ring.count
            if fill < ring.count { fill += 1 } else { readPos = (readPos + 1) % ring.count }
        }
        os_unfair_lock_unlock(&lock)
    }

    func flush() { os_unfair_lock_lock(&lock); fill = 0; readPos = writePos; os_unfair_lock_unlock(&lock) }
}
