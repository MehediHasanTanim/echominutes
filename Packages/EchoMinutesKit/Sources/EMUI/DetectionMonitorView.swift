import AppKit
import EMCore
import EMDetection
import EMSession
import SwiftUI

/// Debug window: the app's live detector — per-app mic/output, current phase and every decision with its reason
/// code (EM-067, used for real-call tuning in EM-077). Decisions are also appended to Logs/detection.log.
public struct DetectionMonitorView: View {
    public static let windowID = "detection-monitor"
    @Environment(AppState.self) private var state

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if state.detectionRunning {
                appTable
                Divider()
                decisionList
            } else {
                ContentUnavailableView("Auto-record is off", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Turn on Auto-record Meetings in the menu to watch detection live."))
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(phaseColor).frame(width: 12, height: 12)
            Text(phaseText).font(.headline)
            Spacer()
            if state.askingAppName != nil {
                Button("Record") { Task { await state.respondToAsk(accept: true) } }
                Button("Ignore") { Task { await state.respondToAsk(accept: false) } }
            }
            if state.recording.isActive {
                Button("Stop") { Task { await state.stopRecording() } }
                Button("Discard") { Task { await state.discardRecording() } }
            }
        }
    }

    private var appTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("App"); Text("Mode"); Text("Start / Stop after"); Text("Mic"); Text("Output"); Text("PIDs")
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(state.currentRuleSet()?.rules ?? []) { r in
                let a = state.lastSnapshot[r.id]
                GridRow {
                    Text(r.app.name)
                    Text(r.mode.rawValue).foregroundStyle(.secondary)
                    Text("\(Int(r.debounce)) s / \(Int(r.grace)) s").monospacedDigit().foregroundStyle(.secondary)
                    dot(a?.mic == true, color: .red)
                    dot(a?.output == true, color: .blue)
                    Text(a.map { $0.pids.map(String.init).joined(separator: ",") } ?? "not running")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var decisionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Decisions").font(.headline)
                Spacer()
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText(), forType: .string)
                }
                .disabled(state.detectionLog.isEmpty)
                if let url = DetectionLogFile.url(state.paths) {
                    Button("Show log file") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            if state.detectionLog.isEmpty {
                Text("Nothing yet — start a call (or a voice note) in Teams, Zoom or WhatsApp.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(state.detectionLog.reversed().enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(d.at.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                        Text(d.reason.rawValue).font(.body.monospaced()).foregroundStyle(color(for: d.reason))
                        Text(name(d.appID))
                        if let detail = d.detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .listStyle(.bordered)
            }
        }
    }

    private func logText() -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        return state.detectionLog.map { d in
            "\(f.string(from: d.at))  \(d.reason.rawValue)  \(d.appID ?? "-")\(d.detail.map { "  (\($0))" } ?? "")"
        }.joined(separator: "\n")
    }

    private func name(_ id: String?) -> String {
        guard let id else { return "—" }
        return state.rules?.apps.first { $0.id == id }?.name ?? id
    }

    private func dot(_ on: Bool, color: Color) -> some View {
        Circle().fill(on ? color : Color.secondary.opacity(0.25)).frame(width: 10, height: 10)
    }

    private var phaseText: String {
        switch state.detectionPhase {
        case .idle: state.detectionRunning ? "Idle — watching" : "Detection off"
        case .candidate(let a, let since): "Candidate: \(name(a)) (mic on since \(since.formatted(date: .omitted, time: .standard)))"
        case .asking(let a, _, _): "Asking: record \(name(a))?"
        case .recording(let a, let since): "Recording \(name(a)) since \(since.formatted(date: .omitted, time: .standard))"
        }
    }

    private var phaseColor: Color {
        switch state.detectionPhase {
        case .idle: .secondary
        case .candidate: .yellow
        case .asking: .orange
        case .recording: .red
        }
    }

    private func color(for r: DecisionReason) -> Color {
        switch r {
        case .startedAuto, .startedUserAccepted: .red
        case .candidateMicOn, .askedUser: .orange
        case .endedGrace, .endedMicOffLong, .endedAppQuit, .endedSleep, .endedManual: .green
        default: .secondary
        }
    }
}
