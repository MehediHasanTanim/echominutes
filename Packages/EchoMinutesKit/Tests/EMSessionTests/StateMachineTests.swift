import EMCore
import EMDetection
import Foundation
import Testing
@testable import EMSession

/// Scripted scenarios (EM-066). Each step = one 1-second poll.
struct Script {
    var m: MeetingStateMachine
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    var effects: [DetectionEffect] = []

    init(_ overrides: [String: RuleOverride] = [:], privateHours: PrivateHours? = nil) throws {
        m = MeetingStateMachine(rules: RuleSet(base: try testRules(), overrides: overrides, privateHours: privateHours))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        m.calendar = cal
    }

    /// Advance `seconds` polls with the given app states; collects effects.
    mutating func run(_ seconds: Int, _ apps: [String: (mic: Bool, out: Bool)]) {
        for _ in 0..<seconds {
            var snap: ActivitySnapshot = [:]
            for (id, s) in apps { snap[id] = AppActivity(appID: id, mic: s.mic, output: s.out) }
            effects += m.observe(snap, now: t)
            t = t.addingTimeInterval(1)
        }
    }
    var reasons: [DecisionReason] { m.decisions.map(\.reason) }
    func count(_ match: (DetectionEffect) -> Bool) -> Int { effects.filter(match).count }
}

func isBegin(_ e: DetectionEffect) -> Bool { if case .beginRecording = e { true } else { false } }
func isFinalize(_ e: DetectionEffect) -> Bool { if case .finalizeRecording = e { true } else { false } }
func isCancel(_ e: DetectionEffect) -> Bool { if case .cancelCandidate = e { true } else { false } }

@Suite("MeetingStateMachine scenarios")
struct StateMachineTests {
    @Test func shortVoiceNoteIsIgnored() throws {
        var s = try Script()
        s.run(5, ["whatsapp": (true, false)])          // 5 s < 8 s WhatsApp debounce
        s.run(3, ["whatsapp": (false, false)])
        #expect(s.count(isBegin) == 0 && s.count(isCancel) == 1)
        #expect(s.reasons == [.candidateMicOn, .ignoredDebounce])
        #expect(s.m.phase == .idle)
    }

