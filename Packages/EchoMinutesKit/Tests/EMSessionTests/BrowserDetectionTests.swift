import EMCore
import EMDetection
import Foundation
import Testing
@testable import EMSession

/// Native apps + two browsers + Google Meet (same shape as the shipped rules file).
func browserRules() throws -> DetectionRules {
    try DetectionRules.decode(Data("""
    {"version":2,"pollIntervalMs":1000,"ignoreBundlePrefixes":[],
     "apps":[{"id":"zoom","name":"Zoom","bundlePrefixes":["us.zoom"],"startSignal":"mic","debounceSec":5,"graceSec":15}],
     "browsers":[{"id":"chrome","name":"Google Chrome","bundlePrefixes":["com.google.Chrome"]},
                 {"id":"safari","name":"Safari","bundlePrefixes":["com.apple.Safari","com.apple.WebKit"]}],
     "webMeetings":[{"id":"meet","name":"Google Meet","titlePatterns":["Google Meet"],"debounceSec":5,"graceSec":20}]}
    """.utf8))
}

@Suite("Browser meetings — detection & recording")
struct BrowserDetectionTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func webMeetingRecordsAutomatically() throws {
        var m = MeetingStateMachine(rules: RuleSet(base: try browserRules()))
        var effects: [DetectionEffect] = []
        for s in 0..<7 { effects += m.observe(["meet": AppActivity(appID: "meet", mic: true, output: true)], now: t0 + Double(s)) }
        #expect(effects.contains(.beginRecording(appID: "meet", candidateSince: t0)))
        // Hang up: the browser keeps its audio process; mic off + no output for the 20 s grace ends it.
        for s in 7..<40 { effects += m.observe(["meet": AppActivity(appID: "meet", mic: false, output: false)], now: t0 + Double(s)) }
        #expect(effects.contains(.finalizeRecording(appID: "meet")))
    }

    @Test func unknownBrowserMicAsks() throws {
        var m = MeetingStateMachine(rules: RuleSet(base: try browserRules()))
        let effects = m.observe([RuleSet.webOtherID: AppActivity(appID: RuleSet.webOtherID, mic: true)], now: t0)
        #expect(effects.contains(.askUser(appID: RuleSet.webOtherID)))
    }

    @Test func capturesOnlyThatBrowserAndUsesTheTabTitle() async throws {
        let rec = FakeRecorder()
        let h = AutoRecordingHandler(recorder: rec, rules: RuleSet(base: try browserRules()), clock: ManualClock(start: t0))
        let snap: ActivitySnapshot = ["meet": AppActivity(appID: "meet", mic: true, output: true, title: "Sprint review",
                                                          browserName: "Google Chrome", bundlePrefixes: ["com.google.Chrome"])]
        await h.perform(.startCandidate(appID: "meet", preRoll: 10), snapshot: snap)
        await h.perform(.beginRecording(appID: "meet", candidateSince: t0), snapshot: snap)
        #expect(await rec.lastApp?.bundlePrefixes == ["com.google.Chrome"])      // not Safari / WebKit
        #expect(await rec.calls == ["candidate:meet:10", "title:Sprint review", "commit:meet", "title:Sprint review"])
    }

    @Test func browserPromptNamesTheBrowser() async throws {
        let rec = FakeRecorder()
        let h = AutoRecordingHandler(recorder: rec, rules: RuleSet(base: try browserRules()), clock: ManualClock(start: t0))
        let stream = h.events
        let snap: ActivitySnapshot = [RuleSet.webOtherID: AppActivity(appID: RuleSet.webOtherID, mic: true,
                                                                      browserName: "Safari", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit"])]
        await h.perform(.askUser(appID: RuleSet.webOtherID), snapshot: snap)
        var first: AutoRecordingEvent?
        for await e in stream { first = e; break }
        #expect(first == .ask(appID: RuleSet.webOtherID, appName: "Safari"))
        await h.perform(.beginRecording(appID: RuleSet.webOtherID, candidateSince: t0), snapshot: snap)
        #expect(await rec.lastApp?.name == "Safari")                             // session "Safari call"
    }

    @Test func nativeAppsUnaffected() async throws {
        let rec = FakeRecorder()
        let h = AutoRecordingHandler(recorder: rec, rules: RuleSet(base: try browserRules()), clock: ManualClock(start: t0))
        await h.perform(.beginRecording(appID: "zoom", candidateSince: t0),
                        snapshot: ["zoom": AppActivity(appID: "zoom", mic: true, output: true)])
        #expect(await rec.calls == ["start:zoom:auto"])
        #expect(await rec.lastApp?.bundlePrefixes == ["us.zoom"])
    }
}
