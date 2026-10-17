import Foundation

/// Decides which parts of a live pass are final (EM-142). Pure logic, no audio.
///
/// Each pass transcribes the audio from the last commit point to "now" (≤ ~15 s). A segment is committed when
///  * the same text appeared at the same place in the previous pass (two passes agree — "local agreement"), and
///  * it ends at least `settleSeconds` before the end of the audio (the speaker has moved on).
/// Everything after the first unstable segment stays tentative and is shown greyed out.
/// Two limits keep the window short: past `targetSeconds` all but the last segment are committed, past
/// `hardCapSeconds` everything is (Whisper only sees 30 s at a time).
public struct LiveWindow: Sendable {
    public static let settleSeconds = 1.5
    public static let targetSeconds = 15.0
    public static let hardCapSeconds = 26.0
    public static let matchToleranceSeconds = 1.0

    public struct Result: Sendable, Equatable {
        /// Final segments, times relative to the start of the pass's audio.
        public var committed: [RawSegment]
        /// Not final yet (shown greyed out).
        public var tentative: [RawSegment]
        /// Seconds to drop from the front of the audio buffer (end of the last committed segment).
        public var advance: Double
    }

    private(set) var previous: [RawSegment] = []

    public init() {}

    /// Forget the previous pass (after a gap / skipped audio).
    public mutating func reset() { previous = [] }

    public mutating func ingest(_ segments: [RawSegment], bufferSeconds: Double) -> Result {
        let segs = segments.filter { !HallucinationGuard.normalized($0.text).isEmpty }
        var k = 0
        while k < segs.count, k < previous.count,
              segs[k].end <= bufferSeconds - Self.settleSeconds,
              Self.same(segs[k], previous[k]) {
            k += 1
        }
        if bufferSeconds > Self.hardCapSeconds {
            k = segs.count
        } else if bufferSeconds > Self.targetSeconds, segs.count >= 2 {
            k = max(k, segs.count - 1)
        }
        let committed = Array(segs[..<k])
        let tentative = Array(segs[k...])
        var advance = committed.last.map { min(bufferSeconds, max(0, $0.end)) } ?? 0
        if segs.isEmpty, bufferSeconds > Self.targetSeconds {
            advance = bufferSeconds - 1                       // nothing intelligible — drop it, keep a little context
        } else if k == segs.count, bufferSeconds > Self.hardCapSeconds {
            advance = max(advance, bufferSeconds - 1)
        }
        previous = tentative.map { $0.shifted(by: -advance) }
        return Result(committed: committed, tentative: tentative, advance: advance)
    }

    static func same(_ a: RawSegment, _ b: RawSegment) -> Bool {
        abs(a.start - b.start) <= matchToleranceSeconds
            && HallucinationGuard.normalized(a.text) == HallucinationGuard.normalized(b.text)
    }
}
