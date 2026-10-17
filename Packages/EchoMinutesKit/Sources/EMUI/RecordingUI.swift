import AVFoundation
import EMAudio
import EMCore
import EMSession
import Observation
import SwiftUI

// MARK: - AppState recording API (EM-055 manual recording, EM-056 recovery)

extension AppState {
    /// Apps that currently have audio processes and can be recorded.
    public func recordableApps() -> [DetectionRules.App] {
        var apps = rules?.apps ?? []
        #if DEBUG
        apps.append(DetectionRules.App(id: "chrome", name: "Google Chrome (test)", bundlePrefixes: ["com.google.Chrome"]))
        apps.append(DetectionRules.App(id: "music", name: "Music (test)", bundlePrefixes: ["com.apple.Music"]))
        #endif
        let procs = AudioProcesses.current()
        return apps.filter { !AudioProcesses.resolve($0, in: procs).isEmpty }
    }

    public func startRecording(_ app: DetectionRules.App) async {
        guard let recorder else { lastError = "Library unavailable"; return }
        lastError = nil
        if RecordingPreferences.includeMic, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        // A detection candidate holds the capture; the user's explicit Start wins.
        if case .candidate = await recorder.state { await recorder.cancelCandidate() }
        do {
            try await recorder.start(app: app, includeMic: RecordingPreferences.includeMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
            notifier.consentReminder(appName: app.name)
            await syncRecordingState()
            reloadSessions()
        } catch { lastError = error.localizedDescription }
    }

    public func pauseRecording() async { do { try await recorder?.pause() } catch { lastError = error.localizedDescription }; await syncRecordingState() }
    public func resumeRecording() async { do { try await recorder?.resume() } catch { lastError = error.localizedDescription }; await syncRecordingState() }

    public func stopRecording() async {
        guard let recorder else { return }
        // Auto recordings stop through detection, so the same call isn't immediately re-detected.
        if recording.info?.origin == .auto, case .recording = detectionPhase, let coordinator {
            await coordinator.manualStop()
            await syncRecordingState()
            return
        }
        let task = Task { try await recorder.stop() }
        await syncRecordingState()                      // shows "Saving…" while finalizing
        do {
            let s = try await task.value
            selectedSessionID = s.id
            recordingSaved(s.id)
        } catch { lastError = error.localizedDescription }
        await syncRecordingState()
        reloadSessions()
    }

    public func discardRecording() async {
        if recording.info?.origin == .auto, case .recording = detectionPhase, let coordinator {
            await coordinator.manualDiscard()
            await syncRecordingState()
            return
        }
        do { try await recorder?.discard() } catch { lastError = error.localizedDescription }
        await syncRecordingState()
        reloadSessions()
    }

    public func recoverSession(_ id: SessionID) async {
        guard let paths, let database else { return }
        do { _ = try await ManualRecorder.recover(id, paths: paths, db: database); recordingSaved(id) }
        catch { lastError = "Recovery failed: \(error.localizedDescription)" }
        reloadSessions()
    }

    public func syncRecordingState() async {
        let r = await recorder?.state ?? .idle
        if r != recording { recording = r }
        let newStatus: AppStatus
        switch r {
        case .idle, .candidate: newStatus = detectionRunning ? .monitoring : .idle
        case .recording(let i): newStatus = .recording(appName: i.appName, since: i.startedAt)
        case .paused(let i): newStatus = .processing("Paused — \(i.appName)")
        case .finalizing: newStatus = .processing("Saving recording…")
        }
        if newStatus != status { status = newStatus }
        recordingStateDidChange()
    }
}

// MARK: - Menu section

struct RecordingMenuSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let app = state.askingAppName {
            Text("Record this \(app) call?")
            Button("Record") { Task { await state.respondToAsk(accept: true) } }
            Button("Ignore") { Task { await state.respondToAsk(accept: false) } }
            Divider()
        }
        switch state.recording {
        case .idle, .candidate:
            if case .candidate(let i) = state.recording { Text("Detecting \(i.appName) call…") }
            Menu("Start Recording") {
                let apps = state.recordableApps()
                if apps.isEmpty { Text("No meeting app is running") }
                ForEach(apps) { app in
                    Button(app.name) { Task { await state.startRecording(app) } }
                }
            }
        case .recording(let i):
            Text("● Recording \(i.appName) — \(elapsed(i.startedAt))\(i.origin == .auto ? " (auto)" : "")")
            Button("Pause") { Task { await state.pauseRecording() } }
            Button("Add Bookmark") { Task { await state.addBookmark() } }
            Button("Show / Hide Mini Widget") { state.toggleMiniWidget() }
            Button("Stop & Save") { Task { await state.stopRecording() } }.keyboardShortcut("s")
            Button("Discard Recording", role: .destructive) { Task { await state.discardRecording() } }
        case .paused(let i):
            Text("⏸ Paused — \(i.appName)")
            Button("Resume") { Task { await state.resumeRecording() } }
            Button("Stop & Save") { Task { await state.stopRecording() } }
            Button("Discard Recording", role: .destructive) { Task { await state.discardRecording() } }
        case .finalizing:
            Text("Saving recording…")
        }
        Toggle("Auto-record Meetings", isOn: Binding(
            get: { state.detectionRunning },
            set: { on in Task { await state.setDetectionEnabled(on) } }))
        if let e = state.lastError { Text("⚠︎ \(e)") }
    }

    private func elapsed(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

