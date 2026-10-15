import EMCore
import EMStorage
import Foundation

/// EMJobs — Persistent job queue and job handlers.
public enum EMJobsModule {
    public static let name = "EMJobs"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore", "EMStorage", "EMTranscription"]
}
