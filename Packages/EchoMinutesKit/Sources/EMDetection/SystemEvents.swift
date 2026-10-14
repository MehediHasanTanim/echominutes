import AppKit
import Foundation

/// Sleep / wake notifications (EM-062). App quit is derived from activity snapshots (processes disappear).
public final class SystemEventsWatcher: @unchecked Sendable {
    public enum Event: Sendable { case willSleep, didWake }
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var tokens: [NSObjectProtocol] = []

    public init() { (events, continuation) = AsyncStream.makeStream(of: Event.self) }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let c = continuation
        tokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in c.yield(.willSleep) })
        tokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in c.yield(.didWake) })
    }

    public func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        continuation.finish()
    }
}
