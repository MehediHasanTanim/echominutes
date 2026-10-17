import Foundation

/// Which speech-to-text engine transcribes a meeting (EM-162…166).
public enum STTEngineChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case local
    case deepgram
    case assemblyAI = "assemblyai"
    case openAI = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "On this Mac (Whisper)"
        case .deepgram: "Deepgram (Nova-3)"
        case .assemblyAI: "AssemblyAI (Universal)"
        case .openAI: "OpenAI"
        }
    }

    public var isCloud: Bool { self != .local }

    /// Keychain account of the API key. OpenAI reuses the key from Settings ▸ Providers.
    public var keychainAccount: String? {
        switch self {
        case .local: nil
        case .deepgram: "stt.deepgram"
        case .assemblyAI: "stt.assemblyai"
        case .openAI: ProviderID.openAI.rawValue
        }
    }

    /// Engine family from a stored `Session.sttEngine` identifier ("deepgram:nova-3", "whisperkit:…").
    public static func from(identifier: String?) -> STTEngineChoice? {
        guard let id = identifier else { return nil }
        if id.hasPrefix("whisperkit") { return .local }
        return allCases.first { $0.isCloud && id.hasPrefix($0.rawValue) }
    }
}
