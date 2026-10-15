import Foundation

/// Energy-based speech detection (EM-085). Spike S3 showed WhisperKit's own VAD chunking drops real call speech,
/// so this one is deliberately conservative: an adaptive threshold just above the track's noise floor, generous
/// padding, and merging of short gaps. Its job is only to skip long silences (faster, fewer hallucinations).
public struct SpeechRegion: Sendable, Equatable {
    public var start: Int          // sample index (inclusive)
    public var end: Int            // sample index (exclusive)
    public var duration: Double { Double(end - start) / AudioLoader.sampleRate }
}

public enum SpeechRegionDetector {
    public static let frameSeconds = 0.03
    public static let padBefore = 0.4
    public static let padAfter = 0.6
    public static let mergeGap = 1.5
    public static let minSpeech = 0.25

    /// Threshold = noise floor (10th percentile of frame RMS) + 10 dB, clamped to −55…−40 dBFS.
    public static func threshold(frameDB: [Float]) -> Float {
        guard !frameDB.isEmpty else { return -45 }
        let sorted = frameDB.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return min(-40, max(-55, floor + 10))
    }

    public static func frameLevels(_ samples: [Float], rate: Double = AudioLoader.sampleRate) -> [Float] {
        let n = max(1, Int(rate * frameSeconds))
        var out: [Float] = []
        out.reserveCapacity(samples.count / n + 1)
        var i = 0
        samples.withUnsafeBufferPointer { p in
            while i < p.count {
                let end = min(p.count, i + n)
                var sum: Float = 0
                for k in i..<end { sum += p[k] * p[k] }
                let rms = (sum / Float(end - i)).squareRoot()
                out.append(rms > 0 ? 20 * log10(rms) : -120)
                i = end
            }
        }
        return out
    }

    public static func detect(_ samples: [Float], rate: Double = AudioLoader.sampleRate) -> [SpeechRegion] {
        let frames = frameLevels(samples, rate: rate)
        let thr = threshold(frameDB: frames)
        let frameLen = Int(rate * frameSeconds)
        // 1. Raw voiced runs (in frames)
        var runs: [(Int, Int)] = []
        var runStart: Int?
        for (i, db) in frames.enumerated() {
            if db > thr { if runStart == nil { runStart = i } }
            else if let s = runStart { runs.append((s, i)); runStart = nil }
        }
        if let s = runStart { runs.append((s, frames.count)) }

        // 2. Pad, clamp, merge gaps, drop blips
        let before = Int(padBefore * rate), after = Int(padAfter * rate), gap = Int(mergeGap * rate)
        var regions: [SpeechRegion] = []
        for (s, e) in runs {
            let voiced = Double(e - s) * frameSeconds
            var r = SpeechRegion(start: max(0, s * frameLen - before), end: min(samples.count, e * frameLen + after))
            if let last = regions.last, r.start - last.end <= gap {
                r.start = last.start
                regions.removeLast()
            } else if voiced < minSpeech {
                continue
            }
            regions.append(r)
        }
        return regions
    }
}
