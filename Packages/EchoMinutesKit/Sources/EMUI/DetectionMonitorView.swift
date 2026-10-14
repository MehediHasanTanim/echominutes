import AppKit
import EMCore
import EMDetection
import EMSession
import Observation
import SwiftUI

/// Debug window (Sprint 5 demo): live per-app mic/output + the state machine's decisions. Observe-only —
/// effects are logged, nothing is recorded (real recording is wired in EM-070).
@MainActor
@Observable
public final class DetectionMonitorModel {
    public struct Row: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var mode: RecordingMode
        public var debounce: TimeInterval
        public var grace: TimeInterval
        public var activity: AppActivity?
    }

    public private(set) var running = false
    public private(set) var rows: [Row] = []
    public private(set) var phase: MeetingStateMachine.Phase = .idle
    public private(set) var decisions: [Decision] = []   // newest first
    public private(set) var lastPoll: Date?
    public var error: String?

    private var monitor: AudioActivityMonitor?
    private var events: SystemEventsWatcher?
    private var coordinator: DetectionCoordinator?
    private var tasks: [Task<Void, Never>] = []
    private var names: [String: String] = [:]

    public init() {}

    public func start() {
        guard !running else { return }
        guard let base = DetectionRules.bundled() else { error = "DetectionRules.json missing from bundle"; return }
        let rules = RuleSet(base: base)
        names = Dictionary(uniqueKeysWithValues: rules.rules.map { ($0.id, $0.app.name) })
        rows = rules.rules.map { Row(id: $0.id, name: $0.app.name, mode: $0.mode, debounce: $0.debounce, grace: $0.grace) }
        decisions = []
        phase = .idle
        error = nil

        let mon = AudioActivityMonitor(rules: rules)
        let ev = SystemEventsWatcher()
        let coord = DetectionCoordinator(rules: rules)
        monitor = mon; events = ev; coordinator = coord

        let snapshots = mon.snapshots
        let updates = coord.updates
        let sysEvents = ev.events
        tasks = [
            Task { await coord.run(snapshots: snapshots) },
            Task { [weak self] in
                for await u in updates { self?.apply(u) }
            },
            Task {
                for await e in sysEvents where e == .willSleep { await coord.systemWillSleep() }
            },
        ]
        ev.start()
        mon.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        monitor?.stop()
        events?.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        monitor = nil; events = nil; coordinator = nil
        running = false
    }

    public func manualStop() { if let c = coordinator { Task { await c.manualStop() } } }
    public func manualDiscard() { if let c = coordinator { Task { await c.manualDiscard() } } }
    public func respond(accept: Bool) { if let c = coordinator { Task { await c.userResponded(accept: accept) } } }

    public func name(_ appID: String?) -> String { appID.map { names[$0] ?? $0 } ?? "—" }

    /// Plain-text log of the decisions (oldest first) for pasting into a bug report.
    public func logText() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return decisions.reversed().map { d in
            "\(f.string(from: d.at))  \(d.reason.rawValue)  \(d.appID ?? "-")\(d.detail.map { "  (\($0))" } ?? "")"
        }.joined(separator: "\n")
    }

    private func apply(_ u: DetectionCoordinator.Update) {
        phase = u.phase
        lastPoll = Date()
        for i in rows.indices { rows[i].activity = u.snapshot[rows[i].id] }
        if !u.newDecisions.isEmpty {
            decisions.insert(contentsOf: u.newDecisions.reversed(), at: 0)
            if decisions.count > 300 { decisions.removeLast(decisions.count - 300) }
        }
    }
}

public struct DetectionMonitorView: View {
    public static let windowID = "detection-monitor"
    @State private var model = DetectionMonitorModel()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            appTable
            Divider()
            decisionList
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 520)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(phaseColor).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseText).font(.headline)
                Text("Observe-only: decisions are logged, nothing is recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .asking = model.phase {
                Button("Accept") { model.respond(accept: true) }
                Button("Decline") { model.respond(accept: false) }
            }
            if case .recording = model.phase {
                Button("Stop") { model.manualStop() }
                Button("Discard") { model.manualDiscard() }
            }
            Button(model.running ? "Pause" : "Start") { model.running ? model.stop() : model.start() }
        }
    }

    private var appTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("App"); Text("Mode"); Text("Debounce / Grace"); Text("Mic"); Text("Output"); Text("PIDs")
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(model.rows) { r in
                GridRow {
                    Text(r.name)
                    Text(r.mode.rawValue).foregroundStyle(.secondary)
                    Text("\(Int(r.debounce)) s / \(Int(r.grace)) s").monospacedDigit().foregroundStyle(.secondary)
                    dot(r.activity?.mic == true, color: .red)
                    dot(r.activity?.output == true, color: .blue)
                    Text(r.activity.map { $0.pids.map(String.init).joined(separator: ",") } ?? "not running")
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
                if let t = model.lastPoll {
                    Text("last poll \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText(), forType: .string)
                }
                .disabled(model.decisions.isEmpty)
            }
            if model.decisions.isEmpty {
                Text("Nothing yet — start a call (or a voice note) in Teams, Zoom or WhatsApp.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(model.decisions.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(d.at.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                        Text(d.reason.rawValue).font(.body.monospaced()).foregroundStyle(color(for: d.reason))
                        Text(model.name(d.appID))
                        if let detail = d.detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .listStyle(.bordered)
            }
            if let e = model.error { Text(e).foregroundStyle(.red) }
        }
    }

    private func dot(_ on: Bool, color: Color) -> some View {
        Circle().fill(on ? color : Color.secondary.opacity(0.25)).frame(width: 10, height: 10)
    }

    private var phaseText: String {
        switch model.phase {
        case .idle: model.running ? "Idle — watching" : "Paused"
        case .candidate(let a, let since): "Candidate: \(model.name(a)) (mic on since \(since.formatted(date: .omitted, time: .standard)))"
        case .asking(let a, _, _): "Asking: record \(model.name(a))?"
        case .recording(let a, let since): "Would be recording: \(model.name(a)) since \(since.formatted(date: .omitted, time: .standard))"
        }
    }

    private var phaseColor: Color {
        switch model.phase {
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
