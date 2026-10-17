import Foundation

/// Settings ▸ Recording. Read at the moment a recording (or transcription) starts.
public enum RecordingPreferences {
    public static let includeMicKey = "recording.includeMic"
    public static let micDeviceUIDKey = "recording.micDeviceUID"
    public static let bitRateKey = "recording.bitRate"
    public static let echoDedupKey = "recording.echoDedup"

    public static let defaultBitRate = 64_000
    public static let bitRates = [48_000, 64_000, 96_000, 128_000]

    /// Record your own microphone alongside the call audio.
    public static var includeMic: Bool { UserDefaults.standard.object(forKey: includeMicKey) as? Bool ?? true }
    /// Core Audio UID of the chosen input device; nil = system default.
    public static var micDeviceUID: String? {
        guard let s = UserDefaults.standard.string(forKey: micDeviceUIDKey), !s.isEmpty else { return nil }
        return s
    }
    /// AAC bit rate for every track (mic, call, mix).
    public static var bitRate: Int {
        let v = UserDefaults.standard.integer(forKey: bitRateKey)
        return bitRates.contains(v) ? v : defaultBitRate
    }
    /// Drop mic segments that repeat the call audio (speakers instead of headphones).
    public static var echoDedup: Bool { UserDefaults.standard.object(forKey: echoDedupKey) as? Bool ?? true }

    /// Rough size of one track per hour of recording.
    public static func megabytesPerHour(_ bitRate: Int) -> Int { Int((Double(bitRate) / 8 * 3600 / 1_000_000).rounded()) }
}
