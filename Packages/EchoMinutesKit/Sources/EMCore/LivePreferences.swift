import Foundation

/// Settings ▸ Transcription ▸ Live transcript (EM-143). Read when a recording starts.
public enum LivePreferences {
    public static let enabledKey = "live.enabled"
    public static let modelKey = "live.model"
    public static let defaultModel = "base"
    /// Small models only: the live pass runs every ~2 s during the call.
    public static let models: [(variant: String, title: String)] = [
        ("base", "Base — fastest, lightest (≈145 MB)"),
        ("small", "Small — more accurate, more CPU (≈480 MB)"),
    ]

    public static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    public static var model: String {
        let m = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        return models.contains { $0.variant == m } ? m : defaultModel
    }
}
