import Foundation

// S8 message log (owner: assist). Read-only: fed from the F2 `onMessage` observer (GameProbe), never touches the game.
//
// The original shows every clue as a one-line HUD message that fades after 25 ticks (or 1 tick when another one is
// queued behind it) and silently drops anything beyond four queued messages. The log keeps them all, marks the
// dropped ones, and folds messages that the game re-queues continuously (the trap-door prompt, the section-2 hint
// timer, the bridge hint at columns $45-$4b, KILLED IN ACTION repeats) into one entry with a repeat count.

public struct MessageLogEntry: Equatable, Codable {
    /// Machine frame of the first / latest occurrence.
    public var frame: UInt64
    public var lastFrame: UInt64
    /// Load section of the table (nil = kernel texts).
    public var section: Int?
    public var index: Int
    public var text: String
    /// The original dropped it (queue full) - the player never saw it.
    public var dropped: Bool
    /// How many times it was queued while folded into this entry (1 = once).
    public var count: Int

    /// Game time of the first occurrence, "mm:ss" (PAL frames).
    public var timeText: String { MessageLog.clock(frame) }
}

public final class MessageLog {
    public init(capacity: Int = 400) { self.capacity = capacity }

    public private(set) var entries: [MessageLogEntry] = []
    public var capacity: Int
    /// A message identical to one logged less than this many frames ago (since its last occurrence) is folded into
    /// that entry instead of being logged again (5 s).
    public var foldFrames: UInt64 = 250
    /// Incremented on every change (UI refresh).
    public private(set) var revision = 0

    /// Adds a message; returns the new entry, or nil when it was folded into an earlier one (or has no text).
    @discardableResult
    public func add(_ m: GameEvent.Message, frame: UInt64) -> MessageLogEntry? {
        let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // fold continuous re-queues: search the recent tail for the same message
        for i in entries.indices.reversed() {
            let e = entries[i]
            if frame &- e.lastFrame > foldFrames { break }
            if e.index == m.index && e.section == m.section && e.text == text {
                entries[i].lastFrame = frame
                entries[i].count += 1
                // it was seen after all if one of the repeats made it into the queue
                if !m.dropped { entries[i].dropped = false }
                revision += 1
                return nil
            }
        }
        let e = MessageLogEntry(frame: frame, lastFrame: frame, section: m.section, index: m.index, text: text,
                                dropped: m.dropped, count: 1)
        entries.append(e)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        revision += 1
        return e
    }

    public func clear() { entries.removeAll(); revision += 1 }

    /// Plain-text export ("mm:ss  TEXT  [dropped] (xN)").
    public func exportText() -> String {
        entries.map { e in
            var s = "\(e.timeText)  \(e.text)"
            if e.dropped { s += "  [not shown by the game]" }
            if e.count > 1 { s += "  (x\(e.count))" }
            return s
        }.joined(separator: "\n")
    }

    /// PAL frames -> "m:ss".
    public static func clock(_ frame: UInt64) -> String {
        let s = Int(frame / 50)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Text for speech synthesis and readable captions: the game's upper-case strings in sentence case, with the
/// 1988 spelling fixed ("DID'NT" -> "didn't") and the prompt shorthand spelled out ("(Y/N)" -> "Y or N").
public enum SpeechText {
    static let fixes: [(String, String)] = [
        ("DID'NT", "DIDN'T"), ("IT'S WAY", "ITS WAY"), ("(Y/N)?", "? Y or N."), ("Y/N", "Y or N"),
        ("!!", "!"), (" !", "!"), (" ?", "?"), ("&", "and"),
    ]

    /// Readable sentence-case version of a game text (keeps line structure as spaces).
    public static func readable(_ text: String) -> String {
        // lines of a text screen: a sentence break where a line doesn't end with punctuation
        var t = text.split(separator: "\n").map { l -> String in
            let x = l.trimmingCharacters(in: .whitespaces)
            return x.last.map { ".!?,:".contains($0) } == false ? x + "." : x
        }.joined(separator: " ")
        if let last = text.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces), let c = last.last,
           !".!?,:".contains(c), t.hasSuffix(".") { t.removeLast() }
        t = t.replacingOccurrences(of: "\u{232B}", with: " ").replacingOccurrences(of: "\u{21B5}", with: " ")
        for (a, b) in fixes { t = t.replacingOccurrences(of: a, with: b) }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespaces)
        // dot runs: 3+ = an ellipsis, 2 = a full stop
        t = t.replacingOccurrences(of: "\\.{3,}", with: "\u{2026}", options: .regularExpression)
        t = t.replacingOccurrences(of: "..", with: ".")
        t = t.replacingOccurrences(of: "\u{2026}", with: "...")
        return sentenceCase(t)
    }

    /// Lower-cases everything except the first letter of each sentence and the word "I"; keeps "VC", "Y", "N" and
    /// "OK" as they are.
    public static func sentenceCase(_ s: String) -> String {
        let keep: Set<String> = ["VC", "OK", "Y", "N", "I", "TV", "HQ"]
        var out = "", word = "", startOfSentence = true
        func flush() {
            guard !word.isEmpty else { return }
            let letters = word.filter { $0.isLetter }
            if keep.contains(letters) && (letters != "Y" && letters != "N" || word.count <= 2) {
                out += word
            } else if startOfSentence, let i = word.firstIndex(where: { $0.isLetter }) {
                out += word[..<i] + word[i...i].uppercased() + word[word.index(after: i)...].lowercased()
            } else {
                out += word.lowercased()
            }
            if word.first(where: { $0.isLetter }) != nil { startOfSentence = false }
            if let l = word.last, ".!?".contains(l) { startOfSentence = true }
            word = ""
        }
        for ch in s {
            if ch == " " { flush(); out.append(ch) } else { word.append(ch) }
        }
        flush()
        return out
    }
}
