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
        let task = Task { try await recorder.stop() }
        await syncRecordingState()                      // shows "Saving…" while finalizing
        do {
            let s = try await task.value
            selectedSessionID = s.id
        } catch { lastError = error.localizedDescription }
        await syncRecordingState()
        reloadSessions()
    }

    public func discardRecording() async {
        do { try await recorder?.discard() } catch { lastError = error.localizedDescription }
        await syncRecordingState()
        reloadSessions()
    }

    public func recoverSession(_ id: SessionID) async {
        guard let paths, let database else { return }
        do { _ = try await ManualRecorder.recover(id, paths: paths, db: database) }
        catch { lastError = "Recovery failed: \(error.localizedDescription)" }
        reloadSessions()
    }

    public func syncRecordingState() async {
        recording = await recorder?.state ?? .idle
        switch recording {
        case .idle: status = .idle
        case .recording(let i): status = .recording(appName: i.appName, since: i.startedAt)
        case .paused(let i): status = .processing("Paused — \(i.appName)")
        case .finalizing: status = .processing("Saving recording…")
        }
    }
}

// MARK: - Menu section

struct RecordingMenuSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.recording {
        case .idle:
            Menu("Start Recording") {
                let apps = state.recordableApps()
                if apps.isEmpty { Text("No meeting app is running") }
                ForEach(apps) { app in
                    Button(app.name) { Task { await state.startRecording(app) } }
                }
            }
        case .recording(let i):
            Text("● Recording \(i.appName) — \(elapsed(i.startedAt))")
            Button("Pause") { Task { await state.pauseRecording() } }
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

    func stop() { player?.stop(); isPlaying = false; timer?.invalidate(); timer = nil }
}

struct SessionAudioView: View {
    let session: Session
    let directory: URL
    @State private var player = SessionAudioPlayer()
    @State private var peaks: [Float] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title) }
                    .buttonStyle(.plain)
                Text("\(fmt(player.currentTime)) / \(fmt(player.duration))").monospacedDigit().foregroundStyle(.secondary)
            }
            WaveformView(peaks: peaks, progress: player.duration > 0 ? player.currentTime / player.duration : 0) { player.seek(fraction: $0) }
                .frame(height: 56)
        }
        .onAppear {
            player.load(directory.appendingPathComponent("mixed.m4a"))
            peaks = AudioFinalizer.loadWaveform(directory.appendingPathComponent("waveform.bin"))
        }
        .onDisappear { player.stop() }
    }

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
