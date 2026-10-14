import EMCore
import EMDetection
import Foundation

/// Why the detector did something (Technical Design §16 reason codes; EM-067).
public enum DecisionReason: String, Sendable, CaseIterable {
    case candidateMicOn = "CANDIDATE_MIC_ON"
    case askedUser = "ASKED_USER"
    case ignoredDebounce = "IGNORED_DEBOUNCE"
    case ignoredRuleNever = "IGNORED_RULE_NEVER"
    case ignoredPrivateHours = "IGNORED_PRIVATE_HOURS"
    case ignoredUserDeclined = "IGNORED_USER_DECLINED"
    case askTimeout = "ASK_TIMEOUT"
    case startedAuto = "STARTED_AUTO"
    case startedUserAccepted = "STARTED_USER_ACCEPTED"
    case endedGrace = "ENDED_GRACE"
    case endedMicOffLong = "ENDED_MIC_OFF_LONG"
    case endedAppQuit = "ENDED_APP_QUIT"
    case endedSleep = "ENDED_SLEEP"
    case endedManual = "ENDED_MANUAL"
    case discardedManual = "DISCARDED_MANUAL"
    case notifiedOtherApp = "NOTIFIED_OTHER_APP"
}

public struct Decision: Sendable, Equatable {
    public var at: Date
    public var appID: String?
    public var reason: DecisionReason
    public var detail: String?
}

/// Side effects the coordinator must perform; the state machine itself is pure.
public enum DetectionEffect: Sendable, Equatable {
    case startCandidate(appID: String, preRoll: TimeInterval)  // start capture into ring buffers only
    case cancelCandidate(appID: String)                         // stop capture, keep nothing
    case beginRecording(appID: String, candidateSince: Date)    // persist pre-roll + live audio
    case finalizeRecording(appID: String)
    case discardRecording(appID: String)
    case askUser(appID: String)
    case dismissAsk(appID: String)
    case notifyOtherApp(appID: String, recordingAppID: String)
}

