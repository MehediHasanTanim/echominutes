import EMCore
import Foundation

/// Google Gemini `generateContent` (EM-104) with `responseSchema` (OpenAPI subset — see `geminiSchema`).
public struct GeminiProvider: LLMProvider {
    public static let defaultBase = "https://generativelanguage.googleapis.com/v1beta"
    public var id: ProviderID { .gemini }
    let key: String
    let base: String
    let http: HTTPClient

    public init(settings: ProviderSettings, http: HTTPClient = HTTPClient()) throws {
        guard let k = settings.apiKey, !k.isEmpty else { throw LLMError.notConfigured("Add your Gemini API key in Settings ▸ Providers.") }
        key = k; base = settings.baseURL.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBase; self.http = http
    }

    var headers: [String: String] { ["x-goog-api-key": key] }

    public func listModels() async throws -> [String] {
        let v = try await http.json(http.request(try .join(base, "/models?pageSize=200"), headers: headers))
        return (v["models"]?.array ?? []).compactMap { m -> String? in
            guard let name = m["name"]?.string,
                  (m["supportedGenerationMethods"]?.array ?? []).contains(where: { $0.string == "generateContent" }) else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
    }

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        var gen: [String: JSONValue] = ["temperature": .number(req.temperature), "maxOutputTokens": .number(Double(req.maxOutputTokens))]
        if let schema = req.jsonSchema {
            gen["responseMimeType"] = "application/json"
            gen["responseSchema"] = Self.geminiSchema(schema)
        }
        var body: [String: JSONValue] = [
            "contents": .array(req.messages.map {
                ["role": .string($0.role == .assistant ? "model" : "user"), "parts": [["text": .string($0.content)]]]
            }),
            "generationConfig": .object(gen),
        ]
        if let s = req.system { body["systemInstruction"] = ["parts": [["text": .string(s)]]] }
        let model = req.model.hasPrefix("models/") ? String(req.model.dropFirst(7)) : req.model
        let v = try await http.json(http.request(try .join(base, "/models/\(model):generateContent"), method: "POST", headers: headers, body: .object(body)))
        if let block = v["promptFeedback"]?["blockReason"]?.string { throw LLMError.badResponse("blocked by safety filter (\(block))") }
        let parts = v["candidates"]?[0]?["content"]?["parts"]?.array ?? []
        let text = parts.compactMap { $0["text"]?.string }.joined()
        guard !text.isEmpty else { throw LLMError.badResponse("empty answer (finishReason: \(v["candidates"]?[0]?["finishReason"]?.string ?? "?"))") }
        return LLMResponse(text: text, model: v["modelVersion"]?.string ?? model,
                           inputTokens: v["usageMetadata"]?["promptTokenCount"]?.int,
                           outputTokens: v["usageMetadata"]?["candidatesTokenCount"]?.int)
    }

    /// JSON Schema → Gemini schema: `"type": ["string","null"]` → `"type": "string", "nullable": true`;
    /// keywords Gemini rejects (`additionalProperties`, `$schema`, `title`…) are dropped.
    static func geminiSchema(_ s: JSONValue) -> JSONValue {
        switch s {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                switch k {
                case "type":
                    if case .array(let types) = v {
                        let names = types.compactMap(\.string)
                        out["type"] = .string(names.first { $0 != "null" } ?? "string")
                        if names.contains("null") { out["nullable"] = true }
                    } else { out["type"] = v }
                case "properties":
                    out["properties"] = .object((v.object ?? [:]).mapValues(geminiSchema))
                case "items":
                    out["items"] = geminiSchema(v)
                case "required", "enum", "description", "format", "nullable", "minItems", "maxItems":
                    out[k] = v
                default:
                    continue        // additionalProperties, $schema, title, default, …
                }
            }
            return .object(out)
        default:
            return s
        }
    }
}
