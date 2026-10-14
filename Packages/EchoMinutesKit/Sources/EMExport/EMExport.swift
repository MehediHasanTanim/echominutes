import EMCore
import Foundation

/// EMExport — Markdown / TXT / SRT / PDF / DOCX renderers.
public enum EMExportModule {
    public static let name = "EMExport"
    /// Modules this one depends on (kept in sync with Package.swift; checked by tests).
    public static let dependencies: [String] = ["EMCore"]
}
