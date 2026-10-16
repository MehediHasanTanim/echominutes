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

/// Thread-safe reads of provider settings (DB + Keychain) — used by AppState and by background jobs.
public struct ProviderStore: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func config(_ p: ProviderID) -> ProviderConfig {
        (try? SettingsRepository(db).providers().first { $0.provider == p }) ?? ProviderConfig(provider: p, enabled: false)
    }

    public static func azureFields(_ c: ProviderConfig) -> (deployment: String, apiVersion: String) {
        let v = c.extraJSON.flatMap { try? JSONValue.parse($0) }
        return (v?["deployment"]?.string ?? "", v?["apiVersion"]?.string ?? "")
    }

    public func settings(_ p: ProviderID) -> ProviderSettings {
        let c = config(p)
        let az = Self.azureFields(c)
        return ProviderSettings(provider: p, apiKey: (try? KeychainStore().get(p)) ?? nil, model: c.model, baseURL: c.baseURL,
                                azureDeployment: az.deployment, azureAPIVersion: az.apiVersion)
    }

    /// nil when usable; otherwise what's missing.
    public func readiness(_ p: ProviderID) -> String? {
        let s = settings(p)
        if p.requiresAPIKey, (s.apiKey ?? "").isEmpty { return "API key missing" }
        if p == .azureOpenAI, (s.baseURL ?? "").isEmpty || (s.azureDeployment ?? "").isEmpty { return "Endpoint or deployment missing" }
        if p == .openAICompatible, (s.baseURL ?? "").isEmpty { return "Base URL missing" }
        if p != .azureOpenAI, (s.model ?? "").isEmpty { return "No model selected" }
        return nil
    }
}

extension AppState {
    var keychain: KeychainStore { KeychainStore() }

    public func providerConfig(_ p: ProviderID) -> ProviderConfig {
        database.map { ProviderStore(db: $0).config(p) } ?? ProviderConfig(provider: p, enabled: false)
    }

    /// Azure fields live in `extra_json`.
    public func azureFields(_ c: ProviderConfig) -> (deployment: String, apiVersion: String) { ProviderStore.azureFields(c) }

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
        database.map { ProviderStore(db: $0).settings(p) } ?? ProviderSettings(provider: p)
    }

    /// Is the provider usable (key / endpoint / model present)?
    public func providerReadiness(_ p: ProviderID) -> String? {
        database.map { ProviderStore(db: $0).readiness(p) } ?? "Library unavailable"
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