    @Test func normalCallStartsAfterDebounceAndEndsAfterGrace() throws {
        var s = try Script()
        s.run(1, ["teams": (false, false)])            // app open, no call
        #expect(s.effects.isEmpty)
        s.run(6, ["teams": (true, true)])              // join
        #expect(s.count(isBegin) == 1)
        if case .startCandidate(_, let preRoll) = s.effects.first { #expect(preRoll == 10) }
        if case .recording(let id, _) = s.m.phase { #expect(id == "teams") } else { Issue.record("not recording") }
        s.run(600, ["teams": (true, true)])            // 10-minute call
        s.run(14, ["teams": (false, false)])           // left: 14 s < 15 s grace
        #expect(s.count(isFinalize) == 0)
        s.run(2, ["teams": (false, false)])
        #expect(s.count(isFinalize) == 1)
        #expect(s.reasons.suffix(1) == [.endedGrace] && s.m.phase == .idle)
    }

    @Test func candidateCapturesFromFirstMicSecond() throws {
        var s = try Script()
        let start = s.t
        s.run(6, ["zoom": (true, false)])
        guard case .beginRecording(_, let since) = s.effects.last else { Issue.record("no begin"); return }
        #expect(since == start)                        // pre-roll covers the debounce window
    }

    @Test func muteKeepsRecording() throws {
        var s = try Script()
        s.run(6, ["teams": (true, true)])
        s.run(300, ["teams": (true, true)])            // muted: Teams keeps the mic open (spike EM-004)
        #expect(s.count(isFinalize) == 0)
    }

    @Test func briefDropoutWithinGraceDoesNotSplitTheMeeting() throws {
        var s = try Script()
        s.run(6, ["zoom": (true, true)])
        s.run(10, ["zoom": (false, false)])            // reconnect / device switch
        s.run(30, ["zoom": (true, true)])
        #expect(s.count(isBegin) == 1 && s.count(isFinalize) == 0)
    }

    @Test func micOffButHelperOutputStillOnEndsAfter60s() throws {
        var s = try Script()
        s.run(6, ["teams": (true, true)])
        s.run(59, ["teams": (false, true)])            // Teams WebView helper keeps output after the call
        #expect(s.count(isFinalize) == 0)
        s.run(2, ["teams": (false, true)])
        #expect(s.count(isFinalize) == 1 && s.reasons.last == .endedMicOffLong)
    }

    @Test func appQuitEndsImmediately() throws {
        var s = try Script()
        s.run(6, ["zoom": (true, true)])
        s.run(1, [:])                                  // zoom processes gone
        #expect(s.count(isFinalize) == 1 && s.reasons.last == .endedAppQuit)
    }

    @Test func sleepFinalizes() throws {
        var s = try Script()
        s.run(6, ["teams": (true, true)])
        s.effects += s.m.systemWillSleep(now: s.t)
        #expect(s.count(isFinalize) == 1 && s.reasons.last == .endedSleep)
    }

    @Test func secondAppIsNotifiedOnceNotRecorded() throws {
        var s = try Script()
        s.run(6, ["teams": (true, true)])
        s.run(20, ["teams": (true, true), "zoom": (true, true)])
        let notifies = s.effects.filter { if case .notifyOtherApp(let a, let r) = $0 { a == "zoom" && r == "teams" } else { false } }
        #expect(notifies.count == 1 && s.count(isBegin) == 1)
    }

    @Test func neverModeAndPrivateHoursAreIgnoredAndLoggedOnce() throws {
        var s = try Script(["whatsapp": RuleOverride(mode: .never)])
        s.run(30, ["whatsapp": (true, true)])
        #expect(s.effects.isEmpty && s.reasons == [.ignoredRuleNever])

        var p = try Script(privateHours: PrivateHours(startMinute: 0, endMinute: 24 * 60 - 1))
        p.run(30, ["teams": (true, true)])
        #expect(p.effects.isEmpty && p.reasons == [.ignoredPrivateHours])
    }

    @Test func askModeAcceptDeclineTimeout() throws {
        var a = try Script(["zoom": RuleOverride(mode: .ask)])
        a.run(3, ["zoom": (true, true)])
        #expect(a.effects.contains(.askUser(appID: "zoom")))
        a.effects += a.m.userResponded(accept: true, now: a.t)
        #expect(a.count(isBegin) == 1 && a.reasons.last == .startedUserAccepted)

        var d = try Script(["zoom": RuleOverride(mode: .ask)])
        d.run(3, ["zoom": (true, true)])
        d.effects += d.m.userResponded(accept: false, now: d.t)
        d.run(60, ["zoom": (true, true)])              // same call continues: not asked again
        #expect(d.count(isBegin) == 0 && d.effects.filter { $0 == .askUser(appID: "zoom") }.count == 1)

        var t = try Script(["zoom": RuleOverride(mode: .ask)])
        t.run(25, ["zoom": (true, true)])              // 20 s ask timeout
        #expect(t.count(isBegin) == 0 && t.reasons.contains(.askTimeout))
    }

    @Test func manualStopDoesNotReRecordSameCallButNextCallWorks() throws {
        var s = try Script()
        s.run(6, ["teams": (true, true)])
        s.effects += s.m.manualStop(now: s.t)
        s.run(60, ["teams": (true, true)])             // same call still going
        #expect(s.count(isBegin) == 1 && s.count(isFinalize) == 1)
        s.run(2, ["teams": (false, false)])            // call ends → suppression cleared
        s.run(6, ["teams": (true, true)])              // next call
        #expect(s.count(isBegin) == 2)
    }

    @Test func manualDiscard() throws {
        var s = try Script()
        s.run(6, ["teams": (true, true)])
        s.effects += s.m.manualDiscard(now: s.t)
        #expect(s.effects.last == .discardRecording(appID: "teams") && s.m.phase == .idle)
    }

    @Test func siriAndUnknownAppsNeverTrigger() throws {
        var s = try Script()
        s.run(30, ["chrome": (true, true)])            // not a watched app id
        #expect(s.effects.isEmpty)
    }
}

@Suite("DetectionCoordinator")
struct CoordinatorTests {
    actor Recorder: DetectionEffectHandler {
        var effects: [DetectionEffect] = []
        func perform(_ effect: DetectionEffect) async { effects.append(effect) }
    }

    @Test func drivesMachineWithInjectedClock() async throws {
        let clock = ManualClock()
        let rec = Recorder()
        let c = DetectionCoordinator(rules: RuleSet(base: try testRules()), handler: rec, clock: clock)
        for _ in 0..<6 {
            await c.ingest(["zoom": AppActivity(appID: "zoom", mic: true, output: true)])
            clock.advance(by: .seconds(1))
        }
        #expect(await rec.effects.contains { if case .beginRecording = $0 { true } else { false } })
        await c.manualStop()
        #expect(await c.phase == .idle)
        #expect(await c.decisions.map(\.reason) == [.candidateMicOn, .startedAuto, .endedManual])
    }
}
