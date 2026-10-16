import EMCore
import Foundation
@preconcurrency import SpeakerKit

/// On-device diarization with Argmax SpeakerKit (pyannote v4 Core ML), shipped with WhisperKit (EM-091).
/// Models (~tens of MB) are downloaded on first use into `<library>/Models`.
public final class CallSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    private let modelsDir: URL
    private let lock = NSLock()
    private var kit: SpeakerKit?

    public init(modelsDir: URL) { self.modelsDir = modelsDir }

    private func loaded() async throws -> SpeakerKit {
        if let k = lock.withLock({ kit }) { return k }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let t0 = Date()
        let config = PyannoteConfig(downloadBase: modelsDir.path, download: true, load: true, verbose: false, logLevel: .error)
        let k = try await SpeakerKit(config)
        lock.withLock { kit = k }
        Log.info(.stt, String(format: "Speaker models ready in %.1f s", Date().timeIntervalSince(t0)))
        return k
    }

    public func diarize(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        guard samples.count > 16_000 * 2 else { return [] }
        let kit = try await loaded()
        let result = try await kit.diarize(audioArray: samples, options: PyannoteDiarizationOptions()) { p in
            progress(p.fractionCompleted)
        }
        progress(1)
        let turns = result.segments.compactMap { s -> SpeakerTurn? in
            guard let id = s.speaker.speakerId else { return nil }
            return SpeakerTurn(speaker: id, start: Double(s.startTime), end: Double(s.endTime))
        }
        Log.info(.stt, "Diarization: \(result.speakerCount) speaker(s), \(turns.count) turn(s)")
        return turns
    }
}
