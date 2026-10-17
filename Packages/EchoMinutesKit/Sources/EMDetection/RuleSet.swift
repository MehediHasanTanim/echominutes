import EMCore
import Foundation

/// User override for one app (mapped from Settings / `app_rules`).
public struct RuleOverride: Sendable, Equatable {
    public var mode: RecordingMode
    public var debounceSec: Double?
    public var graceSec: Double?
    public init(mode: RecordingMode = .auto, debounceSec: Double? = nil, graceSec: Double? = nil) {
        self.mode = mode; self.debounceSec = debounceSec; self.graceSec = graceSec
    }
}

/// Daily window in which nothing is auto-recorded (Feature Spec FR-DET-08). Minutes since midnight; may wrap midnight.
public struct PrivateHours: Sendable, Equatable {
    public var startMinute: Int
    public var endMinute: Int
    public init(startMinute: Int, endMinute: Int) { self.startMinute = startMinute; self.endMinute = endMinute }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinute == endMinute { return false }
        return startMinute < endMinute ? (m >= startMinute && m < endMinute) : (m >= startMinute || m < endMinute)
    }
}

/// One watched app with its effective settings.
public struct EffectiveRule: Sendable, Equatable, Identifiable {
    public var app: DetectionRules.App
    public var mode: RecordingMode
    public var debounce: TimeInterval
    public var grace: TimeInterval
    /// A meeting inside a web browser (EM-153) rather than a desktop app.
    public var isWeb: Bool = false
    public var id: String { app.id }
}

/// Bundled DetectionRules.json + user overrides + private hours (EM-060, EM-064).
public struct RuleSet: Sendable, Equatable {
    public var rules: [EffectiveRule]
    public var ignoreBundlePrefixes: [String]
    public var pollInterval: TimeInterval
    public var privateHours: PrivateHours?
    /// If mic is off but the app keeps producing output (e.g. Teams helper after a call), end after this long.
    public var micOffMaxWhileOutput: TimeInterval
    /// How long an "Ask first" prompt waits before treating it as declined.
    public var askTimeout: TimeInterval
    /// Browser meetings (EM-150…157).
    public var browserDetection: Bool
    public var browsers: [DetectionRules.Browser]
    public var webMeetings: [DetectionRules.WebMeeting]

    /// Rule id for a browser using the mic on a page that isn't a known meeting ("Browser is using mic — record?").
    public static let webOtherID = "browser"

    public init(base: DetectionRules, overrides: [String: RuleOverride] = [:], privateHours: PrivateHours? = nil,
                browserDetection: Bool = true, micOffMaxWhileOutput: TimeInterval = 60, askTimeout: TimeInterval = 20) {
        rules = base.apps.map { app in
            let o = overrides[app.id]
            return EffectiveRule(app: app, mode: o?.mode ?? .auto,
                                 debounce: o?.debounceSec ?? app.debounceSec, grace: o?.graceSec ?? app.graceSec)
        }
        browsers = base.browsers
        webMeetings = base.webMeetings ?? []
        self.browserDetection = browserDetection && !browsers.isEmpty
        if self.browserDetection {
            let prefixes = browsers.flatMap(\.bundlePrefixes)
            let other = DetectionRules.WebMeeting(id: Self.webOtherID, name: "Browser call", titlePatterns: [], debounceSec: 5, graceSec: 20)
            for m in webMeetings + [other] {
                let app = DetectionRules.App(id: m.id, name: m.name, bundlePrefixes: prefixes, startSignal: "mic",
                                             debounceSec: m.debounceSec, graceSec: m.graceSec, notes: "browser")
                let o = overrides[m.id]
                rules.append(EffectiveRule(app: app, mode: o?.mode ?? (m.id == Self.webOtherID ? .ask : .auto),
                                           debounce: o?.debounceSec ?? m.debounceSec, grace: o?.graceSec ?? m.graceSec, isWeb: true))
            }
        }
        ignoreBundlePrefixes = base.ignoreBundlePrefixes
        pollInterval = Double(base.pollIntervalMs) / 1000
        self.privateHours = privateHours
        self.micOffMaxWhileOutput = micOffMaxWhileOutput
        self.askTimeout = askTimeout
    }

    public func rule(_ appID: String) -> EffectiveRule? { rules.first { $0.app.id == appID } }

    /// The watched app an audio process belongs to (bundle prefix on audio or owning-app bundle ID).
    public func appID(bundleID: String, owningBundleID: String) -> String? {
        for id in [bundleID, owningBundleID] where !id.isEmpty {
            if ignoreBundlePrefixes.contains(where: { id.hasPrefix($0) }) { return nil }
            if let r = rules.first(where: { !$0.isWeb && $0.app.matches(bundleID: id) }) { return r.app.id }
        }
        return nil
    }
}
