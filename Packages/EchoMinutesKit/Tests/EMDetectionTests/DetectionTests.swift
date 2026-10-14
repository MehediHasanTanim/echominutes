import EMAudio
import EMCore
import Foundation
import Testing
@testable import EMDetection

func testRules() throws -> DetectionRules {
    try DetectionRules.decode(Data("""
    {"version":1,"pollIntervalMs":1000,"ignoreBundlePrefixes":["com.apple.CoreSpeech"],
     "apps":[
      {"id":"teams","name":"Microsoft Teams","bundlePrefixes":["com.microsoft.teams2"],"startSignal":"mic","debounceSec":5,"graceSec":15},
      {"id":"zoom","name":"Zoom","bundlePrefixes":["us.zoom"],"startSignal":"mic","debounceSec":5,"graceSec":15},
      {"id":"whatsapp","name":"WhatsApp","bundlePrefixes":["net.whatsapp.WhatsApp"],"startSignal":"mic","debounceSec":8,"graceSec":15}],
     "browsers":[]}
    """.utf8))
}

@Suite("RuleSet")
struct RuleSetTests {
    @Test func overridesReplaceDefaults() throws {
        let rs = RuleSet(base: try testRules(), overrides: ["whatsapp": RuleOverride(mode: .never), "zoom": RuleOverride(mode: .ask, debounceSec: 3)])
        #expect(rs.rule("teams")?.mode == .auto && rs.rule("teams")?.debounce == 5)
        #expect(rs.rule("whatsapp")?.mode == .never && rs.rule("whatsapp")?.debounce == 8)
        #expect(rs.rule("zoom")?.mode == .ask && rs.rule("zoom")?.debounce == 3 && rs.rule("zoom")?.grace == 15)
        #expect(rs.pollInterval == 1)
    }

    @Test func appMatchingUsesAudioOrOwningBundle() throws {
        let rs = RuleSet(base: try testRules())
        #expect(rs.appID(bundleID: "com.microsoft.teams2.helper", owningBundleID: "") == "teams")
        #expect(rs.appID(bundleID: "", owningBundleID: "net.whatsapp.WhatsApp") == "whatsapp")
        #expect(rs.appID(bundleID: "com.apple.CoreSpeech", owningBundleID: "") == nil)
        #expect(rs.appID(bundleID: "com.google.Chrome.helper", owningBundleID: "com.google.Chrome") == nil)
    }

    @Test(arguments: [(9 * 60, 17 * 60, 12 * 60, true), (9 * 60, 17 * 60, 8 * 60, false),
                      (22 * 60, 7 * 60, 23 * 60, true), (22 * 60, 7 * 60, 6 * 60, true), (22 * 60, 7 * 60, 12 * 60, false)])
    func privateHours(start: Int, end: Int, at: Int, expected: Bool) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: TimeInterval(at * 60))
        #expect(PrivateHours(startMinute: start, endMinute: end).contains(date, calendar: cal) == expected)
    }
}

@Suite("ActivityAggregator")
struct AggregatorTests {
    @Test func groupsProcessesPerAppAndIgnoresSelfAndSiri() throws {
        let rs = RuleSet(base: try testRules())
        let procs: [AudioProcessInfo] = [
            .init(objectID: 1, pid: 10, bundleID: "com.microsoft.teams2", owningAppBundleID: "com.microsoft.teams2", executable: "MSTeams", isRunningInput: true),
            .init(objectID: 2, pid: 11, bundleID: "com.microsoft.teams2.helper", owningAppBundleID: "com.microsoft.teams2", executable: "Helper", isRunningOutput: true),
            .init(objectID: 3, pid: 20, bundleID: "com.apple.CoreSpeech", owningAppBundleID: "", executable: "corespeechd", isRunningInput: true),
            .init(objectID: 4, pid: 30, bundleID: "us.zoom.xos", owningAppBundleID: "us.zoom.xos", executable: "zoom.us"),
            .init(objectID: 5, pid: 99, bundleID: "com.microsoft.teams2", owningAppBundleID: "", executable: "self", isRunningInput: true),
        ]
        let snap = ActivityAggregator.aggregate(procs, rules: rs, selfPID: 99)
        #expect(Set(snap.keys) == ["teams", "zoom"])
        #expect(snap["teams"] == AppActivity(appID: "teams", mic: true, output: true, pids: [10, 11]))
        #expect(snap["zoom"]?.mic == false && snap["zoom"]?.running == true)
    }
}
