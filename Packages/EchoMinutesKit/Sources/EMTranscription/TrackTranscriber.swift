import EMCore
import Foundation

/// One audio track → cleaned segments on the session timeline (EM-084/085/086):
/// load 16 kHz → speech regions → transcribe each region → shift to absolute time → hallucination guard.
public struct TrackTranscriber: Sendable {
    public struct Output: Sendable {
        public var segments: [RawSegment]
        public var dropped: Int
        public var speechSeconds: Double
        public var audioSeconds: Double
    }

    let engine: TranscriptionEngine
    public init(engine: TranscriptionEngine) { self.engine = engine }

    public func transcribe(_ url: URL, options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let samples = try AudioLoader.load16kMono(url)
        return try await transcribe(samples: samples, options: options, progress: progress)
    }

    public func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let rate = AudioLoader.sampleRate
        let regions = SpeechRegionDetector.detect(samples, rate: rate)
        let total = max(1, regions.reduce(0) { $0 + ($1.end - $1.start) })
        var done = 0
        var raw: [RawSegment] = []
        for r in regions {
            try Task.checkCancellation()
            let len = r.end - r.start
            let base = done
            let offset = Double(r.start) / rate
            let segs = try await engine.transcribe(samples: Array(samples[r.start..<r.end]), options: options) { p in
                progress(Double(base) / Double(total) + p * Double(len) / Double(total))
            }
            let regionEnd = Double(r.end) / rate
            raw += segs.map { s in
                var x = s.shifted(by: offset)
                x.end = min(max(x.end, x.start), regionEnd)
                return x
            }
            done += len
            progress(Double(done) / Double(total))
        }
        let guarded = HallucinationGuard.filter(raw)
        if !guarded.dropped.isEmpty {
            Log.info(.stt, "Guard dropped \(guarded.dropped.count) segment(s): " +
                     guarded.dropped.prefix(5).map { "\($0.1.rawValue) \"\($0.0.text.prefix(30))\"" }.joined(separator: ", "))
        }
        return Output(segments: guarded.kept, dropped: guarded.dropped.count,
                      speechSeconds: Double(regions.reduce(0) { $0 + ($1.end - $1.start) }) / rate,
                      audioSeconds: Double(samples.count) / rate)
    }
}
