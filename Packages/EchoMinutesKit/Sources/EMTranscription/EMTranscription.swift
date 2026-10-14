import EMCore
import Foundation

/// EMTranscription — TranscriptionEngine protocol, WhisperKit engine, VAD, diarization, model manager.
public enum EMTranscriptionModule {
    public static let name = "EMTranscription"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore"]
}
