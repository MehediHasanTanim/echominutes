import EMDetection
import Foundation

/// Detection settings kept in UserDefaults (per-app overrides live in the `app_rules` table).
public enum DetectionPreferences {
    public static let enabledKey = "detection.enabled"
    public static let privateHoursOnKey = "detection.privateHours.on"
    public static let privateHoursStartKey = "detection.privateHours.start"   // minutes since midnight
    public static let privateHoursEndKey = "detection.privateHours.end"

    /// Detect meetings in web browsers (Google Meet, Teams / Zoom web) — EM-153.
    public static let browserEnabledKey = "detection.browser.enabled"
    public static var browserEnabled: Bool { UserDefaults.standard.object(forKey: browserEnabledKey) as? Bool ?? true }

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    public static var privateHours: PrivateHours? {
        let d = UserDefaults.standard
        guard d.bool(forKey: privateHoursOnKey) else { return nil }
        let start = d.object(forKey: privateHoursStartKey) as? Int ?? 22 * 60
        let end = d.object(forKey: privateHoursEndKey) as? Int ?? 7 * 60
        return PrivateHours(startMinute: start, endMinute: end)
    }
}
