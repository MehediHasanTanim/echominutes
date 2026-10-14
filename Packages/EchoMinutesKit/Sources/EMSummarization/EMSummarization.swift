import EMCore
import Foundation

/// EMSummarization — LLMProvider protocol, provider adapters, templates, map-reduce, schema validation.
public enum EMSummarizationModule {
    public static let name = "EMSummarization"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore"]
}
