import EMCore
import Foundation

public struct SessionGroup: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let title: String
    public let sessions: [Session]
}

/// Library sidebar grouping: Today / Yesterday / This week / Earlier (Feature Spec FR-LIB-01).
public enum SessionGrouping {
    public static func group(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> [SessionGroup] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!
        var buckets: [String: [Session]] = [:]
        for s in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            let key: String
            if s.startedAt >= today { key = "Today" }
            else if s.startedAt >= yesterday { key = "Yesterday" }
            else if s.startedAt >= weekAgo { key = "This week" }
            else { key = "Earlier" }
            buckets[key, default: []].append(s)
        }
        return ["Today", "Yesterday", "This week", "Earlier"].compactMap { k in buckets[k].map { SessionGroup(title: k, sessions: $0) } }
    }

    /// "12 min", "1 h 05 min", or "—" while recording.
    public static func durationText(_ s: Session) -> String {
        guard let d = s.duration else { return "—" }
        let m = Int(d / 60)
        return m >= 60 ? String(format: "%d h %02d min", m / 60, m % 60) : "\(max(m, 0)) min"
    }

    public static func appDisplayName(_ appID: String?) -> String {
        switch appID {
        case "teams": "Microsoft Teams"
        case "zoom": "Zoom"
        case "whatsapp": "WhatsApp"
        case "slack": "Slack"
        case "facetime": "FaceTime"
        case "webex": "Webex"
        case "manual": "Manual recording"
        case let other?: other.capitalized
        case nil: "Unknown app"
        }
    }

    public static func appSymbol(_ appID: String?) -> String {
        switch appID {
        case "teams": "person.3.fill"
        case "zoom": "video.fill"
        case "whatsapp": "phone.fill"
        case "manual": "mic.fill"
        default: "waveform"
        }
    }
}
