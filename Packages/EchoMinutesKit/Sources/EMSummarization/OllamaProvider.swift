import EMCore
import Foundation

/// Ollama on this Mac (EM-105): `/api/chat` with `format: <schema>`. No key; plain http allowed for localhost only.
public struct OllamaProvider: LLMProvider {
    public static let defaultBase = "http://localhost:11434"
    public var id: ProviderID { .ollama }
    let base: String
    let http: HTTPClient

    public init(settings: ProviderSettings, http: HTTPClient = HTTPClient()) throws {
        base = settings.baseURL.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBase
        self.http = http
        if let u = URL(string: base), u.scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(u.host ?? "") {
            throw LLMError.notConfigured("Plain http is only allowed for localhost; use https for a remote Ollama server.")
        }
    }

    public func listModels() async throws -> [String] {
        let v = try await http.json(http.request(try .join(base, "/api/tags")))
        return (v["models"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
    }

    public func testConnection() async throws -> ConnectionCheck {
        let models = try await listModels()
        if models.isEmpty { return ConnectionCheck(models: [], message: "Ollama is running but has no models — run `ollama pull llama3.1` first") }
        return ConnectionCheck(models: models, message: "Connected — \(models.count) local model\(models.count == 1 ? "" : "s")")
    }

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        var messages: [JSONValue] = []
        if let s = req.system { messages.append(["role": "system", "content": .string(s)]) }
        messages += req.messages.map { ["role": .string($0.role.rawValue), "content": .string($0.content)] }
        var body: [String: JSONValue] = [
            "model": .string(req.model), "messages": .array(messages), "stream": false,
            "options": ["temperature": .number(req.temperature), "num_predict": .number(Double(req.maxOutputTokens))],
        ]
        if let schema = req.jsonSchema { body["format"] = schema }
        var r = try http.request(try .join(base, "/api/chat"), method: "POST", body: .object(body))
        r.timeoutInterval = 600                                   // local models can be slow on long transcripts
        let v = try await http.json(r)
        guard let text = v["message"]?["content"]?.string, !text.isEmpty else { throw LLMError.badResponse("empty answer") }
        return LLMResponse(text: text, model: v["model"]?.string,
                           inputTokens: v["prompt_eval_count"]?.int, outputTokens: v["eval_count"]?.int)
    }
}

/// Builds the adapter for a provider (EM-100).
public enum ProviderFactory {
    public static func make(_ s: ProviderSettings, http: HTTPClient = HTTPClient()) throws -> LLMProvider {
        switch s.provider {
        case .anthropic: return try AnthropicProvider(settings: s, http: http)
        case .gemini: return try GeminiProvider(settings: s, http: http)
        case .ollama: return try OllamaProvider(settings: s, http: http)
        case .openAI, .azureOpenAI, .openRouter, .openAICompatible: return try OpenAIProvider(settings: s, http: http)
        }
    }
}
