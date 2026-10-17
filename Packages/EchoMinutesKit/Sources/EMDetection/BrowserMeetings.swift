import CoreAudio
import CoreGraphics
import EMAudio
import EMCore
import Foundation

/// One normal on-screen or off-screen window (EM-150).
public struct BrowserWindow: Sendable, Equatable {
    public var pid: pid_t
    public var bundleID: String
    public var title: String
    public init(pid: pid_t, bundleID: String, title: String) { self.pid = pid; self.bundleID = bundleID; self.title = title }
}

/// Where window titles come from. Titles need Screen Recording permission; without it `windows()` is nil.
public protocol WindowTitleSource: Sendable {
    func windows() -> [BrowserWindow]?
}

/// Window titles via `CGWindowListCopyWindowInfo` (all Spaces, minimised windows too). Never triggers the
/// permission prompt: without Screen Recording access it returns nil and detection falls back to asking.
public struct SystemWindowTitles: WindowTitleSource {
    public init() {}

    /// Screen Recording access granted (window titles readable).
    public static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    public func windows() -> [BrowserWindow]? {
        guard Self.permitted else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var bundles: [pid_t: String] = [:]
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pidNumber = w[kCGWindowOwnerPID as String] as? NSNumber,
                  let title = w[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            let pid = pid_t(pidNumber.int32Value)
            let bundle = bundles[pid] ?? AudioProcesses.appBundleID(pid: pid) ?? ""
            bundles[pid] = bundle
            return BrowserWindow(pid: pid, bundleID: bundle, title: title)
        }
    }
}

/// Recognises meeting web apps from browser window titles (EM-152) and turns a title into a session title (EM-156).
public enum WebMeetingClassifier {
    public static func meeting(forTitle title: String, in meetings: [DetectionRules.WebMeeting]) -> DetectionRules.WebMeeting? {
        meetings.first { m in m.titlePatterns.contains { title.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } }
    }

    /// The first meeting window of `browser` (meeting order = priority), with its title.
    public static func classify(windows: [BrowserWindow], browser: DetectionRules.Browser,
                                meetings: [DetectionRules.WebMeeting]) -> (meeting: DetectionRules.WebMeeting, title: String)? {
        let mine = windows.filter { browser.matches(bundleID: $0.bundleID) }
        for m in meetings {
            if let w = mine.first(where: { meeting(forTitle: $0.title, in: [m]) != nil }) { return (m, w.title) }
        }
        return nil
    }

    /// Browser decorations removed from the end of a window title.
    static let browserSuffixes = [
        #"\s*[-–—]\s*(Audio playing|Camera or microphone recording|Microphone recording|Camera recording|Recording)\b"#,
        #"\s*[-–—]\s*(Google Chrome|Microsoft Edge|Brave|Mozilla Firefox|Firefox|Safari|Arc)\b.*$"#,
    ]

    /// A readable session title from a meeting window title, or nil when nothing meaningful is left
    /// ("Meet - abc-defg-hij - Google Chrome" → nil; "Weekly sync | Microsoft Teams" → "Weekly sync").
    public static func sessionTitle(from windowTitle: String, meeting: DetectionRules.WebMeeting) -> String? {
        var t = windowTitle
        for p in browserSuffixes + (meeting.stripPatterns ?? []) {
            t = t.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:·•"))
        t = t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ").trimmingCharacters(in: trimSet)
        return t.count >= 3 ? t : nil
    }
}

/// Turns browser audio activity into meeting activity (EM-152/154).
///
/// While a browser holds the microphone, its window titles decide which meeting it is (Meet, Teams web, Zoom
/// web) — or `RuleSet.webOtherID` when no title matches or titles aren't readable. The decision sticks while the
/// call lasts: switching tabs mid-call doesn't end the recording. It's reconsidered when the mic comes back
/// after being off, and forgotten two minutes after the mic went off.
public struct BrowserMeetingTracker: Sendable {
    struct Sticky: Sendable, Equatable {
        var meetingID: String
        var title: String?
        var micOffSince: Date?
    }

