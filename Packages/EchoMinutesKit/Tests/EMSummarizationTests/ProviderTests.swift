import EMCore
import Foundation
import Testing
@testable import EMSummarization

/// URLProtocol stub: tests set `handler` and inspect `requests`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { let url: URL; let method: String; let headers: [String: String]; let body: JSONValue? }
    typealias Handler = @Sendable (Captured) -> (status: Int, headers: [String: String], body: String)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _requests: [Captured] = []
    static var handler: Handler? { get { lock.withLock { _handler } } set { lock.withLock { _handler = newValue } } }
    static var requests: [Captured] { lock.withLock { _requests } }
    static func reset(_ h: @escaping Handler) { lock.withLock { _handler = h; _requests = [] } }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let s = request.httpBodyStream {        // URLSession moves the body into a stream
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        let cap = Captured(url: request.url!, method: request.httpMethod ?? "GET",
                           headers: request.allHTTPHeaderFields ?? [:], body: data.isEmpty ? nil : try? JSONValue.parse(data))
        Self.lock.withLock { Self._requests.append(cap) }
        guard let h = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let r = h(cap)
        if r.status == -1 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let http = HTTPClient(session: StubURLProtocol.session())
let schema: JSONValue = ["type": "object", "required": ["title"], "additionalProperties": false,
                         "properties": ["title": ["type": "string"], "owner": ["type": ["string", "null"]]]]

@Suite("LLM providers", .serialized)
struct ProviderTests {
    @Test func anthropicStructuredOutputViaForcedTool() async throws {
        StubURLProtocol.reset { _ in (200, [:], """
            {"model":"claude-x","content":[{"type":"tool_use","name":"summary","input":{"title":"Weekly sync"}}],
             "usage":{"input_tokens":1200,"output_tokens":80},"stop_reason":"tool_use"}
            """) }
        let p = try AnthropicProvider(settings: ProviderSettings(provider: .anthropic, apiKey: "sk-ant-test-123456789"), http: http)
        let r = try await p.complete(LLMRequest(model: "claude-x", system: "sys", messages: [LLMMessage(.user, "hi")],
                                                jsonSchema: schema, schemaName: "summary", maxOutputTokens: 500))
        #expect(try JSONValue.parse(r.text)["title"]?.string == "Weekly sync")
        #expect(r.inputTokens == 1200 && r.outputTokens == 80)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.headers["x-api-key"] == "sk-ant-test-123456789")
        #expect(req.headers["anthropic-version"] == AnthropicProvider.apiVersion)
        #expect(req.body?["system"]?.string == "sys")
        #expect(req.body?["max_tokens"]?.int == 500)
        #expect(req.body?["tool_choice"]?["name"]?.string == "summary")
        #expect(req.body?["tools"]?[0]?["input_schema"] == schema)
    }

    @Test func anthropicFallsBackWhenForcedToolIsRejected() async throws {
        StubURLProtocol.reset { c in
            if c.body?["tool_choice"]?["type"]?.string == "tool" {
                return (400, [:], #"{"type":"error","error":{"type":"invalid_request_error","message":"tool_choice: type \"tool\" and \"any\" are not supported for this model"}}"#)
            }
            return (200, [:], #"{"content":[{"type":"tool_use","name":"summary","input":{"title":"T"}}],"usage":{"input_tokens":5,"output_tokens":2}}"#)
        }
        let p = try AnthropicProvider(settings: ProviderSettings(provider: .anthropic, apiKey: "sk-ant-test-123456789"), http: http)
        let req = LLMRequest(model: "claude-thinking-only", messages: [LLMMessage(.user, "hi")], jsonSchema: schema, schemaName: "summary")
        #expect(try await p.complete(req).text == #"{"title":"T"}"#)
        #expect(StubURLProtocol.requests.map { $0.body?["tool_choice"]?["type"]?.string } == ["tool", "auto"])
        #expect(StubURLProtocol.requests.last?.body?["system"]?.string?.contains("calling the summary tool") == true)
        _ = try await p.complete(req)                                     // remembered: goes straight to auto
        #expect(StubURLProtocol.requests.count == 3)
    }

    @Test func anthropicDropsTemperatureWhenDeprecated() async throws {
        StubURLProtocol.reset { c in
            if c.body?["temperature"] != nil {
                return (400, [:], #"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#)
            }
            return (200, [:], #"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#)
        }
        let p = try AnthropicProvider(settings: ProviderSettings(provider: .anthropic, apiKey: "sk-ant-test-123456789"), http: http)
        let req = LLMRequest(model: "claude-no-temp", messages: [LLMMessage(.user, "hi")])
        #expect(try await p.complete(req).text == "ok")
        #expect(StubURLProtocol.requests.map { $0.body?["temperature"] != nil } == [true, false])
        _ = try await p.complete(req)
        #expect(StubURLProtocol.requests.count == 3)                         // remembered
    }

    @Test func openAIRequestShapeAndUsage() async throws {
        StubURLProtocol.reset { _ in (200, [:], """
            {"model":"gpt-5-mini","choices":[{"message":{"role":"assistant","content":"{\\"title\\":\\"A\\"}"},"finish_reason":"stop"}],
             "usage":{"prompt_tokens":10,"completion_tokens":5}}
            """) }
        let p = try OpenAIProvider(settings: ProviderSettings(provider: .openAI, apiKey: "sk-proj-abcdefghijklmnopqrstuvwxyz"), http: http)
        let r = try await p.complete(LLMRequest(model: "gpt-5-mini", system: "sys", messages: [LLMMessage(.user, "hi")], jsonSchema: schema))
        #expect(r.text == "{\"title\":\"A\"}")
        #expect(r.outputTokens == 5)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(req.headers["Authorization"] == "Bearer sk-proj-abcdefghijklmnopqrstuvwxyz")
        #expect(req.body?["messages"]?[0]?["role"]?.string == "system")
        #expect(req.body?["max_completion_tokens"] != nil)
        #expect(req.body?["temperature"] == nil)                       // reasoning models reject non-default temperature
        #expect(req.body?["response_format"]?["type"]?.string == "json_schema")
    }

    @Test func azureUsesDeploymentURLAndApiKeyHeader() async throws {
        StubURLProtocol.reset { _ in (200, [:], #"{"choices":[{"message":{"content":"OK"}}]}"#) }
        let p = try OpenAIProvider(settings: ProviderSettings(provider: .azureOpenAI, apiKey: "azkey", baseURL: "https://acme.openai.azure.com/",
                                                              azureDeployment: "gpt4o-prod"), http: http)
        let check = try await p.testConnection()
        #expect(check.models == ["gpt4o-prod"])
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.url.absoluteString == "https://acme.openai.azure.com/openai/deployments/gpt4o-prod/chat/completions?api-version=\(OpenAIProvider.defaultAzureAPIVersion)")
        #expect(req.headers["api-key"] == "azkey")
        #expect(req.headers["Authorization"] == nil)
        #expect(req.body?["model"] == nil)
    }

    @Test func openAIModelListKeepsChatModelsOnly() async throws {
        StubURLProtocol.reset { _ in (200, [:], """
            {"data":[{"id":"gpt-5-mini"},{"id":"text-embedding-3-large"},{"id":"gpt-4o-realtime-preview"},{"id":"o3"},{"id":"dall-e-3"},{"id":"gpt-4.1"}]}
            """) }
        let p = try OpenAIProvider(settings: ProviderSettings(provider: .openAI, apiKey: "sk-xxxxxxxxxxxxxxxxxxxxxx"), http: http)
        #expect(try await p.listModels() == ["gpt-4.1", "gpt-5-mini", "o3"])
    }

    @Test func geminiRequestAndSchemaConversion() async throws {
        StubURLProtocol.reset { _ in (200, [:], """
            {"candidates":[{"content":{"parts":[{"text":"{\\"title\\":\\"G\\"}"}]},"finishReason":"STOP"}],
             "usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3},"modelVersion":"gemini-2.5-flash"}
            """) }
        let p = try GeminiProvider(settings: ProviderSettings(provider: .gemini, apiKey: "AIzaTestKey"), http: http)
        let r = try await p.complete(LLMRequest(model: "models/gemini-2.5-flash", system: "sys", messages: [LLMMessage(.user, "hi")], jsonSchema: schema))
        #expect(r.text == "{\"title\":\"G\"}")
        #expect(r.inputTokens == 7)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.url.path == "/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(req.headers["x-goog-api-key"] == "AIzaTestKey")
        let gs = req.body?["generationConfig"]?["responseSchema"]
        #expect(gs?["additionalProperties"] == nil)
        #expect(gs?["properties"]?["owner"]?["type"]?.string == "string")
        #expect(gs?["properties"]?["owner"]?["nullable"] == .bool(true))
        #expect(req.body?["systemInstruction"]?["parts"]?[0]?["text"]?.string == "sys")
    }

    @Test func geminiModelListFiltersGenerateContent() async throws {
        StubURLProtocol.reset { _ in (200, [:], """
            {"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent","countTokens"]},
                       {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}]}
            """) }
        let p = try GeminiProvider(settings: ProviderSettings(provider: .gemini, apiKey: "AIzaTestKey"), http: http)
        #expect(try await p.listModels() == ["gemini-2.5-flash"])
    }

    @Test func ollamaChatWithFormatSchema() async throws {
        StubURLProtocol.reset { c in
            c.url.path == "/api/tags" ? (200, [:], #"{"models":[{"name":"llama3.1:8b"},{"name":"qwen2.5:7b"}]}"#)
                : (200, [:], #"{"model":"llama3.1:8b","message":{"role":"assistant","content":"{}"},"prompt_eval_count":9,"eval_count":2}"#)
        }
        let p = try OllamaProvider(settings: ProviderSettings(provider: .ollama), http: http)
        #expect(try await p.testConnection().models == ["llama3.1:8b", "qwen2.5:7b"])
        let r = try await p.complete(LLMRequest(model: "llama3.1:8b", messages: [LLMMessage(.user, "hi")], jsonSchema: schema))
        #expect(r.outputTokens == 2)
        let req = try #require(StubURLProtocol.requests.last)
        #expect(req.url.absoluteString == "http://localhost:11434/api/chat")
        #expect(req.body?["format"] == schema)
        #expect(req.body?["stream"] == .bool(false))
        #expect(throws: LLMError.self) { try OllamaProvider(settings: ProviderSettings(provider: .ollama, baseURL: "http://10.0.0.5:11434")) }
    }

    @Test func errorMapping() async throws {
        let p = try OpenAIProvider(settings: ProviderSettings(provider: .openAI, apiKey: "sk-xxxxxxxxxxxxxxxxxxxxxx"), http: http)
        let cases: [(Int, [String: String], String, LLMError)] = [
            (401, [:], #"{"error":{"message":"Incorrect API key provided: sk-proj-abcdefghijklmnopqrstuv"}}"#, .invalidKey("Incorrect API key provided: sk-…REDACTED")),
            (429, ["retry-after": "12"], #"{"error":{"message":"Rate limit reached"}}"#, .rateLimited(retryAfter: 12)),
            (429, [:], #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota"}}"#, .quotaExceeded("You exceeded your current quota")),
            (404, [:], #"{"error":{"message":"The model `gpt-9` does not exist"}}"#, .modelNotFound("The model `gpt-9` does not exist")),
            (503, [:], "upstream down", .server(status: 503, message: "upstream down")),
        ]
        for (status, headers, body, expected) in cases {
            StubURLProtocol.reset { _ in (status, headers, body) }
            await #expect(throws: expected) { try await p.listModels() }
        }
        StubURLProtocol.reset { _ in (-1, [:], "") }
        await #expect(throws: LLMError.network("no internet connection")) { try await p.listModels() }
        #expect(LLMError.rateLimited(retryAfter: nil).isTransient)
        #expect(!LLMError.invalidKey(nil).isTransient)
    }

    @Test func missingConfigurationIsReportedBeforeAnyRequest() {
        #expect(throws: LLMError.self) { try AnthropicProvider(settings: ProviderSettings(provider: .anthropic)) }
        #expect(throws: LLMError.self) { try OpenAIProvider(settings: ProviderSettings(provider: .azureOpenAI, apiKey: "k", baseURL: "https://x.openai.azure.com")) }
        #expect(throws: LLMError.self) { try OpenAIProvider(settings: ProviderSettings(provider: .openAICompatible)) }
        #expect((try? OpenAIProvider(settings: ProviderSettings(provider: .openAICompatible, baseURL: "http://localhost:1234/v1"))) != nil)
    }
}

@Suite("LLM helpers")
struct LLMHelperTests {
    @Test func sseParser() {
        var p = SSEParser()
        let lines = [": keep-alive", "data: {\"a\":1}", "", "event: x", "data: line1", "data: line2", "", "data: [DONE]", ""]
        let events = lines.compactMap { p.feed($0) }
        #expect(events == ["{\"a\":1}", "line1\nline2", "[DONE]"])
    }

    @Test func modelSuggestion() {
        #expect(ModelSuggestion.pick(["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-1"], for: .anthropic) == "claude-sonnet-4-5")
        #expect(ModelSuggestion.pick(["llama3.1:8b"], for: .ollama) == "llama3.1:8b")
        #expect(ModelSuggestion.pick([], for: .openAI) == nil)
    }

    @Test func jsonValueRoundTrip() throws {
        let v: JSONValue = ["a": 1, "b": [true, "x", .null], "c": ["d": 2.5]]
        #expect(try JSONValue.parse(v.data()) == v)
        #expect(v.compactString() == #"{"a":1,"b":[true,"x",null],"c":{"d":2.5}}"#)
    }

    @Test func baseURLJoin() throws {
        #expect(try URL.join("https://x.com/v1/", "/models").absoluteString == "https://x.com/v1/models")
        #expect(throws: LLMError.self) { try URL.join("not a url", "/models") }
    }
}
