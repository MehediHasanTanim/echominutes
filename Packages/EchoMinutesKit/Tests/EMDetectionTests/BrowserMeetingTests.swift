import EMAudio
import EMCore
import Foundation
import Testing
@testable import EMDetection

/// The rules file the app ships (so its title patterns are what's tested).
func shippedRules() throws -> DetectionRules {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return try DetectionRules.decode(Data(contentsOf: url.appendingPathComponent("Resources/DetectionRules.json")))
}

struct FakeTitles: WindowTitleSource {
    var list: [BrowserWindow]?
    func windows() -> [BrowserWindow]? { list }
}

func chromeAudio(mic: Bool, output: Bool = true, pid: pid_t = 501) -> AudioProcessInfo {
    AudioProcessInfo(objectID: 90, pid: pid, bundleID: "com.google.Chrome.helper", owningAppBundleID: "com.google.Chrome",
                     executable: "Google Chrome Helper", isRunningInput: mic, isRunningOutput: output)
}

func chromeWindow(_ title: String) -> BrowserWindow { BrowserWindow(pid: 500, bundleID: "com.google.Chrome", title: title) }

@Suite("Web meeting titles")
struct WebMeetingClassifierTests {
    func meetingID(_ title: String) throws -> String? {
        WebMeetingClassifier.meeting(forTitle: title, in: try shippedRules().webMeetings ?? [])?.id
    }

    @Test func recognisesMeetings() throws {
        #expect(try meetingID("Meet - abc-defg-hij - Google Chrome") == "meet")
        #expect(try meetingID("Meet – abc-defg-hij") == "meet")
        #expect(try meetingID("Sprint review - Google Meet - Google Chrome") == "meet")
        #expect(try meetingID("Weekly sync | Microsoft Teams - Microsoft Edge") == "teams-web")
        #expect(try meetingID("Zoom Meeting - Google Chrome") == "zoom-web")
        #expect(try meetingID("Zoom Workplace - Brave") == "zoom-web")
    }

    @Test func ignoresOtherPages() throws {
        #expect(try meetingID("YouTube - Google Chrome") == nil)
        #expect(try meetingID("Meetup: Swift Dhaka - Google Chrome") == nil)
        #expect(try meetingID("Meeting notes.docx - Word") == nil)
        #expect(try meetingID("Microsoft Teams pricing - Google Chrome") == nil)
    }

    @Test func sessionTitles() throws {
        let m = Dictionary(uniqueKeysWithValues: (try shippedRules().webMeetings ?? []).map { ($0.id, $0) })
        #expect(WebMeetingClassifier.sessionTitle(from: "Meet - abc-defg-hij - Google Chrome", meeting: m["meet"]!) == nil)
        #expect(WebMeetingClassifier.sessionTitle(from: "Sprint review - Google Meet - Google Chrome", meeting: m["meet"]!) == "Sprint review")
        #expect(WebMeetingClassifier.sessionTitle(from: "Weekly sync | Microsoft Teams - Microsoft Edge", meeting: m["teams-web"]!) == "Weekly sync")
        #expect(WebMeetingClassifier.sessionTitle(from: "(2) Design review | Microsoft Teams", meeting: m["teams-web"]!) == "Design review")
        #expect(WebMeetingClassifier.sessionTitle(from: "Zoom Meeting - Google Chrome", meeting: m["zoom-web"]!) == nil)
        #expect(WebMeetingClassifier.sessionTitle(from: "Meet - abc-defg-hij - Camera or microphone recording - Google Chrome",
                                                  meeting: m["meet"]!) == nil)
    }
}

