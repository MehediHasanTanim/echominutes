import EMCore
import EMTranscription
import Observation
import SwiftUI

/// Settings ▸ Transcription (EM-087): auto-transcribe, model (download / delete with progress), language, vocabulary.
struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(TranscriptionPreferences.autoKey) private var auto = true
    @AppStorage(TranscriptionPreferences.speakersKey) private var speakers = true
    @AppStorage(TranscriptionPreferences.modelKey) private var model = STTModelCatalog.defaultVariant
    @AppStorage(TranscriptionPreferences.languageKey) private var language = "en"
    @AppStorage(TranscriptionPreferences.vocabularyKey) private var vocabulary = ""
    @AppStorage(LivePreferences.enabledKey) private var liveOn = false
    @AppStorage(LivePreferences.modelKey) private var liveModel = LivePreferences.defaultModel
    @State private var installed: [String: Int64] = [:]
    @State private var downloads = ModelDownloads()
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Transcribe recordings automatically when they are saved", isOn: $auto)
                Toggle("Tell speakers on the call apart (Speaker 1, Speaker 2…)", isOn: $speakers)
                Text("Runs on this Mac with Whisper — audio never leaves your computer. On battery below 20 % or in Low Power Mode it waits until you're plugged in (or use “Transcribe now”).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Spoken language", selection: $language) {
                    ForEach(TranscriptionPreferences.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Text("Set this to the language of your calls. Automatic detection is unreliable on call audio, and a wrong language gives empty transcripts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                ForEach(STTModelCatalog.all) { m in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: model == m.variant ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model == m.variant ? Color.accentColor : .secondary)
                            .onTapGesture { model = m.variant }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                            Text(m.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let f = downloads.progress[m.variant] {
                            ProgressView(value: f).frame(width: 90)
                            Text("\(Int(f * 100)) %").font(.caption.monospacedDigit()).frame(width: 36)
                        } else if let bytes = installed[m.variant] {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            Button("Delete", role: .destructive) { delete(m.variant) }.controlSize(.small)
                        } else {
                            Text("~\(m.sizeMB >= 1000 ? String(format: "%.1f GB", Double(m.sizeMB) / 1000) : "\(m.sizeMB) MB")")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Download") { download(m.variant) }.controlSize(.small)
                        }
                    }
                }
                Text("The selected model is downloaded automatically before the first transcription if it isn't installed.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Live transcript") {
                Toggle("Show a live transcript in the mini widget while recording", isOn: $liveOn)
                Picker("Live model", selection: $liveModel) {
                    ForEach(LivePreferences.models, id: \.variant) { Text($0.title).tag($0.variant) }
                }
                .disabled(!liveOn)
                Text(liveOn
                     ? "Text appears a few seconds after someone speaks. It is a rough draft from a small model: after the call the full-quality transcript replaces it. Uses extra CPU while recording; pauses on low battery, Low Power Mode or when the Mac is hot. The model downloads the first time it's needed. Applies from the next recording."
                     : "Off: nothing extra runs during calls. The transcript is made after the call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Custom vocabulary") {
                TextField("Names, product terms, acronyms — comma separated", text: $vocabulary, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        guard let mm = state.modelManager else { return }
        installed = Dictionary(uniqueKeysWithValues: mm.installed().map { ($0.variant, $0.bytes) })
    }

    private func download(_ variant: String) {
        guard let mm = state.modelManager else { return }
        let sink = downloads
        sink.progress[variant] = 0; error = nil
        Task {
            do {
                try await mm.download(variant) { f in Task { @MainActor in sink.progress[variant] = f } }
            } catch {
                self.error = "Download failed: \(error.localizedDescription)"
            }
            sink.progress[variant] = nil
            refresh()
        }
    }

    private func delete(_ variant: String) {
        guard let mm = state.modelManager else { return }
        do { try mm.delete(variant) } catch { self.error = "Delete failed: \(error.localizedDescription)" }
        refresh()
    }
}

/// Download progress per model variant (a main-actor class so the @Sendable progress callback can update it).
@MainActor
@Observable
final class ModelDownloads {
    var progress: [String: Double] = [:]
}
