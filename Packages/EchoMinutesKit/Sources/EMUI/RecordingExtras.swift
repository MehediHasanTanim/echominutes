import AVFoundation
import EMAudio
import EMCore
import EMDetection
import EMSession
import EMStorage
import Foundation

// MARK: - Live levels, mini widget, bookmarks, hotkey actions (EM-073, EM-074)

public enum MiniWidgetPreferences {
    public static let enabledKey = "miniWidget.enabled"
    public static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
}

extension AppState {
    /// Called after every recorder state sync: meters, widget, per-recording counters.
    func recordingStateDidChange() {
        let active = recording.isActive
        let sid = recording.info?.sessionID
        if active, sid != lastActiveSessionID { bookmarksThisRecording = 0 }
        lastActiveSessionID = active ? sid : nil

        if active, levelTask == nil, let recorder {
            levelTask = Task { [weak self] in
                while !Task.isCancelled {
                    let l = await recorder.levels
                    guard let self else { return }
                    if l != self.levels { self.levels = l }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else if !active, let t = levelTask {
            t.cancel(); levelTask = nil; levels = nil
        }

        if active, MiniWidgetPreferences.enabled { miniWidget.show(state: self) }
        else if !active { miniWidget.hide() }
    }

    public func addBookmark() async {
        guard let recorder else { return }
        do {
            try await recorder.addBookmark()
            bookmarksThisRecording += 1
        } catch {
            lastError = "Bookmark failed: \(error.localizedDescription)"
        }
    }

    public func bookmarks(for id: SessionID) -> [Bookmark] {
        guard let database else { return [] }
        return (try? SessionRepository(database).bookmarks(id)) ?? []
    }

    /// Hotkey: stop the active recording, or start recording the meeting app that is using the mic.
    public func toggleRecording() async {
        if recording.isActive { await stopRecording(); return }
        let apps = recordableApps()
        let micApp = lastSnapshot.values.first { $0.mic }.flatMap { a in apps.first { $0.id == a.appID } }
        guard let app = micApp ?? apps.first else {
            lastError = "No meeting app is running"
            notifier.failed("No meeting app is running to record.")
            return
        }
        await startRecording(app)
    }

    public func toggleMiniWidget() {
        let on = !MiniWidgetPreferences.enabled
        UserDefaults.standard.set(on, forKey: MiniWidgetPreferences.enabledKey)
        if on, recording.isActive { miniWidget.show(state: self) } else { miniWidget.hide() }
    }

    public func registerHotKeys() {
        HotKeyCenter.shared.registerDefaults(
            toggleRecording: { [weak self] in Task { await self?.toggleRecording() } },
            bookmark: { [weak self] in Task { await self?.addBookmark() } },
            toggleWidget: { [weak self] in self?.toggleMiniWidget() })
    }
}

/// Appends detection decisions to `<library>/logs/detection.log` for real-call tuning (EM-077).
enum DetectionLogFile {
    static func url(_ paths: AppPaths?) -> URL? {
        paths?.logsDir.appendingPathComponent("detection.log")
    }

    static func append(_ decisions: [Decision], paths: AppPaths?) {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        write(decisions.map { d in
            "\(f.string(from: d.at))  \(d.reason.rawValue)  \(d.appID ?? "-")\(d.detail.map { "  (\($0))" } ?? "")\n"
        }.joined(), paths: paths)
    }

    /// Comment line (ignored by the report), e.g. when detection starts with its effective timings.
    static func note(_ text: String, paths: AppPaths?) {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        write("# \(f.string(from: Date()))  \(text)\n", paths: paths)
    }

    private static func write(_ text: String, paths: AppPaths?) {
        guard let url = url(paths) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: Data(text.utf8))
            } else {
                try Data(text.utf8).write(to: url)
            }
        } catch {
            Log.error(.detection, "Writing detection.log failed: \(error)")
        }
    }
}
