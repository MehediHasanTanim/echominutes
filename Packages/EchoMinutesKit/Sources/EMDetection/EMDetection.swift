import EMCore
import Foundation

/// EMDetection — AudioProcessMonitor (process list + 1 s poll), AppWatcher, RulesEngine.
public enum EMDetectionModule {
    public static let name = "EMDetection"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore"]
}
