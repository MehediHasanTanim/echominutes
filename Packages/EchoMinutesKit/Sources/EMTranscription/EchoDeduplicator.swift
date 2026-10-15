import EMCore
import Foundation

/// Removes speaker echo from the mic transcript (EM-093). On speakers, the mic also hears the call audio
/// (spike S5: ~30 ms later, ~11 dB quieter), so Whisper transcribes the other side twice: once on the call
/// track (correct) and once on the mic track (echo). A mic segment is treated as echo when a call segment
///   * overlaps it in time (± `slack`, Whisper timestamps drift a few seconds between tracks), and
///   * contains most of its words (`containment` ≥ 0.6, order-insensitive, so partial/merged segments match).
/// The call-track segment is always kept; real speech by you never appears on the call track.
public enum EchoDeduplicator {
    public static let slackMs = 3_000
    public static let minContainment = 0.6

    public struct Result: Sendable {
        public var segments: [TranscriptSegment]
        public var removed: [TranscriptSegment]
    }

    public static func dedupe(_ segments: [TranscriptSegment]) -> Result {
        let system = segments.filter { $0.track == .system }.map { ($0, words($0.text)) }
        var kept: [TranscriptSegment] = [], removed: [TranscriptSegment] = []
        for seg in segments {
            guard seg.track == .mic else { kept.append(seg); continue }
            let mine = words(seg.text)
            guard !mine.isEmpty else { kept.append(seg); continue }
            // Words from all call segments overlapping this one (an echo may span two call segments).
            var nearby = Set<String>()
            for (s, w) in system where s.startMs - slackMs <= seg.endMs && seg.startMs <= s.endMs + slackMs {
                nearby.formUnion(w)
            }
            let shared = mine.filter { nearby.contains($0) }.count
            if Double(shared) / Double(mine.count) >= minContainment {
                removed.append(seg)
            } else {
                kept.append(seg)
            }
        }
        return Result(segments: kept, removed: removed)
    }

    /// Lowercased word list without punctuation ("EcoMinutes," → "ecominutes").
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }
}
