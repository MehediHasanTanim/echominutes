import EMCore
import EMDetection
import Foundation
import Testing
@testable import EMSession

/// In-memory stand-in for ManualRecorder: same state transitions, no Core Audio.
actor FakeRecorder: RecorderControl {
    var state: ManualRecorder.State = .idle
    var calls: [String] = []
    var failStart = false
    private var current: Session?

    func startCandidate(app: DetectionRules.App, includeMic: Bool, preRoll: TimeInterval, now: Date) async throws {
        guard case .idle = state else { throw EMError.invalidData("busy") }
        if failStart { throw EMError.invalidData("no processes") }
        calls.append("candidate:\(app.id):\(Int(preRoll))")
        let s = Session(title: "\(app.name) call", sourceAppID: app.id, startedAt: now, status: .recording)
        current = s
        state = .candidate(.init(sessionID: s.id, appID: app.id, appName: app.name, startedAt: now, origin: .auto))
    }

    func commitCandidate(now: Date) async throws -> Session {
        guard case .candidate(let i) = state, let s = current else { throw EMError.notFound("candidate") }
        calls.append("commit:\(i.appID)")
        state = .recording(i)
        return s
    }

    func cancelCandidate() async {
        guard case .candidate(let i) = state else { return }
        calls.append("cancel:\(i.appID)")
        state = .idle; current = nil
    }

    func start(app: DetectionRules.App, includeMic: Bool, origin: ManualRecorder.Origin, now: Date) async throws -> Session {
        guard case .idle = state else { throw EMError.invalidData("busy") }
        if failStart { throw EMError.invalidData("no processes") }
        calls.append("start:\(app.id):\(origin.rawValue)")
        let s = Session(title: "\(app.name) call", sourceAppID: app.id, startedAt: now, status: .recording)
        current = s
        state = .recording(.init(sessionID: s.id, appID: app.id, appName: app.name, startedAt: now, origin: origin))
        return s
    }

    func stop(now: Date) async throws -> Session {
        guard state.isActive, var s = current else { throw EMError.notFound("recording") }
        calls.append("stop")
        s.endedAt = now; s.status = .ready
        state = .idle; current = nil
        return s
    }

    func discard() async throws {
        guard state.info != nil else { return }
        calls.append("discard")
        state = .idle; current = nil
    }

    func setFailStart(_ v: Bool) { failStart = v }
}

@Suite("AutoRecordingHandler")
struct AutoRecordingTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func make() throws -> (AutoRecordingHandler, FakeRecorder, ManualClock) {
        let rec = FakeRecorder()
        let clock = ManualClock(start: t0)
        return (AutoRecordingHandler(recorder: rec, rules: RuleSet(base: try testRules()), clock: clock), rec, clock)
    }

    func drain(_ h: AutoRecordingHandler) async -> [AutoRecordingEvent] {
        let stream = h.events
        // Events are yielded synchronously before perform returns, so a short timed read is enough.
        let task = Task {
            var out: [AutoRecordingEvent] = []
            for await e in stream { out.append(e) }
            return out
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        return await task.value
    }

    @Test func candidateThenCommitKeepsPreRoll() async throws {
        let (h, rec, _) = try make()
        await h.perform(.startCandidate(appID: "zoom", preRoll: 10))
        await h.perform(.beginRecording(appID: "zoom", candidateSince: t0))
        #expect(await rec.calls == ["candidate:zoom:10", "commit:zoom"])
        #expect(await rec.state.info?.origin == .auto)
        await h.perform(.finalizeRecording(appID: "zoom"))
        await h.waitForFinalize()
        #expect(await rec.calls.last == "stop")
        #expect(await rec.state == .idle)
    }

    @Test func voiceNoteCancelsCandidate() async throws {
        let (h, rec, _) = try make()
        await h.perform(.startCandidate(appID: "whatsapp", preRoll: 13))
        await h.perform(.cancelCandidate(appID: "whatsapp"))
        #expect(await rec.calls == ["candidate:whatsapp:13", "cancel:whatsapp"])
        #expect(await rec.state == .idle)
    }

    @Test func beginWithoutCandidateStartsFresh() async throws {
        let (h, rec, _) = try make()
        await rec.setFailStart(true)
        await h.perform(.startCandidate(appID: "teams", preRoll: 10))      // fails, logged only
        await rec.setFailStart(false)
        await h.perform(.beginRecording(appID: "teams", candidateSince: t0))
        #expect(await rec.calls == ["start:teams:auto"])
    }

    @Test func neverTouchesManualRecording() async throws {
        let (h, rec, _) = try make()
        let teams = try #require(RuleSet(base: try testRules()).rule("teams")?.app)
        _ = try await rec.start(app: teams, includeMic: true, origin: .manual, now: t0)
        await h.perform(.startCandidate(appID: "teams", preRoll: 10))
        await h.perform(.beginRecording(appID: "teams", candidateSince: t0))
        await h.perform(.finalizeRecording(appID: "teams"))
        await h.perform(.discardRecording(appID: "teams"))
        await h.waitForFinalize()
        #expect(await rec.calls == ["start:teams:manual"])
        #expect(await rec.state.info?.origin == .manual)
    }

    @Test func discardAutoRecording() async throws {
        let (h, rec, _) = try make()
        await h.perform(.startCandidate(appID: "zoom", preRoll: 10))
        await h.perform(.beginRecording(appID: "zoom", candidateSince: t0))
        await h.perform(.discardRecording(appID: "zoom"))
        #expect(await rec.calls.last == "discard")
        #expect(await rec.state == .idle)
    }

    @Test func emitsUIEvents() async throws {
        let (h, _, clock) = try make()
        await h.perform(.askUser(appID: "zoom"))
        await h.perform(.dismissAsk(appID: "zoom"))
        await h.perform(.notifyOtherApp(appID: "zoom", recordingAppID: "teams"))
        await h.perform(.startCandidate(appID: "zoom", preRoll: 10))
        await h.perform(.beginRecording(appID: "zoom", candidateSince: t0))
        clock.advance(by: .seconds(65))
        await h.perform(.finalizeRecording(appID: "zoom"))
        await h.waitForFinalize()
        let events = await drain(h)
        #expect(events.contains(.ask(appID: "zoom", appName: "Zoom")))
        #expect(events.contains(.dismissAsk(appID: "zoom")))
        #expect(events.contains(.otherApp(appName: "Zoom", recordingAppName: "Microsoft Teams")))
        #expect(events.contains { if case .started(_, "zoom", "Zoom") = $0 { true } else { false } })
        #expect(events.contains { if case .saved(_, "Zoom call", 65) = $0 { true } else { false } })
    }

    /// Whole pipeline: scripted snapshots → state machine → handler → fake recorder.
    @Test func coordinatorEndToEnd() async throws {
        let (h, rec, clock) = try make()
        let c = DetectionCoordinator(rules: RuleSet(base: try testRules()), handler: h, clock: clock)
        func tick(_ s: ActivitySnapshot, _ n: Int) async {
            for _ in 0..<n { await c.ingest(s); clock.advance(by: .seconds(1)) }
        }
        let onCall: ActivitySnapshot = ["zoom": AppActivity(appID: "zoom", mic: true, output: true)]
        let hungUp: ActivitySnapshot = ["zoom": AppActivity(appID: "zoom", mic: false, output: false)]
        await tick(onCall, 30)
        #expect(await rec.calls == ["candidate:zoom:10", "commit:zoom"])
        await tick(hungUp, 16)
        await h.waitForFinalize()
        #expect(await rec.calls.last == "stop")
        #expect(await c.phase == .idle)
    }
}
