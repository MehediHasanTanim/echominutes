import Foundation

/// Removes Whisper's classic hallucinations (EM-086), using the confidence gate found in spike S3:
///  * decoded only at temperature ≥ 1.0 with compression ratio > 2.4 (all fallbacks used, repetitive)
///  * avg log-prob < −1.0, or no-speech probability > 0.6
///  * known filler phrases emitted over silence/music ("Продолжение следует…", "[Music]", "Thanks for watching")
///  * the same line repeated 3+ times in a row; in-segment loops ("the the the the …") are collapsed.
public enum HallucinationGuard {
    public enum Reason: String, Sendable { case lowConfidence, noSpeech, fallbackLoop, blacklisted, empty, repeated }

    public struct Result: Sendable {
        public var kept: [RawSegment]
        public var dropped: [(RawSegment, Reason)]
    }

    static let blacklist: [String] = [
        "продолжение следует", "thank you for watching", "thanks for watching", "please subscribe",
        "subtitles by", "subtitled by", "amara.org", "music playing", "[music]", "(music)", "[blank_audio]",
        "[silence]", "(silence)", "[no speech]", "♪",
    ]

    /// Whole-segment outputs Whisper emits on near-silence (the trailing "you" at the end of a call).
    static let exactHallucinations: Set<String> = ["you", "bye", "so", "uh", "um", "hmm"]

    public static func filter(_ segments: [RawSegment]) -> Result {
        var kept: [RawSegment] = [], dropped: [(RawSegment, Reason)] = []
        var repeatRun = 0
        for var s in segments {
            s.text = collapseLoops(s.text.trimmingCharacters(in: .whitespacesAndNewlines))
            let norm = normalized(s.text)
            if norm.isEmpty { dropped.append((s, .empty)); continue }
            if s.temperature >= 1.0 && s.compressionRatio > 2.4 { dropped.append((s, .fallbackLoop)); continue }
            if s.avgLogprob < -1.0 { dropped.append((s, .lowConfidence)); continue }
            if s.noSpeechProb > 0.6 { dropped.append((s, .noSpeech)); continue }
            if exactHallucinations.contains(norm) { dropped.append((s, .blacklisted)); continue }
            let lower = s.text.lowercased()
            if blacklist.contains(where: { lower.contains($0) }) && norm.split(separator: " ").count <= 6 {
                dropped.append((s, .blacklisted)); continue
            }
            if let last = kept.last, normalized(last.text) == norm {
                repeatRun += 1
                if repeatRun >= 2 { dropped.append((s, .repeated)); continue }
            } else {
                repeatRun = 0
            }
            kept.append(s)
        }
        return Result(kept: kept, dropped: dropped)
    }

    /// Lowercased, punctuation/brackets removed, whitespace collapsed.
    static func normalized(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }

    /// "a b c a b c a b c a b c" → "a b c" when a 1…6-word phrase repeats 4+ times consecutively.
    static func collapseLoops(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return text }
        var changed = true
        while changed {
            changed = false
            outer: for n in 1...6 where words.count >= n * 4 {
                var i = 0
                while i + n * 4 <= words.count {
                    let unit = words[i..<i + n].map { normalized($0) }
                    var reps = 1
                    while i + (reps + 1) * n <= words.count, words[i + reps * n..<i + (reps + 1) * n].map({ normalized($0) }) == unit { reps += 1 }
                    if reps >= 4 {
                        words.removeSubrange(i + n..<i + reps * n)
                        changed = true
                        break outer
                    }
                    i += 1
                }
            }
        }
        return words.joined(separator: " ")
    }
}
