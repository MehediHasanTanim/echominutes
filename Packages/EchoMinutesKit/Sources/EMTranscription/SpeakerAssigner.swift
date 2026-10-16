import EMCore
import Foundation

/// A stretch of audio attributed to one (anonymous) speaker by the diarizer, in seconds.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: Int
    public var start: Double
    public var end: Double
    public init(speaker: Int, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

/// Splits the call track's "Others" into Speaker 1…N (EM-091): each call segment goes to the diarizer speaker it
/// overlaps most (or the nearest turn within 1 s). Speakers are numbered by first appearance. With fewer than two
/// distinct speakers the result is `nil` and the caller keeps the single "Others" label.
public enum SpeakerAssigner {
    public static let nearestWithinMs = 1_000

    public struct Assignment: Sendable, Equatable {
        /// For each input segment: speaker number 1…N (nil = unknown → stays with the first/"Others" speaker).
        public var speakerOfSegment: [Int?]
        public var speakerCount: Int
    }

    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> Assignment? {
        guard !segments.isEmpty, !turns.isEmpty else { return nil }
        var raw: [Int?] = []
        for seg in segments {
            var best: (speaker: Int, overlap: Int)?
            for t in turns {
                let ts = Int(t.start * 1000), te = Int(t.end * 1000)
                let ov = min(seg.endMs, te) - max(seg.startMs, ts)
                if ov > 0, ov > (best?.overlap ?? 0) { best = (t.speaker, ov) }
            }
            if best == nil {
                // No overlap (timestamps drift): nearest turn edge within 1 s.
                let mid = (seg.startMs + seg.endMs) / 2
                let near = turns.map { t -> (Int, Int) in
                    let ts = Int(t.start * 1000), te = Int(t.end * 1000)
                    return (t.speaker, mid < ts ? ts - mid : (mid > te ? mid - te : 0))
                }.min { $0.1 < $1.1 }
                if let near, near.1 <= nearestWithinMs { best = (near.0, 0) }
            }
            raw.append(best?.speaker)
        }
        // Renumber by first appearance → 1…N.
        var order: [Int: Int] = [:]
        for s in raw.compactMap({ $0 }) where order[s] == nil { order[s] = order.count + 1 }
        guard order.count >= 2 else { return nil }
        return Assignment(speakerOfSegment: raw.map { $0.flatMap { order[$0] } }, speakerCount: order.count)
    }
}

/// Anonymous speaker separation of one track (16 kHz mono). Implemented with SpeakerKit (pyannote) on device.
public protocol SpeakerDiarizer: Sendable {
    func diarize(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn]
}
