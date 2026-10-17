import AppKit
import EMAudio
import EMCore
import EMStorage
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Diagnostics (EM-132): permissions, 5-second audio test, detection monitor, redacted log bundle.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var perms = PermissionsModel()
    @State private var exporting = false
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "Your voice", status: perms.mic,
                              actionTitle: perms.mic == .granted ? nil : "Allow", onAction: { Task { await perms.requestMic() } },
                              settings: { PermissionsModel.open(.microphone) })
                PermissionRow(title: "System audio recording", detail: "Other people on the call — checked by the audio test",
                              status: perms.systemAudio, actionTitle: nil, settings: { PermissionsModel.open(.systemAudio) })
                PermissionRow(title: "Window titles (Screen Recording)", detail: "Optional — recognises Google Meet / Teams / Zoom in a browser",
                              status: perms.screenRecording, actionTitle: perms.screenRecording == .granted ? nil : "Allow",
                              onAction: { Task { await perms.requestScreenRecording() } },
                              settings: { PermissionsModel.open(.systemAudio) })
                PermissionRow(title: "Notifications", detail: "Recording started / saved, summaries", status: perms.notifications,
                              actionTitle: perms.notifications == .granted ? nil : "Allow", onAction: { Task { await perms.requestNotifications() } },
                              settings: { PermissionsModel.open(.notifications) })
            }
            Section("Audio test") {
                HStack {
                    Button(perms.testing ? "Testing… (say something)" : "Run 5-second audio test") { Task { await perms.runAudioTest() } }
                        .disabled(perms.testing || state.recording.isActive)
                    if perms.testing { ProgressView().controlSize(.small) }
                }
                Text("Plays a quiet tone and records it the way a call is recorded, while measuring your microphone. Speak during the test.")
                    .font(.caption).foregroundStyle(.secondary)
                if let r = perms.lastTest {
                    if let e = r.error { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
                    else {
                        Label(String(format: "Call audio: %.0f dBFS — %@", r.systemPeakDB, r.systemOK ? "OK" : "nothing captured (check System Audio Recording permission)"),
                              systemImage: r.systemOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.systemOK ? .green : .red)
                        if let m = r.micPeakDB {
                            Label(String(format: "Microphone: %.0f dBFS — %@", m, r.micOK ? "OK" : "silent (wrong input device or muted?)"),
                                  systemImage: r.micOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.micOK ? .green : .orange)
                        }
                        Text("Devices: \(r.device)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section("Detection & logs") {
                Button("Open Detection Monitor") { openWindow(id: DetectionMonitorView.windowID); NSApp.activate() }
                HStack {
                    Button(exporting ? "Collecting…" : "Export diagnostics bundle…") { Task { await exportBundle() } }.disabled(exporting)
                    if exporting { ProgressView().controlSize(.small) }
                }
                Text("A .zip with the last 24 h of app logs, the detection log, recent recording manifests and settings — API keys and tokens are removed. Nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                if let exportResult { Text(exportResult).font(.caption).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task { await perms.refresh() }
    }

    private func exportBundle() async {
        guard let paths = state.paths else { return }
        let panel = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "EchoMinutes-diagnostics-\(df.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true; exportResult = nil
        let settings = settingsSummary()
        do {
            try await Task.detached(priority: .userInitiated) { try DiagnosticsBundle.write(to: url, paths: paths, settings: settings) }.value
            exportResult = "Saved \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { exportResult = "Export failed: \(error.localizedDescription)" }
        exporting = false
    }

    /// Non-secret settings only (key presence, never the key).
    private func settingsSummary() -> String {
        var lines = ["app: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "detection: \(DetectionPreferences.enabled)", "auto-transcribe: \(TranscriptionPreferences.current.autoTranscribe)",
                     "stt model: \(TranscriptionPreferences.current.model) lang \(TranscriptionPreferences.current.language)",
                     "summary provider: \(LLMPreferences.summaryProvider?.rawValue ?? "none")"]
        for p in ProviderID.allCases {
            let c = state.providerConfig(p)
            lines.append("provider \(p.rawValue): key \(state.hasAPIKey(p) ? "set" : "none"), model \(c.model ?? "-"), base \(c.baseURL ?? "-")")
        }
        lines.append("sessions: \(state.sessions.count)")
        return lines.joined(separator: "\n")
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionsModel.Status
    let actionTitle: String?
    var onAction: () -> Void = {}
    let settings: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status.symbol).foregroundStyle(status == .granted ? .green : status == .denied ? .red : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle { Button(actionTitle, action: onAction).controlSize(.small) }
            Button("System Settings…", action: settings).controlSize(.small)
        }
    }
}

/// Builds the redacted .zip (runs off the main thread).
enum DiagnosticsBundle {
    static func write(to zip: URL, paths: AppPaths, settings: String) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("EchoMinutes-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func save(_ text: String, _ name: String) throws {
            try Redactor.redact(text).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try save(settings, "settings.txt")
        try save(run("/usr/bin/log", ["show", "--last", "24h", "--info", "--style", "compact",
                                      "--predicate", "subsystem == \"com.tanimkabir.echominutes\""]), "app-log.txt")
        try save(run("/usr/bin/sw_vers", []) + run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]), "system.txt")
        if let d = try? String(contentsOf: paths.logsDir.appendingPathComponent("detection.log"), encoding: .utf8) { try save(d, "detection.log") }
        let sessions = (try? fm.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let recent = sessions.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(5)
        for s in recent {
            if let m = try? String(contentsOf: s.appendingPathComponent("manifest.json"), encoding: .utf8) {
                try save(m, "manifest-\(s.lastPathComponent).json")
            }
        }
        // Crash reports of this app (last 7 days)
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        for f in (try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.lastPathComponent.hasPrefix("EchoMinutes") {
            if let date = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date > Date().addingTimeInterval(-7 * 86_400) {
                try? fm.copyItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent))
            }
        }
        try? fm.removeItem(at: zip)
        _ = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dir.path, zip.path])
        guard fm.fileExists(atPath: zip.path) else { throw EMError.invalidData("zip was not created") }
    }

    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "(\(tool) failed: \(error))\n" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
