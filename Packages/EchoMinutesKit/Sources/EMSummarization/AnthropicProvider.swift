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

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        var body: [String: JSONValue] = [
            "model": .string(req.model),
            "max_tokens": .number(Double(req.maxOutputTokens)),
            "temperature": .number(req.temperature),
            "messages": .array(req.messages.map { ["role": .string($0.role.rawValue), "content": .string($0.content)] }),
        ]
        if let s = req.system { body["system"] = .string(s) }
        if let schema = req.jsonSchema {
            let tool: JSONValue = .object(["name": .string(req.schemaName),
                                           "description": .string("Return the result in this exact structure."),
                                           "input_schema": schema])
            body["tools"] = .array([tool])
            body["tool_choice"] = .object(["type": .string("tool"), "name": .string(req.schemaName)])
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
