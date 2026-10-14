import EMCore
import Foundation

/// Logs when the main thread stops responding (menu bar clicks ignored, widget not drawn). Pings the main queue
/// every second from a background queue; a ping answered late, or not at all for 3 s, is logged as an error with
/// what the app was doing (recording state), so `scripts/collect-diagnostics.sh` captures it.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private let queue = DispatchQueue(label: "echominutes.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pending: Date?          // queue-confined
    private var reportedStall = false
    var context = "idle"                 // best-effort label for the log, written on main

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            Log.info(.app, "Main-thread watchdog started")
        }
    }

    private func tick() {
        let now = Date()
        if let sent = pending {
            let blocked = now.timeIntervalSince(sent)
            if blocked >= 3, !reportedStall {
                reportedStall = true
                Log.error(.app, String(format: "MAIN THREAD UNRESPONSIVE for %.0f s (while %@)", blocked, context))
            }
            return                       // still waiting for the previous ping
        }
        pending = now
        DispatchQueue.main.async { [weak self] in
            let answered = Date()
            self?.queue.async {
                guard let self, let sent = self.pending else { return }
                let delay = answered.timeIntervalSince(sent)
                if delay >= 1 || self.reportedStall {
                    Log.error(.app, String(format: "Main thread was blocked for %.1f s (while %@)", delay, self.context))
                }
                self.pending = nil
                self.reportedStall = false
            }
        }
    }
}
