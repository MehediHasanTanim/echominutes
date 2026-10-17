import EMCore
import EMDetection
import Foundation

/// Things the UI should react to (notifications, menu refresh) — EM-070/071/076.
public enum AutoRecordingEvent: Sendable, Equatable {
    case started(sessionID: SessionID, appID: String, appName: String)
    case saved(sessionID: SessionID, title: String, durationSec: Int)
    case discarded(appName: String)
    case ask(appID: String, appName: String)
    case dismissAsk(appID: String)
    case otherApp(appName: String, recordingAppName: String)
    case failed(String)
    /// Recorder state changed (candidate started/cancelled, finalizing began…); the UI should re-read it.
    case stateChanged
}

/// Performs the state machine's effects on the real recorder (EM-070). Detection only ever stops or discards
/// recordings it started itself (`origin == .auto`); a manual recording is never touched.
public actor AutoRecordingHandler: DetectionEffectHandler {
    public nonisolated let events: AsyncStream<AutoRecordingEvent>
    private let continuation: AsyncStream<AutoRecordingEvent>.Continuation
    private let recorder: RecorderControl
    private var rules: RuleSet
    private let micAllowed: @Sendable () -> Bool
    private let clock: EMClock
    private var finalizing: Task<Void, Never>?
    /// Snapshot behind the effect being performed (browser + tab title for web meetings).
    private var context: ActivitySnapshot = [:]

    public init(recorder: RecorderControl, rules: RuleSet, clock: EMClock = SystemClock(),
                micAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.recorder = recorder
        self.rules = rules
        self.clock = clock
        self.micAllowed = micAllowed
        (events, continuation) = AsyncStream.makeStream(of: AutoRecordingEvent.self, bufferingPolicy: .bufferingNewest(32))
    }

    public func updateRules(_ rules: RuleSet) { self.rules = rules }

    /// Waits for a background finalize (tests).
    public func waitForFinalize() async { await finalizing?.value }

    private func name(_ id: String) -> String {
        if id == RuleSet.webOtherID, let browser = context[id]?.browserName { return browser }
        return rules.rule(id)?.app.name ?? id
    }

    /// The app to capture: for a browser meeting only the browser that holds the mic (EM-154).
    private func app(_ id: String) -> DetectionRules.App? {
        guard var app = rules.rule(id)?.app else { return nil }
        if let a = context[id] {
            if !a.bundlePrefixes.isEmpty { app.bundlePrefixes = a.bundlePrefixes }
            if id == RuleSet.webOtherID, let b = a.browserName { app.name = b }
        }
        return app
    }

    /// Browser meetings are named after the meeting tab when it has a useful title (EM-156).
    private func applyTitle(_ id: String) async {
        guard rules.rule(id)?.isWeb == true, let title = context[id]?.title else { return }
        await recorder.setTitle(title)
    }

    public func perform(_ effect: DetectionEffect, snapshot: ActivitySnapshot) async {
        context = snapshot
        await perform(effect)
    }

    public func perform(_ effect: DetectionEffect) async {
        switch effect {
        case .startCandidate(let id, let preRoll):
            guard let app = app(id) else { return }
            guard case .idle = await recorder.state else {
                Log.info(.session, "Candidate \(id) not captured: recorder busy"); return
            }
            do {
                try await recorder.startCandidate(app: app, includeMic: micAllowed(), preRoll: preRoll, now: clock.now)
                await applyTitle(id)
                continuation.yield(.stateChanged)
            } catch {
                // Not fatal: beginRecording falls back to a fresh start without pre-roll.
                Log.error(.session, "Candidate capture failed for \(id): \(error)")
            }

        case .cancelCandidate:
            if case .candidate = await recorder.state {
                await recorder.cancelCandidate()
                continuation.yield(.stateChanged)
            }

        case .beginRecording(let id, _):
            do {
                let session: Session
                switch await recorder.state {
                case .candidate(let info) where info.appID == id:
                    session = try await recorder.commitCandidate(now: clock.now)
                case .candidate:
                    await recorder.cancelCandidate()
                    session = try await startFresh(id)
                case .idle:
                    session = try await startFresh(id)
                case .recording, .paused, .finalizing:
                    Log.info(.session, "Auto-start of \(id) skipped: another recording is active"); return
                }
                await applyTitle(id)
                continuation.yield(.started(sessionID: session.id, appID: id, appName: name(id)))
            } catch {
                Log.error(.session, "Auto-start failed for \(id): \(error)")
                continuation.yield(.failed("Couldn't start recording \(name(id)): \(error.localizedDescription)"))
            }

        case .finalizeRecording:
            let state = await recorder.state
            guard state.isActive, state.info?.origin == .auto else { return }
            let recorder = self.recorder, cont = continuation, now = clock.now
            // Finalizing can take seconds; don't block detection while it runs.
            finalizing = Task {
                do {
                    let s = try await recorder.stop(now: now)
                    let dur = Int((s.endedAt ?? now).timeIntervalSince(s.startedAt))
                    cont.yield(.saved(sessionID: s.id, title: s.title, durationSec: dur))
                } catch {
                    cont.yield(.failed("Saving the recording failed: \(error.localizedDescription)"))
                }
            }
            continuation.yield(.stateChanged)

        case .discardRecording:
            let state = await recorder.state
            guard state.info?.origin == .auto, let appName = state.info?.appName else { return }
            do {
                try await recorder.discard()
                continuation.yield(.discarded(appName: appName))
            } catch {
                continuation.yield(.failed("Discard failed: \(error.localizedDescription)"))
            }

        case .askUser(let id):
            continuation.yield(.ask(appID: id, appName: name(id)))

        case .dismissAsk(let id):
            continuation.yield(.dismissAsk(appID: id))

        case .notifyOtherApp(let id, let recordingID):
            continuation.yield(.otherApp(appName: name(id), recordingAppName: name(recordingID)))
        }
    }

    private func startFresh(_ id: String) async throws -> Session {
        guard let app = app(id) else { throw EMError.notFound("rule \(id)") }
        return try await recorder.start(app: app, includeMic: micAllowed(), origin: .auto, now: clock.now)
    }
}
