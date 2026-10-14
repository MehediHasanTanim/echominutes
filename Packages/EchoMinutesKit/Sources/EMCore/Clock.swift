import Foundation

/// Injectable time source so state machines (debounce/grace) are testable without real waiting.
public protocol EMClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: EMClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Test clock: time only moves when `advance(by:)` is called; sleepers whose deadline passes are resumed.
/// Note: does not support cancellation of pending sleeps (sufficient for unit tests).
public final class ManualClock: EMClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    public var now: Date { lock.withLock { current } }

    /// Number of tasks currently waiting in `sleep`.
    public var pendingSleepers: Int { lock.withLock { sleepers.count } }

    public func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let resumeNow: Bool = lock.withLock {
                let deadline = current.addingTimeInterval(duration.seconds)
                if deadline <= current { return true }
                sleepers.append((deadline, c)); return false
            }
            if resumeNow { c.resume() }
        }
    }

    public func advance(by duration: Duration) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = current.addingTimeInterval(duration.seconds)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }
}

public extension Duration {
    /// Duration as fractional seconds.
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
