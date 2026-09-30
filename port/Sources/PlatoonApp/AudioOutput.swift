import AVFoundation
import os
import PlatoonCore

/// Streams Paula's output to the default device through a small ring buffer (PlatoonCore.HostAudioStream:
/// original block-dropping drift control, or M22 dynamic rate control), and plays the optional user-supplied
/// replacement soundtrack (M25) on a player node of the same engine.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    let stream: HostAudioStream
    let sampleRate: Double = 48000
    /// Target latency (the ring fill the output aims for); default ~60 ms as before.
    var latency: Double {
        get { stream.latency }
        set { stream.latency = newValue }
    }
    var targetFill: Int { Int(sampleRate * latency) * 2 }

    init() {
        stream = HostAudioStream(rate: sampleRate, seconds: 1.0, mode: .legacy)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        node = AVAudioSourceNode(format: fmt) { [stream] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            stream.render(Int(frameCount), l, r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.attach(soundtrack)
        engine.connect(soundtrack, to: engine.mainMixerNode, format: fmt)
        do { try engine.start() } catch { NSLog("audio start failed: \(error)") }
        // M22: the engine stops when the output device or its format changes (headphones, AirPlay, sample rate);
        // restart it so the sound doesn't just vanish until the next launch.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.stream.flush()
            do { try self.engine.start() } catch { NSLog("audio restart failed: \(error)") }
            if self.soundtrackFile != nil { self.soundtrack.play() }
        }
    }
    private var configObserver: NSObjectProtocol?

    /// Called from the emulation (main thread) with interleaved stereo samples.
    func push(_ s: UnsafeBufferPointer<Float>) { stream.push(s) }

    /// As `push`, scaled by `gain` (fast-forward ducking).
    func push(_ s: UnsafeBufferPointer<Float>, gain: Float) {
        guard gain > 0 else { return }
        stream.push(s, gain: gain)
    }

    func flush() { stream.flush() }

    // MARK: M25 replacement soundtrack (user-supplied files; nothing is bundled)

    private let soundtrack = AVAudioPlayerNode()
    private var soundtrackFile: AVAudioFile?
    private var soundtrackLoop = false
    private var soundtrackToken = 0
    private(set) var soundtrackURL: URL?
    /// Player volume (0...1+), set every frame by the soundtrack controller.
    var soundtrackVolume: Float {
        get { soundtrack.volume }
        set { soundtrack.volume = newValue }
    }

    /// Starts `url` (looping unless `loop` is false). Returns false if the file can't be read.
    @discardableResult func playSoundtrack(_ url: URL, loop: Bool) -> Bool {
        stopSoundtrack()
        guard let f = try? AVAudioFile(forReading: url) else { NSLog("soundtrack: cannot read \(url.path)"); return false }
        soundtrackToken += 1
        let token = soundtrackToken
        engine.disconnectNodeOutput(soundtrack)
        engine.connect(soundtrack, to: engine.mainMixerNode, format: f.processingFormat)
        soundtrackFile = f; soundtrackLoop = loop; soundtrackURL = url
        schedule(token)
        if loop { schedule(token) }          // one segment ahead: gapless loop
        if !engine.isRunning { try? engine.start() }
        soundtrack.play()
        return true
    }

    private func schedule(_ token: Int) {
        guard let f = soundtrackFile, token == soundtrackToken else { return }
        soundtrack.scheduleFile(f, at: nil, completionCallbackType: .dataConsumed) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.soundtrackToken, self.soundtrackLoop else { return }
                self.schedule(token)
            }
        }
    }

    func stopSoundtrack() {
        soundtrackToken += 1
        soundtrack.stop()
        soundtrackFile = nil; soundtrackURL = nil
    }

    func pauseSoundtrack(_ paused: Bool) {
        guard soundtrackFile != nil else { return }
        if paused { soundtrack.pause() } else { soundtrack.play() }
    }
    var soundtrackPlaying: Bool { soundtrackFile != nil }

    // MARK: test capture (PLATOON_DEBUG_AUDIO_WAV: app-level audio tests record what the device is fed)

    private var recordFile: AVAudioFile?
    /// Records the engine's final mix (Paula stream + soundtrack, after the main mixer) to a WAV file.
    func startRecording(to url: URL) {
        stopRecording()
        let mixer = engine.mainMixerNode
        let fmt = mixer.outputFormat(forBus: 0)
        guard let f = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            NSLog("audio: cannot record to \(url.path)"); return
        }
        recordFile = f
        mixer.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            try? self?.recordFile?.write(from: buf)
        }
    }
    func stopRecording() {
        guard recordFile != nil else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        recordFile = nil
    }
}
