import EMCore
import EMStorage
import EMSummarization
import Foundation

/// Provider settings glue (EM-106/107): non-secret config in `provider_configs`, keys only in the Keychain.
public enum LLMPreferences {
    public static let summaryProviderKey = "llm.summaryProvider"
    public static var summaryProvider: ProviderID? {
        UserDefaults.standard.string(forKey: summaryProviderKey).flatMap(ProviderID.init(rawValue:))
    }
}

extension AppState {
    var keychain: KeychainStore { KeychainStore() }

    public func providerConfig(_ p: ProviderID) -> ProviderConfig {
        guard let database, let c = try? SettingsRepository(database).providers().first(where: { $0.provider == p })
        else { return ProviderConfig(provider: p, enabled: false) }
        return c
    }

    /// Azure fields live in `extra_json`.
    public func azureFields(_ c: ProviderConfig) -> (deployment: String, apiVersion: String) {
        let v = c.extraJSON.flatMap { try? JSONValue.parse($0) }
        return (v?["deployment"]?.string ?? "", v?["apiVersion"]?.string ?? "")
    }

    public func saveProviderConfig(_ p: ProviderID, model: String?, baseURL: String?, azureDeployment: String? = nil, azureAPIVersion: String? = nil) {
        guard let database else { return }
        var extra: String?
        if p == .azureOpenAI {
            extra = JSONValue.object(["deployment": .string(azureDeployment ?? ""), "apiVersion": .string(azureAPIVersion ?? "")]).compactString()
        }
        let clean = { (s: String?) -> String? in s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) } }
        do {
            try SettingsRepository(database).saveProvider(ProviderConfig(provider: p, enabled: true, model: clean(model), baseURL: clean(baseURL), extraJSON: extra))
        } catch { lastError = "Saving provider settings failed: \(error.localizedDescription)" }
    }

    public func hasAPIKey(_ p: ProviderID) -> Bool { keychain.hasKey(p) }

    public func maskedAPIKey(_ p: ProviderID) -> String? { ((try? keychain.get(p)) ?? nil).map(Redactor.mask) }

    /// Plain key — only after Touch ID / password (see ProvidersSettingsView).
    public func revealAPIKey(_ p: ProviderID) -> String? { (try? keychain.get(p)) ?? nil }

    public func setAPIKey(_ key: String, for p: ProviderID) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        try keychain.set(k, for: p)
        Log.info(.llm, "API key saved for \(p.rawValue) (\(Redactor.mask(k)))")
    }

    public func removeAPIKey(_ p: ProviderID) {
        try? keychain.delete(p)
        Log.info(.llm, "API key removed for \(p.rawValue)")
    }

    public func providerSettings(_ p: ProviderID) -> ProviderSettings {
        let c = providerConfig(p)
        let az = azureFields(c)
        return ProviderSettings(provider: p, apiKey: (try? keychain.get(p)) ?? nil, model: c.model, baseURL: c.baseURL,
                                azureDeployment: az.deployment, azureAPIVersion: az.apiVersion)
    }

    /// Is the provider usable (key / endpoint / model present)?
    public func providerReadiness(_ p: ProviderID) -> String? {
        let s = providerSettings(p)
        if p.requiresAPIKey, (s.apiKey ?? "").isEmpty { return "API key missing" }
        if p == .azureOpenAI, (s.baseURL ?? "").isEmpty || (s.azureDeployment ?? "").isEmpty { return "Endpoint or deployment missing" }
        if p == .openAICompatible, (s.baseURL ?? "").isEmpty { return "Base URL missing" }
        if p != .azureOpenAI, (s.model ?? "").isEmpty { return "No model selected" }
        return nil
    }

    /// EM-107 banner text; nil when summaries can run.
    public var summaryProviderProblem: String? {
        guard let p = LLMPreferences.summaryProvider else { return "No AI provider chosen for summaries yet." }
        return providerReadiness(p).map { "\(p.displayName): \($0)." }
    }

    public func testProvider(_ p: ProviderID) async -> Result<ConnectionCheck, LLMError> {
        do {
            let provider = try ProviderFactory.make(providerSettings(p))
            let r = try await provider.testConnection()
            Log.info(.llm, "Test \(p.rawValue): \(r.message)")
            return .success(r)
        } catch let e as LLMError {
            Log.error(.llm, "Test \(p.rawValue) failed: \(e.localizedDescription)")
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
