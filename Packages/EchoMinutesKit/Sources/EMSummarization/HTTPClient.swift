import EMCore
import Foundation

/// Shared HTTP layer for all providers (EM-101): JSON in/out, 120 s timeout, status → `LLMError` mapping,
/// `retry-after` hints, and an SSE line parser for streaming. Tests inject a URLSession with a stub URLProtocol.
public struct HTTPClient: Sendable {
    public let session: URLSession
    public let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 120) {
        self.session = session; self.timeout = timeout
    }

    public func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: JSONValue? = nil) throws -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.httpBody = try body.data()
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// Sends and returns parsed JSON; non-2xx statuses throw a mapped `LLMError`.
    public func json(_ request: URLRequest) async throws -> JSONValue {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let e as URLError { throw LLMError.network(Self.describe(e)) }
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data, headers: http) }
        do { return try JSONValue.parse(data) }
        catch { throw LLMError.badResponse("invalid JSON (\(data.count) bytes)") }
    }

    // MARK: - Error mapping

    static func error(status: Int, data: Data, headers: HTTPURLResponse) -> LLMError {
        let body = (try? JSONValue.parse(data))
        let message = body.flatMap(errorMessage) ?? String(data: data.prefix(300), encoding: .utf8).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let msg = message.map { Redactor.redact(String($0.prefix(240))) }.flatMap { $0.isEmpty ? nil : $0 }
        let lower = (msg ?? "").lowercased()
        switch status {
        case 401: return .invalidKey(msg)
        case 403:
            return lower.contains("quota") || lower.contains("billing") ? .quotaExceeded(msg) : .invalidKey(msg)
        case 402: return .quotaExceeded(msg)
        case 404: return lower.contains("model") ? .modelNotFound(msg ?? "") : .badRequest(msg ?? "Not found (check the base URL)")
        case 429:
            if lower.contains("quota") || lower.contains("credit") || lower.contains("billing") || lower.contains("insufficient") {
                return .quotaExceeded(msg)
            }
            return .rateLimited(retryAfter: retryAfter(headers))
        case 400, 413, 422:
            if lower.contains("api key") || lower.contains("api_key") { return .invalidKey(msg) }
            if lower.contains("credit") || lower.contains("balance") { return .quotaExceeded(msg) }
            return .badRequest(msg)
        case 500...599: return status == 529 ? .rateLimited(retryAfter: retryAfter(headers)) : .server(status: status, message: msg)
        default: return .server(status: status, message: msg)
        }
    }

    /// {"error":{"message":…}} (OpenAI, Anthropic, Gemini), {"error":"…"} (Ollama), {"message":…}.
    static func errorMessage(_ v: JSONValue) -> String? {
        v["error"]?["message"]?.string ?? v["error"]?.string ?? v["message"]?.string ?? v["detail"]?.string
    }

    static func retryAfter(_ r: HTTPURLResponse) -> TimeInterval? {
        if let s = r.value(forHTTPHeaderField: "retry-after"), let n = TimeInterval(s) { return n }
        if let s = r.value(forHTTPHeaderField: "retry-after-ms"), let n = TimeInterval(s) { return n / 1000 }
        return nil
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet: "no internet connection"
        case .timedOut: "the request timed out"
        case .cannotFindHost, .dnsLookupFailed: "host not found (check the base URL)"
        case .cannotConnectToHost: "connection refused (is the server running?)"
        case .secureConnectionFailed, .serverCertificateUntrusted: "secure connection failed"
        case .appTransportSecurityRequiresSecureConnection: "plain http is only allowed for localhost"
        default: e.localizedDescription
        }
    }
}

/// Server-Sent Events: feed raw lines, get the `data:` payloads of complete events (EM-101).
public struct SSEParser: Sendable {
    private var dataLines: [String] = []
    public init() {}

    /// Returns a payload when `line` completes an event (blank line). "[DONE]" is passed through.
    public mutating func feed(_ line: String) -> String? {
        let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if l.isEmpty {
            defer { dataLines = [] }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        if l.hasPrefix(":") { return nil }                       // comment / keep-alive
        if l.hasPrefix("data:") {
            var v = String(l.dropFirst(5))
            if v.hasPrefix(" ") { v.removeFirst() }
            dataLines.append(v)
        }
        return nil
    }
}

extension URL {
    /// base + path, tolerating trailing/leading slashes in user-entered base URLs.
    static func join(_ base: String, _ path: String) throws -> URL {
        let b = base.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let p = path.hasPrefix("/") ? path : "/" + path
        guard let u = URL(string: b + p), u.scheme == "https" || u.scheme == "http" else {
            throw LLMError.notConfigured("Invalid base URL “\(base)”")
        }
        return u
    }
}
