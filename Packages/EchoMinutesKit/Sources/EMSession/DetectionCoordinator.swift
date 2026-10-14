import EMCore
import EMDetection
import Foundation

/// Performs detection effects. Sprint 5: logging only; Sprint 6 (EM-070) plugs in real recording + notifications.
public protocol DetectionEffectHandler: Sendable {
    func perform(_ effect: DetectionEffect) async
}

public struct LoggingEffectHandler: DetectionEffectHandler {
    public init() {}
    public func perform(_ effect: DetectionEffect) async { Log.info(.detection, "effect (observe-only): \(effect)") }
}

/// Drives the MeetingStateMachine from live activity snapshots and system events (EM-065/067).
public actor DetectionCoordinator {
    public struct Update: Sendable {
        public var phase: MeetingStateMachine.Phase
        public var snapshot: ActivitySnapshot
        public var newDecisions: [Decision]
    }

    public nonisolated let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private var machine: MeetingStateMachine
    private let handler: DetectionEffectHandler
    private let clock: EMClock
    private var lastSnapshot: ActivitySnapshot = [:]

    public init(rules: RuleSet, handler: DetectionEffectHandler = LoggingEffectHandler(), clock: EMClock = SystemClock()) {
        machine = MeetingStateMachine(rules: rules)
        self.handler = handler
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .bufferingNewest(8))
    }

    public var phase: MeetingStateMachine.Phase { machine.phase }
    public var decisions: [Decision] { machine.decisions }

    /// Consumes the monitor until it finishes (or the task is cancelled).
    public func run(snapshots: AsyncStream<ActivitySnapshot>) async {
        for await s in snapshots { await ingest(s) }
    }

    public func ingest(_ snapshot: ActivitySnapshot) async {
        lastSnapshot = snapshot
        await apply { $0.observe(snapshot, now: clock.now) }
    }

    public func userResponded(accept: Bool) async { await apply { $0.userResponded(accept: accept, now: clock.now) } }
    public func manualStop() async { await apply { $0.manualStop(now: clock.now) } }
    public func manualDiscard() async { await apply { $0.manualDiscard(now: clock.now) } }
    public func systemWillSleep() async { await apply { $0.systemWillSleep(now: clock.now) } }

    public func updateRules(_ rules: RuleSet) { machine.rules = rules }

    private func apply(_ step: (inout MeetingStateMachine) -> [DetectionEffect]) async {
        let before = machine.decisions.count
        let effects = step(&machine)
        let fresh = Array(machine.decisions.suffix(max(0, machine.decisions.count - before)))
        for d in fresh {
            Log.info(.detection, "\(d.reason.rawValue) app=\(d.appID ?? "-")\(d.detail.map { " (\($0))" } ?? "")")
        }
        for e in effects { await handler.perform(e) }
        continuation.yield(Update(phase: machine.phase, snapshot: lastSnapshot, newDecisions: fresh))
    }
}
