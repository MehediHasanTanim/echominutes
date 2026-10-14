import EMCore
import Foundation

/// EMAudio — Process-tap + mic capture in one aggregate device, ring buffers, chunk writer.
public enum EMAudioModule {
    public static let name = "EMAudio"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore"]
}
