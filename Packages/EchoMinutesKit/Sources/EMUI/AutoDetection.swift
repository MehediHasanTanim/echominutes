import AVFoundation
import EMCore
import EMDetection
import EMSession
import EMStorage
import Foundation

// MARK: - AppState ⇄ meeting detection (EM-070, EM-072, EM-075, EM-076)

extension AppState {
    /// Bundled rules + the user's per-app overrides + private hours.
    public func currentRuleSet() -> RuleSet? {
        guard let rules else { return nil }
        var overrides: [String: RuleOverride] = [:]
        if let database, let saved = try? SettingsRepository(database).rules() {
            for (id, o) in saved { overrides[id] = RuleOverride(mode: o.mode, debounceSec: o.debounceSec, graceSec: o.graceSec) }
        }
        return RuleSet(base: rules, overrides: overrides, privateHours: DetectionPreferences.privateHours)
    }

    public func startDetection() {
        guard coordinator == nil else { return }
        guard DetectionPreferences.enabled, let recorder, let ruleSet = currentRuleSet() else {
            Task { await syncRecordingState() }
            return
        }
        let handler = AutoRecordingHandler(recorder: recorder, rules: ruleSet,
                                           micAllowed: { RecordingPreferences.includeMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized })
        let coord = DetectionCoordinator(rules: ruleSet, handler: handler)
        let monitor = AudioActivityMonitor(rules: ruleSet)
        let sleep = SystemEventsWatcher()
        autoHandler = handler; coordinator = coord; activityMonitor = monitor; sleepWatcher = sleep

        let snapshots = monitor.snapshots, updates = coord.updates, events = handler.events, sys = sleep.events
        detectionTasks = [
            Task { await coord.run(snapshots: snapshots) },
            Task { [weak self] in
                for await u in updates { await self?.detectionUpdated(u) }
            },
            Task { [weak self] in
                for await e in events { await self?.handleAutoEvent(e) }
            },
            Task {
                for await e in sys where e == .willSleep { await coord.systemWillSleep() }
            },
        ]
        sleep.start()
        monitor.start()
        detectionRunning = true
        Log.info(.app, "Meeting detection started")
        DetectionLogFile.note("detection started — " + ruleSet.rules.map {
            "\($0.id): \($0.mode.rawValue) \(Int($0.debounce))s/\(Int($0.grace))s"
        }.joined(separator: ", "), paths: paths)
        Task { await syncRecordingState() }
    }

    /// Turning detection off saves an auto recording that is in progress.
    public func stopDetection() async {
        guard let coordinator else { return }
        await coordinator.manualStop()          // saves an auto recording; cancels a candidate / pending ask
        await autoHandler?.waitForFinalize()
        activityMonitor?.stop(); sleepWatcher?.stop()
        detectionTasks.forEach { $0.cancel() }
        detectionTasks = []
        self.coordinator = nil; autoHandler = nil; activityMonitor = nil; sleepWatcher = nil
        detectionRunning = false
        detectionPhase = .idle
        Log.info(.app, "Meeting detection stopped")
        await syncRecordingState()
    }

    public func setDetectionEnabled(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: DetectionPreferences.enabledKey)
        if on { startDetection() } else { await stopDetection() }
    }

    /// Settings changed: push the new rules to the running detector.
    public func applyDetectionSettings() {
        guard let rs = currentRuleSet() else { return }
        let coord = coordinator, handler = autoHandler
        Task {
            await coord?.updateRules(rs)
            await handler?.updateRules(rs)
        }
    }

    /// Answer to "Record this call?" (menu or notification).
    public func respondToAsk(accept: Bool) async {
        await coordinator?.userResponded(accept: accept)
    }

    /// The meeting app currently being asked about, if any.
    public var askingAppName: String? {
        guard case .asking(let id, _, _) = detectionPhase else { return nil }
        return rules?.apps.first { $0.id == id }?.name ?? id
    }

    func detectionUpdated(_ u: DetectionCoordinator.Update) async {
        if u.phase != detectionPhase { detectionPhase = u.phase }
        if u.snapshot != lastSnapshot { lastSnapshot = u.snapshot }
        if !u.newDecisions.isEmpty {
            detectionLog.append(contentsOf: u.newDecisions)
            if detectionLog.count > 500 { detectionLog.removeFirst(detectionLog.count - 500) }
            DetectionLogFile.append(u.newDecisions, paths: paths)
        }
        await syncRecordingState()
    }

    func handleAutoEvent(_ e: AutoRecordingEvent) async {
        switch e {
        case .started(let sid, _, let appName):
            notifier.recordingStarted(sessionID: sid, appName: appName)
            notifier.consentReminder(appName: appName)
            reloadSessions()
        case .saved(let sid, let title, let dur):
            notifier.recordingSaved(sessionID: sid, title: title, durationSec: dur)
            reloadSessions()
            recordingSaved(sid)
        case .discarded:
            notifier.removeRecordingStarted()
            reloadSessions()
        case .ask(let id, let appName):
            notifier.ask(appID: id, appName: appName)
        case .dismissAsk(let id):
            notifier.removeAsk(appID: id)
        case .otherApp(let appName, let recordingAppName):
            notifier.otherApp(appName: appName, recordingAppName: recordingAppName)
        case .failed(let msg):
            lastError = msg
            notifier.failed(msg)
        case .stateChanged:
            break
        }
        await syncRecordingState()
    }
}
