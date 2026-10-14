import Foundation
import Testing
@testable import EMCore

@Suite("Models")
struct ModelsTests {
    @Test func sessionIDRoundTrip() throws {
        let id = SessionID()
        #expect(SessionID(string: id.description) == id)
        #expect(SessionID(string: "not-a-uuid") == nil)
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(SessionID.self, from: data) == id)
    }

    @Test func statusFlags() {
        #expect(SessionStatus.recording.isCapturing)
        #expect(!SessionStatus.ready.isCapturing)
        #expect(Set(SessionStatus.allCases.filter(\.needsRecovery)) == [.recording, .paused, .finalizing])
    }

    @Test func sessionDuration() {
        var s = Session(title: "Stand-up", sourceAppID: "teams", startedAt: Date(timeIntervalSince1970: 0))
        #expect(s.duration == nil)
        s.endedAt = Date(timeIntervalSince1970: 90)
        #expect(s.duration == 90)
        #expect(s.status == .recording && s.tags.isEmpty && !s.titleIsUserEdited)
    }

    @Test(arguments: [(0, "00:00"), (65_000, "01:05"), (3_599_999, "59:59"), (3_600_000, "1:00:00"), (-5, "00:00")])
    func timestampFormat(ms: Int, expected: String) {
        #expect(TranscriptSegment.format(ms: ms) == expected)
    }

    @Test func speakerName() {
        let sid = SessionID()
        #expect(Speaker(sessionID: sid, label: "Speaker 1").name == "Speaker 1")
        #expect(Speaker(sessionID: sid, label: "Speaker 1", displayName: "Rahim").name == "Rahim")
        #expect(Speaker(sessionID: sid, label: "Speaker 1", displayName: "").name == "Speaker 1")
    }

    @Test func summaryContentDecodesSnakeCaseSchema() throws {
        let json = """
        {"title":"Sprint planning","tldr":"Planned S3.","key_points":["capture"],"decisions":["one aggregate device"],
         "action_items":[{"task":"Write ring buffer","owner":"Tanim","due":"Fri","timestamp":"12:30"},{"task":"Review","owner":null}],
         "open_questions":[],"next_steps":["S4"]}
        """
        let c = try JSONDecoder().decode(SummaryContent.self, from: Data(json.utf8))
        #expect(c.keyPoints == ["capture"])
        #expect(c.actionItems.count == 2)
        #expect(c.actionItems[0].owner == "Tanim" && c.actionItems[1].owner == nil)
        let re = try JSONDecoder().decode(SummaryContent.self, from: JSONEncoder().encode(c))
        #expect(re == c)
    }

    @Test func providers() {
        #expect(ProviderID.ollama.isLocal && !ProviderID.ollama.requiresAPIKey)
        #expect(ProviderID.anthropic.requiresAPIKey)
        #expect(ProviderID(rawValue: "azure-openai") == .azureOpenAI)
        #expect(Set(ProviderID.allCases.map(\.displayName)).count == ProviderID.allCases.count)
    }

    @Test func errorMessagesAreUserFacing() {
        let e = EMError.provider(.anthropic, .invalidKey)
        #expect(e.localizedDescription.contains("Anthropic"))
        #expect(e.localizedDescription.contains("Settings"))
    }
}

@Suite("DetectionRules")
struct DetectionRulesTests {
    /// Decodes the real repo file so the JSON and the model can't drift apart.
    static func repoRules() throws -> DetectionRules {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return try DetectionRules.decode(Data(contentsOf: url.appendingPathComponent("Resources/DetectionRules.json")))
    }

    @Test func decodesRepoFile() throws {
        let r = try Self.repoRules()
        #expect(r.pollIntervalMs == 1000)
        #expect(Set(r.apps.map(\.id)).isSuperset(of: ["teams", "zoom", "whatsapp"]))
    }

    @Test(arguments: [
        ("com.microsoft.teams2", "teams"), ("com.microsoft.teams2.helper", "teams"), ("com.microsoft.teams2.modulehost", "teams"),
        ("us.zoom.xos", "zoom"), ("us.zoom.caphost", "zoom"),
        ("net.whatsapp.WhatsApp", "whatsapp"), ("net.whatsapp.WhatsApp.ServiceExtension", "whatsapp"),
    ])
    func matchesVerifiedProcesses(bundleID: String, appID: String) throws {
        #expect(try Self.repoRules().app(forBundleID: bundleID)?.id == appID)
    }

    @Test func ignoresSiriAndUnknown() throws {
        let r = try Self.repoRules()
        #expect(r.app(forBundleID: "com.apple.CoreSpeech") == nil)
        #expect(r.app(forBundleID: "com.google.Chrome.helper") == nil)
    }
}

@Suite("ManualClock")
struct ManualClockTests {
    @Test func sleepResumesOnlyAfterDeadline() async throws {
        let clock = ManualClock()
        let start = clock.now
        let task = Task { try await clock.sleep(for: .seconds(5)); return clock.now }
        while clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .seconds(4))
        #expect(clock.pendingSleepers == 1)
        clock.advance(by: .seconds(1))
        let woke = try await task.value
        #expect(woke.timeIntervalSince(start) == 5)
        #expect(clock.pendingSleepers == 0)
    }

    @Test func zeroSleepReturnsImmediately() async throws {
        let clock = ManualClock()
        try await clock.sleep(for: .zero)
        #expect(clock.pendingSleepers == 0)
    }

    @Test func durationSeconds() {
        #expect(Duration.milliseconds(1500).seconds == 1.5)
    }
}

@Suite("Redactor")
struct RedactorTests {
    @Test(arguments: [
        "key=sk-ant-api03-AbCdEfGh1234567890XYZ",
        "Authorization: Bearer sk-proj-abcdefghijklmnop1234567890",
        "x-goog-api-key: AIzaSyA1234567890abcdefghijklmnopqrstuv",
        "api_key=\"my-secret-token-123456\"",
    ])
    func removesSecrets(text: String) {
        let out = Redactor.redact(text)
        #expect(out.contains("REDACTED"))
        for secret in ["AbCdEfGh1234567890XYZ", "abcdefghijklmnop1234567890", "SyA1234567890abcdefghijklmnopqrstuv", "my-secret-token-123456"] {
            #expect(!out.contains(secret))
        }
    }

    @Test func leavesNormalTextAlone() {
        let t = "Recording Zoom call, 3 speakers, model large-v3"
        #expect(Redactor.redact(t) == t)
    }

    @Test func mask() {
        #expect(Redactor.mask("sk-ant-api03-abcdefgh9F2a") == "sk-ant-…9F2a")
        #expect(Redactor.mask("sk-proj-abcdefgha9F2") == "sk-…a9F2")
        #expect(Redactor.mask("short") == "•••••")
    }
}
