import AVFoundation
import EMAudio
import EMCore
import Observation
import SwiftUI

/// Debug window (EM-047 demo): start capturing an app + mic and watch two live level meters.
@MainActor
@Observable
public final class DebugCaptureModel {
    public var levels: RecordingService.Levels?
    public var session: RecordingService.Session?
    public var error: String?
    public var running = false
    private let recorder = RecordingService()
    private var levelTask: Task<Void, Never>?

    public init() {}

    public static func targetApps() -> [DetectionRules.App] {
        var apps = DetectionRules.bundled()?.apps ?? []
        apps.append(DetectionRules.App(id: "chrome", name: "Google Chrome (test)", bundlePrefixes: ["com.google.Chrome"]))
        apps.append(DetectionRules.App(id: "music", name: "Music (test)", bundlePrefixes: ["com.apple.Music"]))
        return apps
    }

    public func start(_ app: DetectionRules.App, includeMic: Bool) async {
        error = nil
        if includeMic, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Microphone permission denied"; return }
        }
        do {
            session = try await recorder.start(app: app, includeMic: includeMic)
            running = true
            let stream = recorder.levels   // nonisolated: AsyncStream is Sendable
            levelTask = Task { [weak self] in
                for await l in stream { self?.levels = l }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func stop() async {
        await recorder.stop()
        levelTask?.cancel(); levelTask = nil
        running = false
    }
}

public struct DebugCaptureView: View {
    public static let windowID = "debug-capture"
    @State private var model = DebugCaptureModel()
    @State private var apps = DebugCaptureModel.targetApps()
    @State private var selectedID = "teams"
    @State private var includeMic = true

    public init() {}

    public var body: some View {
        Form {
            Section("Target") {
                Picker("App", selection: $selectedID) {
                    ForEach(apps) { Text($0.name).tag($0.id) }
                }
                .disabled(model.running)
                Toggle("Also record microphone", isOn: $includeMic).disabled(model.running)
                HStack {
                    Button(model.running ? "Stop" : "Start capture") {
                        Task {
                            if model.running { await model.stop() }
                            else if let app = apps.first(where: { $0.id == selectedID }) { await model.start(app, includeMic: includeMic) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    if let e = model.error { Text(e).foregroundStyle(.red).font(.caption) }
                }
            }
            if let s = model.session {
                Section("Session") {
                    LabeledContent("Processes", value: s.processes.map { "\($0.executable) (\($0.pid))" }.joined(separator: ", "))
                    LabeledContent("Devices", value: s.deviceSummary)
                }
            }
            if let l = model.levels {
                Section("Levels") {
                    LevelRow(label: "System (\(model.session?.app.name ?? "app"))", db: l.systemDB, warn: l.systemSilenceWarning)
                    if includeMic { LevelRow(label: "Microphone", db: l.micDB, warn: l.micSilenceWarning) }
                    LabeledContent("Elapsed", value: String(format: "%.1f s", l.elapsed))
                    LabeledContent("Sample rate", value: "\(Int(l.sampleRate)) Hz")
                    LabeledContent("IO callbacks / overruns", value: "\(l.callbacks) / \(l.overruns)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onDisappear { Task { await model.stop() } }
    }
}

struct LevelRow: View {
    let label: String
    let db: Float
    let warn: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f dBFS", db)).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(db > -6 ? Color.red : db > -20 ? Color.orange : Color.green)
                        .frame(width: g.size.width * CGFloat(max(0, min(1, (db + 60) / 60))))
                }
            }
            .frame(height: 8)
            if warn { Text("No audio for 60 s — check the app is playing and permissions are granted.").font(.caption).foregroundStyle(.orange) }
        }
    }
}
