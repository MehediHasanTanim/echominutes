import EMCore
import Foundation

/// OpenAI Chat Completions and the services that speak it (EM-103, EM-105): OpenAI, Azure OpenAI, OpenRouter,
/// and any OpenAI-compatible server (LM Studio, vLLM, Groq, Together…).
public struct OpenAIProvider: LLMProvider {
    public enum Flavor: Sendable { case openAI, azure, openRouter, compatible }
    public let id: ProviderID
    let flavor: Flavor
    let key: String?
    let base: String
    let deployment: String?
    let apiVersion: String
    let http: HTTPClient

    public static let defaultAzureAPIVersion = "2024-10-21"

    public init(settings: ProviderSettings, http: HTTPClient = HTTPClient()) throws {
        id = settings.provider
        self.http = http
        let customBase = settings.baseURL.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        key = settings.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        deployment = settings.azureDeployment.flatMap { $0.isEmpty ? nil : $0 }
        apiVersion = settings.azureAPIVersion.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultAzureAPIVersion
        switch settings.provider {
        case .openAI:
            flavor = .openAI; base = customBase ?? "https://api.openai.com/v1"
        case .openRouter:
            flavor = .openRouter; base = customBase ?? "https://openrouter.ai/api/v1"
        case .azureOpenAI:
            flavor = .azure
            guard let b = customBase else { throw LLMError.notConfigured("Enter your Azure OpenAI endpoint (https://<resource>.openai.azure.com).") }
            guard deployment != nil else { throw LLMError.notConfigured("Enter your Azure OpenAI deployment name.") }
            base = b
        case .openAICompatible:
            flavor = .compatible
            guard let b = customBase else { throw LLMError.notConfigured("Enter the server's base URL (e.g. http://localhost:1234/v1).") }
            base = b
        default:
            throw LLMError.notConfigured("\(settings.provider.displayName) isn't an OpenAI-style provider")
        }
        if flavor != .compatible, key == nil {
            throw LLMError.notConfigured("Add your \(settings.provider.displayName) API key in Settings ▸ Providers.")
        }
    }

    var headers: [String: String] {
        var h: [String: String] = [:]
        if flavor == .azure { h["api-key"] = key }
        else if let key { h["Authorization"] = "Bearer \(key)" }
        if flavor == .openRouter {
            h["HTTP-Referer"] = "https://github.com/tanimkabir/echominutes"
            h["X-Title"] = "EchoMinutes"
        }
        return h
    }

    func chatURL() throws -> URL {
        if flavor == .azure, let deployment {
            return try .join(base, "/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)")
        }
        return try .join(base, "/chat/completions")
    }

    public func listModels() async throws -> [String] {
        if flavor == .azure { return deployment.map { [$0] } ?? [] }      // deployments aren't listable with an api-key
        let v = try await http.json(http.request(try .join(base, "/models"), headers: headers))
        let ids = (v["data"]?.array ?? []).compactMap { $0["id"]?.string }
        guard flavor == .openAI else { return ids.sorted() }
        // Only chat-capable families (the list also has embeddings, audio, image, moderation models).
        return ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("chatgpt"))
                && !["audio", "realtime", "transcribe", "tts", "image", "search", "embedding"].contains { id.contains($0) }
        }.sorted()
    }

    public func testConnection() async throws -> ConnectionCheck {
        guard flavor == .azure else {
            let models = try await listModels()
            return ConnectionCheck(models: models, message: "Connected — \(models.count) model\(models.count == 1 ? "" : "s") available")
        }
        _ = try await complete(LLMRequest(model: deployment ?? "", messages: [LLMMessage(.user, "Reply with OK.")], maxOutputTokens: 16))
        return ConnectionCheck(models: deployment.map { [$0] } ?? [], message: "Connected to deployment “\(deployment ?? "")”")
    }

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        var temperature = !ModelQuirks.noTemperature.contains(req.model)
        while true {
            do {
                return try await send(req, temperature: temperature)
            } catch LLMError.badRequest(let m?) where temperature && m.lowercased().contains("temperature") {
                temperature = false
                ModelQuirks.noTemperature.insert(req.model)
                Log.info(.llm, "\(req.model) rejected temperature; retrying without it")
            }
        }
    }

    private func send(_ req: LLMRequest, temperature: Bool) async throws -> LLMResponse {
        var messages: [JSONValue] = []
        if let s = req.system { messages.append(["role": "system", "content": .string(s)]) }
        messages += req.messages.map { ["role": .string($0.role.rawValue), "content": .string($0.content)] }
        var body: [String: JSONValue] = ["messages": .array(messages)]
        if flavor != .azure { body["model"] = .string(req.model) }
        switch flavor {
        case .openAI, .azure:
            // Current OpenAI models (incl. reasoning models) take max_completion_tokens and only the default temperature.
            body["max_completion_tokens"] = .number(Double(req.maxOutputTokens))
        case .openRouter, .compatible:
            body["max_tokens"] = .number(Double(req.maxOutputTokens))
            if temperature { body["temperature"] = .number(req.temperature) }
        }
        if let schema = req.jsonSchema, flavor != .compatible {
            let spec: JSONValue = .object(["name": .string(req.schemaName), "schema": schema, "strict": .bool(false)])
            body["response_format"] = .object(["type": .string("json_schema"), "json_schema": spec])
        }
        let v = try await http.json(http.request(try chatURL(), method: "POST", headers: headers, body: .object(body)))
        guard let choice = v["choices"]?[0] else { throw LLMError.badResponse("no choices") }
        if let refusal = choice["message"]?["refusal"]?.string, !refusal.isEmpty { throw LLMError.badResponse("model refused: \(refusal)") }
        guard let text = choice["message"]?["content"]?.string, !text.isEmpty else {
            throw LLMError.badResponse("empty answer (finish_reason: \(choice["finish_reason"]?.string ?? "?"))")
        }
        return LLMResponse(text: text, model: v["model"]?.string,
                           inputTokens: v["usage"]?["prompt_tokens"]?.int, outputTokens: v["usage"]?["completion_tokens"]?.int)
    }
}
