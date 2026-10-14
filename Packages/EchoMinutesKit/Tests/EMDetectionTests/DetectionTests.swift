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
        let teams = try #require(rs.rule("teams"))
        let whatsapp = try #require(rs.rule("whatsapp"))
        let zoom = try #require(rs.rule("zoom"))
        #expect(teams.mode == .auto)
        #expect(teams.debounce == 5)
        #expect(whatsapp.mode == .never)
        #expect(whatsapp.debounce == 8)
        #expect(zoom.mode == .ask)
        #expect(zoom.debounce == 3)
        #expect(zoom.grace == 15)
        #expect(rs.pollInterval == 1)
    }

    @Test func appMatchingUsesAudioOrOwningBundle() throws {
        let rs = RuleSet(base: try testRules())
        #expect(rs.appID(bundleID: "com.microsoft.teams2.helper", owningBundleID: "") == "teams")
        #expect(rs.appID(bundleID: "", owningBundleID: "net.whatsapp.WhatsApp") == "whatsapp")
        #expect(rs.appID(bundleID: "com.apple.CoreSpeech", owningBundleID: "") == nil)
        #expect(rs.appID(bundleID: "com.google.Chrome.helper", owningBundleID: "com.google.Chrome") == nil)
    }

    struct PHCase: Sendable, CustomTestStringConvertible {
        let start: Int, end: Int, at: Int, expected: Bool
        var testDescription: String { "\(start)-\(end) @\(at) → \(expected)" }
    }
    static let phCases: [PHCase] = [
        PHCase(start: 540, end: 1020, at: 720, expected: true),
        PHCase(start: 540, end: 1020, at: 480, expected: false),
        PHCase(start: 1320, end: 420, at: 1380, expected: true),
        PHCase(start: 1320, end: 420, at: 360, expected: true),
        PHCase(start: 1320, end: 420, at: 720, expected: false),
    ]

    @Test(arguments: phCases)
    func privateHours(_ c: PHCase) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: TimeInterval(c.at * 60))
        let hours = PrivateHours(startMinute: c.start, endMinute: c.end)
        #expect(hours.contains(date, calendar: cal) == c.expected)
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
        #expect(snap["zoom"]?.mic == false)
        #expect(snap["zoom"]?.running == true)
    }
}
