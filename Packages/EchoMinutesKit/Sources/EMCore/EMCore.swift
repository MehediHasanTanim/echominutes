import Foundation

/// EMCore — Models, IDs, errors, Clock protocol, shared utilities.
public enum EMCoreModule {
    public static let name = "EMCore"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = []
}

/// App-wide constants.
public enum EchoMinutes {
    public static let bundleIDPrefix = "com.tanimkabir.echominutes"
    public static let allModules = [
        "EMCore", "EMStorage", "EMDetection", "EMAudio", "EMSession",
        "EMTranscription", "EMSummarization", "EMJobs", "EMExport", "EMUI",
    ]
}
