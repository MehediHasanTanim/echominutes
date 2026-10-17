import CoreAudio
import EMAudio
import EMCore
import Foundation

/// Aggregated audio state of one watched app across all its processes (EM-063).
public struct AppActivity: Sendable, Equatable {
    public var appID: String
    public var running: Bool        // has at least one audio process object
    public var mic: Bool            // any process using the microphone
    public var output: Bool         // any process producing audio
    public var pids: [pid_t]
    /// Browser meetings (EM-152): the meeting window's title, the browser's name and bundle prefixes
    /// (so capture taps only that browser).
    public var title: String?
    public var browserName: String?
    public var bundlePrefixes: [String]
    public init(appID: String, running: Bool = true, mic: Bool = false, output: Bool = false, pids: [pid_t] = [],
                title: String? = nil, browserName: String? = nil, bundlePrefixes: [String] = []) {
        self.appID = appID; self.running = running; self.mic = mic; self.output = output; self.pids = pids
        self.title = title; self.browserName = browserName; self.bundlePrefixes = bundlePrefixes
    }
}

public typealias ActivitySnapshot = [String: AppActivity]

public enum ActivityAggregator {
    /// Groups process objects by watched app. Apps without processes are absent from the snapshot.
    public static func aggregate(_ processes: [AudioProcessInfo], rules: RuleSet, selfPID: pid_t = getpid()) -> ActivitySnapshot {
        var out: ActivitySnapshot = [:]
        for p in processes where p.pid != selfPID {
            guard let id = rules.appID(bundleID: p.bundleID, owningBundleID: p.owningAppBundleID) else { continue }
            var a = out[id] ?? AppActivity(appID: id)
            a.mic = a.mic || p.isRunningInput
            a.output = a.output || p.isRunningOutput
            a.pids.append(p.pid)
            out[id] = a
        }
        return out
    }
}

/// Live source of activity snapshots: polls Core Audio every `pollInterval` (per-process listeners don't fire on
/// macOS 26 — spike EM-004) and polls immediately when the process list changes (that listener does fire).
public final class AudioActivityMonitor: @unchecked Sendable {
    public let snapshots: AsyncStream<ActivitySnapshot>
    private let continuation: AsyncStream<ActivitySnapshot>.Continuation
    private let rules: RuleSet
    private let titles: WindowTitleSource
    private var browserTracker = BrowserMeetingTracker()          // queue-confined
    private let queue = DispatchQueue(label: "echominutes.detection.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var listener: AudioObjectPropertyListenerBlock?

    public init(rules: RuleSet, titles: WindowTitleSource = SystemWindowTitles()) {
        self.rules = rules
        self.titles = titles
        (snapshots, continuation) = AsyncStream.makeStream(of: ActivitySnapshot.self, bufferingPolicy: .bufferingNewest(4))
    }

    public func start() {
        queue.sync {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: rules.pollInterval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.poll() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, l)
            listener = l
        }
        Log.info(.detection, "Activity monitor started (poll \(rules.pollInterval)s, \(rules.rules.count) apps)")
    }

    public func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            if let listener {
                var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
            }
            listener = nil
        }
        continuation.finish()
    }

    private func poll() {
        let processes = AudioProcesses.current()
        var snap = ActivityAggregator.aggregate(processes, rules: rules)
        if rules.browserDetection {
            for (id, a) in browserTracker.update(processes: processes, rules: rules, now: Date(), titles: titles) { snap[id] = a }
        }
        continuation.yield(snap)
    }
}
