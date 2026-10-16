import EMCore
import Foundation

/// User-facing transcription settings (Settings ▸ Transcription, EM-087).
public struct TranscriptionSettings: Sendable, Equatable {
    /// WhisperKit variant, e.g. "large-v3-v20240930_turbo".
    public var model: String
    /// Forced language code ("en", "bn", …). Spike S3: auto-detect is unreliable on call audio, so it is always forced.
    public var language: String
    /// Names, jargon, acronyms — fed to the decoder as a prompt so they are spelled correctly.
    public var vocabulary: [String]
    public var autoTranscribe: Bool
    /// Split the call track into Speaker 1…N (EM-091).
    public var identifySpeakers: Bool
    /// Shown instead of "Me" (Settings ▸ General).
    public var myName: String

    public init(model: String = STTModelCatalog.defaultVariant, language: String = "en", vocabulary: [String] = [],
                autoTranscribe: Bool = true, identifySpeakers: Bool = true, myName: String = "") {
        self.model = model; self.language = language; self.vocabulary = vocabulary; self.autoTranscribe = autoTranscribe
        self.identifySpeakers = identifySpeakers; self.myName = myName
    }
}

/// Options for one transcription call (EM-082).
public struct STTOptions: Sendable, Equatable {
    public var language: String
    public var vocabulary: [String]
    public init(language: String, vocabulary: [String] = []) { self.language = language; self.vocabulary = vocabulary }
}

/// One decoded segment, times in seconds relative to the samples passed in, plus decoder confidence signals.
public struct RawSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var avgLogprob: Double
    public var noSpeechProb: Double
    public var compressionRatio: Double
    public var temperature: Double

    public init(start: Double, end: Double, text: String, avgLogprob: Double = -0.3, noSpeechProb: Double = 0.05,
                compressionRatio: Double = 1.3, temperature: Double = 0) {
        self.start = start; self.end = end; self.text = text; self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb; self.compressionRatio = compressionRatio; self.temperature = temperature
    }

    public func shifted(by seconds: Double) -> RawSegment {
        var s = self; s.start += seconds; s.end += seconds; return s
    }
}

/// What a model is doing before it can transcribe (shown in the UI).
public enum EngineStatus: Sendable, Equatable {
    case downloading(fraction: Double)
    case loading            // first load: Core ML specialisation ("Optimizing model for this Mac…")
    case ready
}

/// Pluggable speech-to-text engine (WhisperKit now; cloud engines later). Input is 16 kHz mono Float32.
public protocol TranscriptionEngine: Sendable {
    var identifier: String { get }
    /// Downloads (first use) and loads the model. Cheap when already loaded.
    func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws
    /// `progress` is 0…1 within these samples. Must honour task cancellation.
    func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment]
}

public enum TranscriptionError: Error, LocalizedError, Sendable, Equatable {
    case modelUnavailable(String)
    case audioUnreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let m): "Transcription model unavailable: \(m)"
        case .audioUnreadable(let f): "Couldn't read audio \(f)"
        case .cancelled: "Transcription cancelled"
        }
    }
}
