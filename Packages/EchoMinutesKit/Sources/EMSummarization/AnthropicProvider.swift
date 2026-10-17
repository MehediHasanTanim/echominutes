import EMCore
import Foundation

/// Anthropic Messages API (EM-102). Structured output: the schema is offered as a single forced tool and the
/// tool input is returned as the JSON text.
public struct AnthropicProvider: LLMProvider {
    public static let defaultBase = "https://api.anthropic.com"
    public static let apiVersion = "2023-06-01"
    public var id: ProviderID { .anthropic }
    let key: String
    let base: String
    let http: HTTPClient

    public init(settings: ProviderSettings, http: HTTPClient = HTTPClient()) throws {
        guard let k = settings.apiKey, !k.isEmpty else { throw LLMError.notConfigured("Add your Anthropic API key in Settings ▸ Providers.") }
        key = k; base = settings.baseURL.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBase; self.http = http
    }

    var headers: [String: String] { ["x-api-key": key, "anthropic-version": Self.apiVersion] }

    public func listModels() async throws -> [String] {
        let v = try await http.json(http.request(try .join(base, "/v1/models?limit=100"), headers: headers))
        return (v["data"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    /// Models that rejected a forced `tool_choice` (some newer / thinking models only allow "auto").
    private static let autoToolOnly = ModelSet()

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        guard req.jsonSchema != nil, !Self.autoToolOnly.contains(req.model) else {
            return try await send(req, forceTool: false)
        }
        do {
            return try await send(req, forceTool: true)
        } catch LLMError.badRequest(let m?) where m.contains("tool_choice") {
            Log.info(.llm, "\(req.model) doesn't support a forced tool; retrying with tool_choice auto")
            Self.autoToolOnly.insert(req.model)
            return try await send(req, forceTool: false)
        }
    }

    private func send(_ req: LLMRequest, forceTool: Bool) async throws -> LLMResponse {
        var body: [String: JSONValue] = [
            "model": .string(req.model),
            "max_tokens": .number(Double(req.maxOutputTokens)),
            "temperature": .number(req.temperature),
            "messages": .array(req.messages.map { ["role": .string($0.role.rawValue), "content": .string($0.content)] }),
        ]
        var system = req.system
        if req.jsonSchema != nil, !forceTool {
            system = (system.map { $0 + "\n\n" } ?? "") + "Answer by calling the \(req.schemaName) tool exactly once with the complete result."
        }
        if let s = system { body["system"] = .string(s) }
        if let schema = req.jsonSchema {
            let tool: JSONValue = .object(["name": .string(req.schemaName),
                                           "description": .string("Return the result in this exact structure."),
                                           "input_schema": schema])
            body["tools"] = .array([tool])
            body["tool_choice"] = forceTool ? .object(["type": .string("tool"), "name": .string(req.schemaName)]) : .object(["type": .string("auto")])
        }
        let v = try await http.json(http.request(try .join(base, "/v1/messages"), method: "POST", headers: headers, body: .object(body)))
        let blocks = v["content"]?.array ?? []
        let text: String
        if req.jsonSchema != nil, let input = blocks.first(where: { $0["type"]?.string == "tool_use" })?["input"] {
            text = input.compactString()
        } else {
            text = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
        }
        guard !text.isEmpty else { throw LLMError.badResponse("empty answer (stop_reason: \(v["stop_reason"]?.string ?? "?"))") }
        return LLMResponse(text: text, model: v["model"]?.string,
                           inputTokens: v["usage"]?["input_tokens"]?.int, outputTokens: v["usage"]?["output_tokens"]?.int)
    }
}

/// Small thread-safe set of model ids.
final class ModelSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
}
