import EMCore
import EMSummarization
import LocalAuthentication
import SwiftUI

/// Settings ▸ Providers (EM-106/107): per provider key (Keychain), endpoint, model picker from the provider's
/// own list, Test connection, and which provider writes summaries.
struct ProvidersSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var selected: ProviderID = .anthropic
    @AppStorage(LLMPreferences.summaryProviderKey) private var summaryProvider = ""
    @State private var refresh = 0

    var body: some View {
        HStack(spacing: 0) {
            List(ProviderID.allCases, selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) { p in
                HStack {
                    Text(p.displayName)
                    Spacer()
                    if summaryProvider == p.rawValue { Image(systemName: "star.fill").foregroundStyle(.yellow).help("Used for summaries") }
                    Circle().fill(state.providerReadiness(p) == nil ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                }
                .tag(p)
                .id("\(p.rawValue)-\(refresh)")
            }
            .frame(width: 210)
            Divider()
            ProviderDetailView(provider: selected, summaryProvider: $summaryProvider) { refresh += 1 }
                .id(selected)
        }
    }
}

struct ProviderDetailView: View {
    @Environment(AppState.self) private var state
    let provider: ProviderID
    @Binding var summaryProvider: String
    let changed: () -> Void

    @State private var keyInput = ""
    @State private var masked: String?
    @State private var revealed: String?
    @State private var model = ""
    @State private var models: [String] = []
    @State private var baseURL = ""
    @State private var deployment = ""
    @State private var apiVersion = ""
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        Form {
            Section {
                Toggle("Use \(provider.displayName) for meeting summaries", isOn: Binding(
                    get: { summaryProvider == provider.rawValue },
                    set: { summaryProvider = $0 ? provider.rawValue : ""; changed() }))
                if let problem = state.summaryProviderProblem, summaryProvider == provider.rawValue {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            }
            if provider.requiresAPIKey || provider == .openAICompatible { keySection }
            endpointSection
            modelSection
            Section {
                HStack {
                    Button(testing ? "Testing…" : "Save & Test connection") { Task { await saveAndTest() } }
                        .disabled(testing).keyboardShortcut(.defaultAction)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red).font(.callout).textSelection(.enabled)
                }
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private var keySection: some View {
        Section("API key") {
            if let masked {
                HStack {
                    Text(revealed ?? masked).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button(revealed == nil ? "Reveal" : "Hide") {
                        if revealed == nil { Task { await reveal() } } else { revealed = nil }
                    }
                    .help("Requires Touch ID or your Mac password")
                    Button("Remove", role: .destructive) {
                        state.removeAPIKey(provider); self.masked = nil; revealed = nil; result = nil; changed()
                    }
                }
            }
            SecureField(masked == nil ? "Paste your API key" : "Paste a new key to replace it", text: $keyInput)
                .textContentType(.password)
            Text("Stored only in your macOS Keychain (visible in Keychain Access as “EchoMinutes – \(provider.displayName) API key”). Never written to disk or logs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var endpointSection: some View {
        switch provider {
        case .azureOpenAI:
            Section("Azure endpoint") {
                TextField("Endpoint", text: $baseURL, prompt: Text("https://<resource>.openai.azure.com"))
                TextField("Deployment name", text: $deployment)
                TextField("API version", text: $apiVersion, prompt: Text(OpenAIProvider.defaultAzureAPIVersion))
            }
        case .openAICompatible:
            Section("Server") { TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:1234/v1")) }
        case .ollama:
            Section("Server") { TextField("Base URL", text: $baseURL, prompt: Text(OllamaProvider.defaultBase)) }
        case .openRouter:
            Section("Server") { TextField("Base URL (optional)", text: $baseURL, prompt: Text("https://openrouter.ai/api/v1")) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var modelSection: some View {
        if provider != .azureOpenAI {
            Section("Model") {
                if !models.isEmpty {
                    Picker("Model", selection: $model) {
                        if !models.contains(model) { Text(model.isEmpty ? "Choose…" : model).tag(model) }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Model name", text: $model, prompt: Text("Run Test connection to load the list, or type a name"))
            }
        }
    }

    private var footer: String {
        switch provider {
        case .anthropic: "Create a key at console.anthropic.com ▸ API Keys."
        case .openAI: "Create a key at platform.openai.com ▸ API keys."
        case .gemini: "Create a key at aistudio.google.com ▸ Get API key."
        case .openRouter: "Create a key at openrouter.ai ▸ Keys. One key reaches many model vendors."
        case .azureOpenAI: "Use the key and endpoint from your Azure OpenAI resource ▸ Keys and Endpoint."
        case .openAICompatible: "Any server with an OpenAI-style /chat/completions (LM Studio, vLLM, Groq…). Key optional."
        case .ollama: "Runs models on this Mac — nothing leaves your computer. Install from ollama.com, then `ollama pull <model>`."
        }
    }

    private func load() {
        let c = state.providerConfig(provider)
        masked = state.maskedAPIKey(provider)
        model = c.model ?? ""
        baseURL = c.baseURL ?? ""
        let az = state.azureFields(c)
        deployment = az.deployment; apiVersion = az.apiVersion
    }

    private func saveAndTest() async {
        result = nil
        if !keyInput.isEmpty {
            do { try state.setAPIKey(keyInput, for: provider); keyInput = ""; masked = state.maskedAPIKey(provider) }
            catch { result = (false, "Couldn't save the key to the Keychain: \(error.localizedDescription)"); return }
        }
        state.saveProviderConfig(provider, model: model, baseURL: baseURL, azureDeployment: deployment, azureAPIVersion: apiVersion)
        testing = true
        let r = await state.testProvider(provider)
        testing = false
        switch r {
        case .success(let check):
            models = check.models
            if model.isEmpty || (!check.models.isEmpty && !check.models.contains(model) && provider != .openAICompatible),
               let pick = ModelSuggestion.pick(check.models, for: provider) {
                model = pick
                state.saveProviderConfig(provider, model: model, baseURL: baseURL, azureDeployment: deployment, azureAPIVersion: apiVersion)
            }
            result = (true, check.message + (model.isEmpty ? "" : " · using \(model)"))
            if summaryProvider.isEmpty { summaryProvider = provider.rawValue }    // first working provider becomes the default
        case .failure(let e):
            result = (false, e.localizedDescription)
        }
        changed()
    }

    private func reveal() async {
        let ctx = LAContext()
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your \(provider.displayName) API key")
            if ok { revealed = state.revealAPIKey(provider) }
        } catch {
            result = (false, "Authentication cancelled")
        }
    }
}
