import EMCore
import EMDetection
import EMStorage
import SwiftUI

/// Settings ▸ Detection (EM-075): master switch, per-app mode and timings, private hours.
struct DetectionSettingsView: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let defaultDebounce: Double
        let defaultGrace: Double
        var mode: RecordingMode
        var debounce: Double
        var grace: Double
        var localOnly: Bool
    }

    @Environment(AppState.self) private var state
    @AppStorage(DetectionPreferences.enabledKey) private var enabled = true
    @AppStorage(DetectionPreferences.privateHoursOnKey) private var privateOn = false
    @AppStorage(DetectionPreferences.privateHoursStartKey) private var privateStart = 22 * 60
    @AppStorage(DetectionPreferences.privateHoursEndKey) private var privateEnd = 7 * 60
    @AppStorage(DetectionPreferences.browserEnabledKey) private var browserOn = true
    @State private var titlesAllowed = SystemWindowTitles.permitted
    @State private var perms = PermissionsModel()
    @State private var rows: [Row] = []
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Automatically record meetings", isOn: $enabled)
                    .onChange(of: enabled) { _, on in Task { await state.setDetectionEnabled(on) } }
                Text("A call is detected when a watched app turns on the microphone. Recording starts after the start delay (the audio from the beginning is kept) and stops when the call has been silent for the stop delay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser meetings") {
                Toggle("Detect meetings in web browsers (Google Meet, Teams and Zoom on the web)", isOn: $browserOn)
                    .onChange(of: browserOn) { Task { await state.restartDetection(); load() } }
                if browserOn {
                    HStack {
                        Image(systemName: titlesAllowed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(titlesAllowed ? .green : .secondary)
                        Text(titlesAllowed ? "Window titles readable — meetings are recognised by their tab"
                                           : "Window titles not readable — you'll be asked “Browser is using the microphone — record?”")
                        Spacer()
                        if !titlesAllowed {
                            Button("Allow…") { Task { await perms.requestScreenRecording(); titlesAllowed = SystemWindowTitles.permitted } }
                        }
                    }
                    Text("Needs Screen & System Audio Recording permission for EchoMinutes (only window titles are read — nothing on screen is recorded). After allowing it, quit and reopen EchoMinutes. The meeting must be the visible tab of a browser window; otherwise you get the question instead. Recording captures all audio of that browser, so pause other tabs that play sound.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Watched apps") {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.name).bold()
                            Spacer()
                            Picker("", selection: $row.mode) {
                                Text("Auto").tag(RecordingMode.auto)
                                Text("Ask first").tag(RecordingMode.ask)
                                Text("Never").tag(RecordingMode.never)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                        }
                        if row.mode != .never {
                            HStack(spacing: 20) {
                                Stepper("Start after \(Int(row.debounce)) s", value: $row.debounce, in: 2...60, step: 1)
                                Stepper("Stop after \(Int(row.grace)) s", value: $row.grace, in: 5...300, step: 5)
                                Toggle("Local only", isOn: $row.localOnly)
                                    .help("Summaries of this app's meetings use Ollama on this Mac only — nothing is sent to a cloud provider")
                                if row.debounce != row.defaultDebounce || row.grace != row.defaultGrace {
                                    Button("Reset") { row.debounce = row.defaultDebounce; row.grace = row.defaultGrace }
                                        .buttonStyle(.link)
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Private hours") {
                Toggle("Never auto-record during these hours", isOn: $privateOn)
                if privateOn {
                    DatePicker("From", selection: timeBinding($privateStart), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding($privateEnd), displayedComponents: .hourAndMinute)
                }
            }
            if let saveError { Text(saveError).foregroundStyle(.red).font(.caption) }
        }
        .formStyle(.grouped)
        .onAppear { load(); titlesAllowed = SystemWindowTitles.permitted }
        .onChange(of: rows) { old, new in if !old.isEmpty { save(new) } }
        .onChange(of: privateOn) { state.applyDetectionSettings() }
        .onChange(of: privateStart) { state.applyDetectionSettings() }
        .onChange(of: privateEnd) { state.applyDetectionSettings() }
    }

    private func load() {
        guard let rs = state.currentRuleSet() else { return }
        let saved = state.database.flatMap { try? SettingsRepository($0).rules() } ?? [:]
        rows = rs.rules.map {
            Row(id: $0.id, name: $0.app.name, defaultDebounce: $0.app.debounceSec, defaultGrace: $0.app.graceSec,
                mode: $0.mode, debounce: $0.debounce, grace: $0.grace, localOnly: saved[$0.id]?.localOnly ?? false)
        }
    }

    private func save(_ rows: [Row]) {
        guard let db = state.database else { return }
        do {
            let repo = SettingsRepository(db)
            for r in rows {
                try repo.saveRule(AppRuleOverride(appID: r.id, mode: r.mode,
                                                  debounceSec: r.debounce == r.defaultDebounce ? nil : r.debounce,
                                                  graceSec: r.grace == r.defaultGrace ? nil : r.grace, localOnly: r.localOnly))
            }
            saveError = nil
            state.applyDetectionSettings()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Minutes-since-midnight ⇄ Date for the time pickers.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}
