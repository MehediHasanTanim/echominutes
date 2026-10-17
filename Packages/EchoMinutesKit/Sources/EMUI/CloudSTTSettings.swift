import EMCore
import EMDetection
import EMStorage
import EMTranscription
import SwiftUI

/// Settings ▸ Transcription ▸ Engine (EM-162…167): local Whisper or a cloud service, per app; API keys; usage.
struct TranscriptionEngineSection: View {
    @Environment(AppState.self) private var state
    @AppStorage(TranscriptionPreferences.engineKey) private var engine = STTEngineChoice.local.rawValue
    @AppStorage(TranscriptionPreferences.openAIModelKey) private var openAIModel = "whisper-1"
    @AppStorage(TranscriptionPreferences.cloudConsentKey) private var consented = false
    @State private var appEngines = TranscriptionPreferences.appEngines
    @State private var pendingConsent: (() -> Void)?
    @State private var showConsent = false
    @State private var showPerApp = false

    var body: some View {
        Section("Engine") {
            Picker("Transcribe with", selection: Binding(get: { engine }, set: { new in
                confirmCloud(STTEngineChoice(rawValue: new) ?? .local) { engine = new }
            })) {
                ForEach(STTEngineChoice.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text(note(STTEngineChoice(rawValue: engine) ?? .local))
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("Different engine per app", isExpanded: $showPerApp) {
                ForEach(apps, id: \.id) { app in
                    Picker(app.name, selection: Binding(get: { appEngines[app.id]?.rawValue ?? "" }, set: { new in
                        let choice = STTEngineChoice(rawValue: new)
                        confirmCloud(choice ?? .local) {
                            appEngines[app.id] = choice
                            TranscriptionPreferences.appEngines = appEngines
                        }
                    })) {
                        Text("Default").tag("")
                        ForEach(STTEngineChoice.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .disabled(localOnly(app.id))
                    .help(localOnly(app.id) ? "“Local only” is on for this app (Settings ▸ Detection) — always transcribed on this Mac" : "")
                }
            }
        }
        Section("Cloud transcription") {
            CloudKeyRow(choice: .deepgram, url: "https://console.deepgram.com")
            CloudKeyRow(choice: .assemblyAI, url: "https://www.assemblyai.com/dashboard")
            HStack {
                Text("OpenAI")
                Spacer()
                if TranscriptionPreferences.apiKey(.openAI) != nil {
                    Label("Uses your OpenAI key from Settings ▸ Providers", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Text("Add an OpenAI key in Settings ▸ Providers").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("OpenAI model", selection: $openAIModel) {
                Text("whisper-1 — timestamps per sentence").tag("whisper-1")
                Text("gpt-4o-transcribe — text per speech block").tag("gpt-4o-transcribe")
                Text("gpt-4o-mini-transcribe — cheaper, text per speech block").tag("gpt-4o-mini-transcribe")
            }
            if !usage.isEmpty {
                LabeledContent("Sent this month", value: usage)
            }
            Text("Only the recorded audio tracks are uploaded, after the call; the live transcript always runs on this Mac. AssemblyAI transcripts are deleted from their servers after download. Bengali: Deepgram Nova-3 and AssemblyAI (Universal-2) support it; check quality on your own calls.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Send meeting audio to a cloud service?", isPresented: $showConsent) {
            Button("Use cloud transcription") { consented = true; pendingConsent?(); pendingConsent = nil }
            Button("Cancel", role: .cancel) { pendingConsent = nil }
        } message: {
            Text("With a cloud engine, the audio of your meetings (your voice and the other people's) is uploaded to that company for transcription, under their terms. Make sure the people on your calls are OK with that. Apps marked “Local only” stay on this Mac.")
        }
    }

    private var apps: [DetectionRules.App] { state.currentRuleSet()?.rules.map(\.app) ?? state.rules?.apps ?? [] }

    private func localOnly(_ appID: String) -> Bool {
        (state.database.flatMap { try? SettingsRepository($0).rules() } ?? [:])[appID]?.localOnly ?? false
    }

    /// Asks once before the first cloud engine is chosen (EM-167).
    private func confirmCloud(_ choice: STTEngineChoice, then apply: @escaping () -> Void) {
        if choice.isCloud && !consented { pendingConsent = apply; showConsent = true } else { apply() }
    }

    private func note(_ c: STTEngineChoice) -> String {
        switch c {
        case .local: "Private and free: everything stays on this Mac."
        case .deepgram: "Fast and accurate, ~1 minute for an hour of audio. Needs a Deepgram API key (paid per minute)."
        case .assemblyAI: "Accurate, a few minutes per hour of audio. Needs an AssemblyAI API key (paid per hour)."
        case .openAI: "Uses your OpenAI key; audio is sent in chunks of up to 10 minutes."
        }
    }

    /// Minutes of audio transcribed by each cloud engine this month (from the sessions' engine).
    private var usage: String {
        let cal = Calendar.current
        var minutes: [STTEngineChoice: Double] = [:]
        for s in state.sessions where cal.isDate(s.startedAt, equalTo: Date(), toGranularity: .month) {
            guard let c = STTEngineChoice.from(identifier: s.sttEngine), c.isCloud, let end = s.endedAt else { continue }
            minutes[c, default: 0] += end.timeIntervalSince(s.startedAt) / 60
        }
        return STTEngineChoice.allCases.compactMap { c in
            minutes[c].map { "\(c.displayName.components(separatedBy: " (").first ?? c.displayName) \(Int($0.rounded())) min" }
        }.joined(separator: " · ")
    }
}

/// API key field for one cloud engine, stored in the Keychain; "Test" checks it without sending audio.
struct CloudKeyRow: View {
    let choice: STTEngineChoice
    let url: String
    @State private var key = ""
    @State private var saved = false
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(choice.displayName.components(separatedBy: " (").first ?? choice.displayName).frame(width: 90, alignment: .leading)
                SecureField(saved ? "Saved — paste a new key to replace" : "API key", text: $key)
                Button("Save") { save() }.disabled(key.isEmpty)
                Button(testing ? "Testing…" : "Test") { Task { await test() } }.disabled(!saved || testing)
                if saved { Button("Remove", role: .destructive) { remove() }.buttonStyle(.link) }
            }
            HStack {
                if let result { Text(result).font(.caption).foregroundStyle(result.hasPrefix("✓") ? .green : .red) }
                Spacer()
                Link("Get a key", destination: URL(string: url)!).font(.caption)
            }
        }
        .onAppear { saved = TranscriptionPreferences.apiKey(choice) != nil }
    }

    private func save() {
        guard let account = choice.keychainAccount else { return }
        do {
            try KeychainStore().set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account, label: choice.displayName)
            key = ""; saved = true; result = "Saved in the Keychain"
        } catch { result = "Couldn't save: \(error.localizedDescription)" }
    }

    private func remove() {
        if let account = choice.keychainAccount { try? KeychainStore().delete(account: account) }
        saved = false; result = nil
    }

    private func test() async {
        guard let k = TranscriptionPreferences.apiKey(choice) else { return }
        testing = true; defer { testing = false }
        do {
            switch choice {
            case .deepgram: try await DeepgramEngine.validate(key: k)
            case .assemblyAI: try await AssemblyAIEngine.validate(key: k)
            default: break
            }
            result = "✓ Key works"
        } catch {
            result = error.localizedDescription
        }
    }
}
