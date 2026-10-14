import EMCore
import EMDetection
import EMAudio
import EMStorage
import Foundation

/// EMSession — SessionCoordinator state machine.
public enum EMSessionModule {
    public static let name = "EMSession"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore", "EMDetection", "EMAudio", "EMStorage"]
}