@Suite("Browser meeting tracker")
struct BrowserMeetingTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func knownMeetingInChrome() throws {
        let rules = RuleSet(base: try shippedRules())
        var tracker = BrowserMeetingTracker()
        let snap = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0,
                                  titles: FakeTitles(list: [chromeWindow("Inbox - Gmail - Google Chrome"),
                                                            chromeWindow("Sprint review - Google Meet - Google Chrome")]))
        let meet = try #require(snap["meet"])
        #expect(meet.mic)
        #expect(meet.title == "Sprint review")
        #expect(meet.browserName == "Google Chrome")
        #expect(meet.bundlePrefixes == ["com.google.Chrome"])
        #expect(snap.count == 1)
    }

    @Test func unknownPageOrNoPermissionAsks() throws {
        let rules = RuleSet(base: try shippedRules())
        var a = BrowserMeetingTracker(), b = BrowserMeetingTracker()
        let noPermission = a.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0, titles: FakeTitles(list: nil))
        let otherPage = b.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0,
                                 titles: FakeTitles(list: [chromeWindow("Voice recorder - Google Chrome")]))
        #expect(noPermission[RuleSet.webOtherID]?.mic == true)
        #expect(otherPage[RuleSet.webOtherID]?.browserName == "Google Chrome")
        #expect(rules.rule(RuleSet.webOtherID)?.mode == .ask)
    }

    @Test func tabSwitchDoesNotEndTheMeeting() throws {
        let rules = RuleSet(base: try shippedRules())
        var tracker = BrowserMeetingTracker()
        _ = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0,
                           titles: FakeTitles(list: [chromeWindow("Meet - abc-defg-hij - Google Chrome")]))
        let later = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0 + 30,
                                   titles: FakeTitles(list: [chromeWindow("Jira board - Google Chrome")]))
        #expect(later["meet"]?.mic == true)
        #expect(later[RuleSet.webOtherID] == nil)
    }

    @Test func micOffKeepsReportingThenForgets() throws {
        let rules = RuleSet(base: try shippedRules())
        var tracker = BrowserMeetingTracker()
        let titles = FakeTitles(list: [chromeWindow("Meet - abc-defg-hij - Google Chrome")])
        _ = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0, titles: titles)
        let hungUp = tracker.update(processes: [chromeAudio(mic: false, output: true)], rules: rules, now: t0 + 10, titles: titles)
        #expect(hungUp["meet"]?.mic == false)                     // still there → the state machine's grace applies
        #expect(hungUp["meet"]?.output == true)
        let muchLater = tracker.update(processes: [chromeAudio(mic: false)], rules: rules,
                                       now: t0 + 10 + BrowserMeetingTracker.forgetAfter + 1, titles: titles)
        #expect(muchLater.isEmpty)
    }

    @Test func browserQuitEndsIt() throws {
        let rules = RuleSet(base: try shippedRules())
        var tracker = BrowserMeetingTracker()
        let titles = FakeTitles(list: [chromeWindow("Zoom Meeting - Google Chrome")])
        _ = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0, titles: titles)
        #expect(tracker.update(processes: [], rules: rules, now: t0 + 1, titles: titles).isEmpty)
    }

    @Test func soundWithoutMicIsNotACall() throws {
        let rules = RuleSet(base: try shippedRules())
        var tracker = BrowserMeetingTracker()
        let snap = tracker.update(processes: [chromeAudio(mic: false, output: true)], rules: rules, now: t0,
                                  titles: FakeTitles(list: [chromeWindow("Meet - abc-defg-hij - Google Chrome")]))
        #expect(snap.isEmpty)
    }

    @Test func rejoinOtherMeetingReclassifies() throws {
        let rules = RuleSet(base: try shippedRules())
        var tracker = BrowserMeetingTracker()
        _ = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0,
                           titles: FakeTitles(list: [chromeWindow("Meet - abc-defg-hij - Google Chrome")]))
        _ = tracker.update(processes: [chromeAudio(mic: false)], rules: rules, now: t0 + 5,
                           titles: FakeTitles(list: [chromeWindow("Zoom Meeting - Google Chrome")]))
        let snap = tracker.update(processes: [chromeAudio(mic: true)], rules: rules, now: t0 + 40,
                                  titles: FakeTitles(list: [chromeWindow("Zoom Meeting - Google Chrome")]))
        #expect(snap["zoom-web"]?.mic == true)
        #expect(snap["meet"] == nil)
    }

    @Test func browserRulesOnlyWhenEnabled() throws {
        let on = RuleSet(base: try shippedRules())
        let off = RuleSet(base: try shippedRules(), browserDetection: false)
        #expect(on.rule("meet")?.isWeb == true)
        #expect(off.rule("meet") == nil)
        // Browser processes are never mistaken for a desktop app.
        #expect(on.appID(bundleID: "com.google.Chrome.helper", owningBundleID: "com.google.Chrome") == nil)
        #expect(on.appID(bundleID: "com.microsoft.teams2", owningBundleID: "") == "teams")
    }

    @Test func overrideCanSilenceBrowserPrompt() throws {
        let rs = RuleSet(base: try shippedRules(), overrides: [RuleSet.webOtherID: RuleOverride(mode: .never)])
        #expect(rs.rule(RuleSet.webOtherID)?.mode == .never)
    }
}
