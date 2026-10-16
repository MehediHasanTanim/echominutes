import AppKit
import EMCore
import EMSummarization
import SwiftUI

/// Settings ▸ AI Summary (EM-112/116): auto-summarise, language, default template, spend this month.
struct SummarySettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(SummaryPreferences.autoKey) private var auto = true
    @AppStorage(SummaryPreferences.languageKey) private var language = ""
    @AppStorage(SummaryPreferences.templateKey) private var template = ""

    var body: some View {
        Form {
            Section {
                Toggle("Summarise meetings automatically after transcription", isOn: $auto)
                if let problem = state.summaryProviderProblem {
                    Label(problem + " Set one up in the Providers tab.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if let p = LLMPreferences.summaryProvider {
                    LabeledContent("Provider", value: "\(p.displayName) · \(state.providerConfig(p).model ?? "")")
                }
                Text("Only the transcript text is sent to the provider — never the audio. Apps marked “Local only” in the Detection tab are summarised with Ollama on this Mac, or not at all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Style") {
                Picker("Summary language", selection: $language) {
                    ForEach(SummaryPreferences.languages, id: \.self) { Text($0.isEmpty ? "Same as the meeting" : $0).tag($0) }
                }
                Picker("Template", selection: $template) {
                    Text("Automatic (from title and opening)").tag("")
                    ForEach(SummaryTemplate.all) { Text($0.name).tag($0.id) }
                }
            }
            Section("Cost") {
                LabeledContent("Estimated spend this month", value: String(format: "$%.2f", state.costThisMonth))
                HStack {
                    Text("Based on approximate list prices; edit them if your rates differ.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let paths = state.paths {
                        Button("Edit prices…") {
                            let url = SummaryPreferences.pricingURL(paths)
                            _ = Pricing.load(from: url)                  // make sure the editable copy exists
                            NSWorkspace.shared.open(url)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