/// Deterministic meeting detector (Technical Design §6.4; EM-065). Fed an activity snapshot every poll (1 s) plus
/// user/system events, it returns effects. Time only comes from the `now` arguments, so tests need no waiting.
public struct MeetingStateMachine: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case candidate(appID: String, since: Date)
        case asking(appID: String, since: Date, askedAt: Date)
        case recording(appID: String, since: Date)

        public var appID: String? {
            switch self {
            case .idle: nil
            case .candidate(let a, _), .asking(let a, _, _), .recording(let a, _): a
            }
        }
    }

    public private(set) var phase: Phase = .idle
    public var rules: RuleSet
    public private(set) var decisions: [Decision] = []
    public var calendar: Calendar = .current

    private var micOffSince: Date?
    private var inactiveSince: Date?
    /// Apps not considered again until their mic turns off (declined, ignored, manually stopped…).
    private var suppressed: Set<String> = []
    private var notified: Set<String> = []
    private static let maxDecisions = 200

    public init(rules: RuleSet) { self.rules = rules }

    // MARK: - Inputs

    public mutating func observe(_ snap: ActivitySnapshot, now: Date) -> [DetectionEffect] {
        suppressed = suppressed.filter { snap[$0]?.mic == true }
        notified = notified.filter { snap[$0]?.mic == true }

        switch phase {
        case .idle:
            return considerNewCandidate(snap, now: now)

        case .candidate(let id, let since):
            guard let a = snap[id], a.mic else {
                phase = .idle
                log(now, id, .ignoredDebounce, String(format: "mic on for %.1f s", now.timeIntervalSince(since)))
                return [.cancelCandidate(appID: id)] + considerNewCandidate(snap, now: now)
            }
            let debounce = rules.rule(id)?.debounce ?? 5
            if now.timeIntervalSince(since) >= debounce {
                phase = .recording(appID: id, since: since)
                micOffSince = nil; inactiveSince = nil
                log(now, id, .startedAuto, String(format: "after %.1f s debounce", debounce))
                return [.beginRecording(appID: id, candidateSince: since)]
            }
            return []

        case .asking(let id, _, let askedAt):
            guard let a = snap[id], a.mic else {
                phase = .idle
                log(now, id, .ignoredDebounce, "mic off while asking")
                return [.dismissAsk(appID: id), .cancelCandidate(appID: id)]
            }
            if now.timeIntervalSince(askedAt) >= rules.askTimeout {
                phase = .idle; suppressed.insert(id)
                log(now, id, .askTimeout, nil)
                return [.dismissAsk(appID: id), .cancelCandidate(appID: id)]
            }
            return []

        case .recording(let id, _):
            var effects: [DetectionEffect] = []
            guard let a = snap[id] else {
                end(now, id, .endedAppQuit, nil)
                return [.finalizeRecording(appID: id)]
            }
            if a.mic {
                micOffSince = nil; inactiveSince = nil
            } else {
                micOffSince = micOffSince ?? now
                inactiveSince = a.output ? nil : (inactiveSince ?? now)
            }
            let grace = rules.rule(id)?.grace ?? 15
            if let ia = inactiveSince, now.timeIntervalSince(ia) >= grace {
                end(now, id, .endedGrace, String(format: "no mic/output for %.0f s", grace))
                return [.finalizeRecording(appID: id)]
            }
            if let mo = micOffSince, now.timeIntervalSince(mo) >= max(grace, rules.micOffMaxWhileOutput) {
                end(now, id, .endedMicOffLong, String(format: "mic off %.0f s (output still on)", now.timeIntervalSince(mo)))
                return [.finalizeRecording(appID: id)]
            }
            for r in rules.rules where r.app.id != id && snap[r.app.id]?.mic == true && !notified.contains(r.app.id) && r.mode != .never {
                notified.insert(r.app.id)
                log(now, r.app.id, .notifiedOtherApp, "while recording \(id)")
                effects.append(.notifyOtherApp(appID: r.app.id, recordingAppID: id))
            }
            return effects
        }
    }

    /// Answer to an "Ask first" prompt.
    public mutating func userResponded(accept: Bool, now: Date) -> [DetectionEffect] {
        guard case .asking(let id, let since, _) = phase else { return [] }
        if accept {
            phase = .recording(appID: id, since: since)
            micOffSince = nil; inactiveSince = nil
            log(now, id, .startedUserAccepted, nil)
            return [.beginRecording(appID: id, candidateSince: since)]
        }
        phase = .idle; suppressed.insert(id)
        log(now, id, .ignoredUserDeclined, nil)
        return [.cancelCandidate(appID: id)]
    }

    /// User pressed Stop: save it, and don't immediately re-detect the same ongoing call.
    public mutating func manualStop(now: Date) -> [DetectionEffect] {
        switch phase {
        case .recording(let id, _):
            end(now, id, .endedManual, nil); suppressed.insert(id)
            return [.finalizeRecording(appID: id)]
        case .candidate(let id, _), .asking(let id, _, _):
            phase = .idle; suppressed.insert(id)
            return [.dismissAsk(appID: id), .cancelCandidate(appID: id)]
        case .idle: return []
        }
    }

    public mutating func manualDiscard(now: Date) -> [DetectionEffect] {
        guard case .recording(let id, _) = phase else { return manualStop(now: now) }
        phase = .idle; resetTimers(); suppressed.insert(id)
        log(now, id, .discardedManual, nil)
        return [.discardRecording(appID: id)]
    }

    public mutating func systemWillSleep(now: Date) -> [DetectionEffect] {
        switch phase {
        case .recording(let id, _):
            end(now, id, .endedSleep, nil)
            return [.finalizeRecording(appID: id)]
        case .candidate(let id, _), .asking(let id, _, _):
            phase = .idle
            return [.dismissAsk(appID: id), .cancelCandidate(appID: id)]
        case .idle: return []
        }
    }

    // MARK: - Helpers

    private mutating func considerNewCandidate(_ snap: ActivitySnapshot, now: Date) -> [DetectionEffect] {
        for r in rules.rules {
            let id = r.app.id
            guard snap[id]?.mic == true, !suppressed.contains(id) else { continue }
            if r.mode == .never {
                suppressed.insert(id); log(now, id, .ignoredRuleNever, nil); continue
            }
            if let ph = rules.privateHours, ph.contains(now, calendar: calendar) {
                suppressed.insert(id); log(now, id, .ignoredPrivateHours, nil); continue
            }
            let preRoll = r.debounce + 5
            if r.mode == .ask {
                phase = .asking(appID: id, since: now, askedAt: now)
                log(now, id, .askedUser, nil)
                return [.startCandidate(appID: id, preRoll: max(preRoll, rules.askTimeout + 5)), .askUser(appID: id)]
            }
            phase = .candidate(appID: id, since: now)
            log(now, id, .candidateMicOn, nil)
            return [.startCandidate(appID: id, preRoll: preRoll)]
        }
        return []
    }

    private mutating func end(_ now: Date, _ id: String, _ reason: DecisionReason, _ detail: String?) {
        phase = .idle; resetTimers()
        log(now, id, reason, detail)
    }

    private mutating func resetTimers() { micOffSince = nil; inactiveSince = nil; notified = [] }

    private mutating func log(_ at: Date, _ appID: String?, _ reason: DecisionReason, _ detail: String?) {
        decisions.append(Decision(at: at, appID: appID, reason: reason, detail: detail))
        if decisions.count > Self.maxDecisions { decisions.removeFirst(decisions.count - Self.maxDecisions) }
    }
}
