import AppKit
import AVFoundation
import PlatoonCore

// [assist] S8 phase 2: HUD messages and full-screen texts spoken with AVSpeechSynthesizer, or as VoiceOver
// announcements while VoiceOver runs. Text is normalised (sentence case, "DID'NT" -> "didn't", "(Y/N)" -> "Y or N").
// Nothing is spoken while fast-forwarding; a backlog is cut to the newest message.

final class AssistSpeech {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    /// Tests: every spoken line (normalised text) is also appended here.
    var spokenLog: [String] = []
    var testSink: ((String) -> Void)?

    func install() {}

    private var enabled: Bool { Prefs.bool(AssistPrefs.speech) }

    func message(_ text: String, dropped: Bool) {
        guard enabled else { return }
        say(SpeechText.readable(text))
    }

    func screen(_ text: String) {
        guard enabled, Prefs.bool(AssistPrefs.speechScreens) else { return }
        say(SpeechText.readable(text))
    }

    func say(_ line: String) {
        guard !line.isEmpty else { return }
        if let h = AppServices.shared.host, h.isFastForwarding { return }
        spokenLog.append(line)
        if spokenLog.count > 200 { spokenLog.removeFirst(100) }
        if let t = testSink { t(line); return }
        if NSWorkspace.shared.isVoiceOverEnabled, let w = AppServices.shared.window {
            NSAccessibility.post(element: w, notification: .announcementRequested,
                                 userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        if synth.isSpeaking && pending >= 2 { synth.stopSpeaking(at: .word); pending = 0 }
        let u = AVSpeechUtterance(string: line)
        u.rate = Float(Prefs.double(AssistPrefs.speechRate))
        u.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
        pending += 1
        synth.speak(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self.map { $0.pending = max(0, $0.pending - 1) } }
    }

    func stop() { synth.stopSpeaking(at: .immediate); pending = 0 }
}
