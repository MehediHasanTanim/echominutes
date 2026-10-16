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
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        // A detection candidate holds the capture; the user's explicit Start wins.
        if case .candidate = await recorder.state { await recorder.cancelCandidate() }
        do {
            try await recorder.start(app: app, includeMic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
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

// MARK: - Simple player + waveform for a finished session (full player in EM-122)

@MainActor
@Observable
final class SessionAudioPlayer {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false; timer?.invalidate() }
        else {
            player.play(); isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.player else { return }
                    self.currentTime = p.currentTime
                    if !p.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
                }
            }
        }
    }

    func seek(fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        currentTime = player.currentTime
    }

    func seek(seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, seconds))
        currentTime = player.currentTime
    }

    func stop() { player?.stop(); isPlaying = false; timer?.invalidate(); timer = nil }
}

struct SessionAudioView: View {
    let session: Session
    let directory: URL
    @State private var player = SessionAudioPlayer()
    @State private var peaks: [Float] = []
    @State private var manifest: RecordingManifest?
    @State private var remixing = false
    @State private var remixError: String?
    @State private var bookmarks: [Bookmark] = []
    @State private var handledNonce = 0
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title) }
                    .buttonStyle(.plain)
                Text("\(fmt(player.currentTime)) / \(fmt(player.duration))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if remixing { ProgressView().controlSize(.small) }
                Button(manifest?.mix == nil ? "Balance voice levels" : "Rebuild mix") { Task { await remix() } }
                    .disabled(remixing || player.isPlaying)
            }
            WaveformView(peaks: peaks, progress: player.duration > 0 ? player.currentTime / player.duration : 0) { player.seek(fraction: $0) }
                .frame(height: 56)
            if !bookmarks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(bookmarks) { b in
                            Button {
                                state.play(session.id, atMs: b.atMs)
                            } label: {
                                Label(fmt(Double(b.atMs) / 1000), systemImage: "bookmark.fill")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help(b.note ?? "Jump to bookmark")
                        }
                    }
                }
            }
            if let mix = manifest?.mix {
                Text("Levels — you: \(db(mix.micLevelDB)) → \(gain(mix.micGainDB)) · others: \(db(mix.systemLevelDB)) → \(gain(mix.systemGainDB))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let devices = manifest?.devices {
                Text("Devices: \(devices)").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            if let remixError { Text(remixError).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { load(); honour(state.playRequest) }        // request made before this view existed (search hit)
        .onDisappear { player.stop() }
        .onChange(of: state.playRequest) { _, r in honour(r) }
    }

    private func honour(_ r: AppState.PlayRequest?) {
        guard let r, r.sessionID == session.id, r.nonce != handledNonce else { return }
        handledNonce = r.nonce
        player.seek(seconds: Double(r.ms) / 1000)
        if !player.isPlaying { player.toggle() }
    }

    private func load() {
        player.load(directory.appendingPathComponent("mixed.m4a"))
        peaks = AudioFinalizer.loadWaveform(directory.appendingPathComponent("waveform.bin"))
        manifest = try? RecordingManifest.load(from: directory)
        bookmarks = state.bookmarks(for: session.id)
    }

    private func remix() async {
        remixing = true; remixError = nil
        player.stop()
        let dir = directory
        do { _ = try await Task.detached(priority: .userInitiated) { try AudioFinalizer.remix(sessionDirectory: dir) }.value }
        catch { remixError = "Rebuild failed: \(error.localizedDescription)" }
        load()
        remixing = false
    }

    private func db(_ v: Float?) -> String { v.map { String(format: "%.0f dBFS", $0) } ?? "silent" }
    private func gain(_ v: Float) -> String { String(format: "%+.0f dB", v) }

    private func fmt(_ t: TimeInterval) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let bars = max(1, Int(size.width / 3))
                let per = max(1, peaks.count / bars)
                for b in 0..<min(bars, peaks.count) {
                    let slice = peaks[(b * per)..<min(peaks.count, (b + 1) * per)]
                    let h = max(1, CGFloat(slice.max() ?? 0) * size.height)
                    let x = CGFloat(b) * 3
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: 2, height: h)
                    ctx.fill(Path(rect), with: .color(Double(b) / Double(bars) <= progress ? Color.accentColor : Color.gray.opacity(0.5)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { onSeek($0.location.x / g.size.width) })
        }
    }
}
