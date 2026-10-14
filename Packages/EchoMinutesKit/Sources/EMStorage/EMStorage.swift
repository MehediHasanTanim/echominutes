import EMCore
import Foundation

/// EMStorage — GRDB database, migrations, repositories, FileStore, KeychainStore.
public enum EMStorageModule {
    public static let name = "EMStorage"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore", "GRDB"]
}
