import EMCore
import Foundation

// MARK: - Requests & responses (Technical Design §10.1, EM-100)

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

public struct LLMRequest: Sendable, Equatable {
    public var model: String
    public var system: String?
    public var messages: [LLMMessage]
    /// JSON Schema for structured output (each adapter maps it to its provider's mechanism).
    public var jsonSchema: JSONValue?
    public var schemaName: String
    public var maxOutputTokens: Int
    public var temperature: Double

    public init(model: String, system: String? = nil, messages: [LLMMessage], jsonSchema: JSONValue? = nil,
                schemaName: String = "result", maxOutputTokens: Int = 4096, temperature: Double = 0.2) {
        self.model = model; self.system = system; self.messages = messages; self.jsonSchema = jsonSchema
        self.schemaName = schemaName; self.maxOutputTokens = maxOutputTokens; self.temperature = temperature
    }
}

public struct LLMResponse: Sendable, Equatable {
    public var text: String
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(text: String, model: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

/// Error taxonomy shown to the user (EM-100). Messages never contain the API key.
public enum LLMError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured(String)
    case invalidKey(String?)
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded(String?)
    case modelNotFound(String)
    case network(String)
    case server(status: Int, message: String?)
    case badRequest(String?)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let m): m
        case .invalidKey(let m): "The API key was rejected." + (m.map { " (\($0))" } ?? "") + " Check it in Settings ▸ Providers."
        case .rateLimited(let s): "Rate limited by the provider." + (s.map { " Try again in \(Int($0)) s." } ?? " Try again shortly.")
        case .quotaExceeded(let m): "Quota or credit exhausted." + (m.map { " (\($0))" } ?? "") + " Check billing with the provider."
        case .modelNotFound(let m): "Model “\(m)” isn't available for this key. Pick another model."
        case .network(let m): "Couldn't reach the provider: \(m)"
        case .server(let code, let m): "The provider had a problem (HTTP \(code))." + (m.map { " \($0)" } ?? "")
        case .badRequest(let m): "The provider rejected the request." + (m.map { " \($0)" } ?? "")
        case .badResponse(let m): "Unexpected answer from the provider: \(m)"
        }
    }

    /// Worth retrying automatically (job queue backoff).
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .network, .server: true
        default: false
        }
    }
}

// MARK: - Provider

/// Everything an adapter needs; the key comes from the Keychain, the rest from `provider_configs`.
public struct ProviderSettings: Sendable, Equatable {
    public var provider: ProviderID
    public var apiKey: String?
    public var model: String?
    /// Override for OpenAI-compatible / OpenRouter / Ollama; Azure resource endpoint (https://x.openai.azure.com).
    public var baseURL: String?
    public var azureDeployment: String?
    public var azureAPIVersion: String?

    public init(provider: ProviderID, apiKey: String? = nil, model: String? = nil, baseURL: String? = nil,
                azureDeployment: String? = nil, azureAPIVersion: String? = nil) {
        self.provider = provider; self.apiKey = apiKey; self.model = model; self.baseURL = baseURL
        self.azureDeployment = azureDeployment; self.azureAPIVersion = azureAPIVersion
    }
}

public struct ConnectionCheck: Sendable, Equatable {
    public var models: [String]
    public var message: String
}

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func listModels() async throws -> [String]
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    /// Validates key + endpoint; returns available models where the provider can list them.
    func testConnection() async throws -> ConnectionCheck
}

extension LLMProvider {
    public func testConnection() async throws -> ConnectionCheck {
        let models = try await listModels()
        return ConnectionCheck(models: models, message: "Connected — \(models.count) model\(models.count == 1 ? "" : "s") available")
    }
}

/// Picks a sensible default from a fetched model list (names change too often to hard-code one).
public enum ModelSuggestion {
    static let preferences: [ProviderID: [String]] = [
        .anthropic: ["sonnet", "opus", "haiku"],
        .openAI: ["gpt-5-mini", "gpt-5", "gpt-4.1", "gpt-4o"],
        .gemini: ["2.5-flash", "flash", "pro"],
        .openRouter: ["claude", "gpt", "gemini"],
    ]

    public static func pick(_ models: [String], for provider: ProviderID) -> String? {
        let sorted = models.sorted(by: >)                      // newer versions usually sort later → reverse
        for p in preferences[provider] ?? [] {
            if let m = sorted.first(where: { $0.localizedCaseInsensitiveContains(p) && !$0.contains("embed") }) { return m }
        }
        return models.first
    }
}