    public static let titleRefresh: TimeInterval = 2
    public static let forgetAfter: TimeInterval = 120

    private var sticky: [String: Sticky] = [:]                // by browser id
    private var cachedWindows: [BrowserWindow]?
    private var cachedAt = Date.distantPast

    public init() {}

    public mutating func update(processes: [AudioProcessInfo], rules: RuleSet, now: Date, titles: WindowTitleSource,
                                selfPID: pid_t = getpid()) -> ActivitySnapshot {
        let browsers = Self.browserActivity(processes, rules: rules, selfPID: selfPID)
        sticky = sticky.filter { browsers[$0.key] != nil }    // browser quit → its meeting ended

        var out: ActivitySnapshot = [:]
        for browser in rules.browsers {
            guard let a = browsers[browser.id] else { continue }
            var s = sticky[browser.id]
            if a.mic {
                if s == nil || s?.micOffSince != nil {
                    let found = classify(browser, rules: rules, now: now, titles: titles)
                    if s == nil || (found != nil && found?.meetingID != s?.meetingID) {
                        let new = found ?? Sticky(meetingID: RuleSet.webOtherID, title: nil)
                        if s?.meetingID != new.meetingID {
                            Log.info(.detection, "Browser mic: \(browser.name) → \(new.meetingID)\(new.title.map { " \"\($0)\"" } ?? "")")
                        }
                        s = new
                    }
                }
                s?.micOffSince = nil
            } else if var cur = s {
                cur.micOffSince = cur.micOffSince ?? now
                s = now.timeIntervalSince(cur.micOffSince!) > Self.forgetAfter ? nil : cur
            }
            sticky[browser.id] = s
            guard let cur = s, rules.rule(cur.meetingID) != nil else { continue }

            var m = out[cur.meetingID] ?? AppActivity(appID: cur.meetingID, mic: false, output: false)
            m.mic = m.mic || a.mic
            m.output = m.output || a.output
            m.pids += a.pids
            m.title = m.title ?? cur.title
            m.browserName = m.browserName ?? browser.name
            m.bundlePrefixes += browser.bundlePrefixes
            out[cur.meetingID] = m
        }
        return out
    }

    private mutating func classify(_ browser: DetectionRules.Browser, rules: RuleSet, now: Date,
                                   titles: WindowTitleSource) -> Sticky? {
        if now.timeIntervalSince(cachedAt) >= Self.titleRefresh {
            cachedWindows = titles.windows()
            cachedAt = now
        }
        guard let windows = cachedWindows,
              let found = WebMeetingClassifier.classify(windows: windows, browser: browser, meetings: rules.webMeetings)
        else { return nil }
        return Sticky(meetingID: found.meeting.id, title: WebMeetingClassifier.sessionTitle(from: found.title, meeting: found.meeting))
    }

    /// Audio activity per browser (all its processes, incl. helpers / WebKit GPU process).
    static func browserActivity(_ processes: [AudioProcessInfo], rules: RuleSet, selfPID: pid_t) -> [String: AppActivity] {
        var out: [String: AppActivity] = [:]
        for p in processes where p.pid != selfPID {
            if rules.ignoreBundlePrefixes.contains(where: { p.bundleID.hasPrefix($0) }) { continue }
            guard let b = rules.browsers.first(where: { $0.matches(bundleID: p.bundleID) || (!p.owningAppBundleID.isEmpty && $0.matches(bundleID: p.owningAppBundleID)) })
            else { continue }
            var a = out[b.id] ?? AppActivity(appID: b.id)
            a.mic = a.mic || p.isRunningInput
            a.output = a.output || p.isRunningOutput
            a.pids.append(p.pid)
            out[b.id] = a
        }
        return out
    }
}
