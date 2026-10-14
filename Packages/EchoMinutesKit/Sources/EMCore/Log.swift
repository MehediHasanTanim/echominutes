import Foundation
import os

/// Logging facade over os.Logger (EM-027). Subsystem com.tanimkabir.echominutes, one category per area.
public enum Log {
    public static let subsystem = "com.tanimkabir.echominutes"
    public enum Category: String, CaseIterable, Sendable { case app, detection, audio, session, stt, llm, jobs, storage, ui }

    public static func logger(_ c: Category) -> Logger { Logger(subsystem: subsystem, category: c.rawValue) }

    public static func info(_ c: Category, _ message: String) { logger(c).info("\(Redactor.redact(message), privacy: .public)") }
    public static func debug(_ c: Category, _ message: String) { logger(c).debug("\(Redactor.redact(message), privacy: .public)") }
    public static func error(_ c: Category, _ message: String) { logger(c).error("\(Redactor.redact(message), privacy: .public)") }
}

/// Removes secrets (API keys, bearer tokens) from any text before it is logged or exported.
public enum Redactor {
    // Ordered most specific first.
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, "sk-ant-…REDACTED"),
        (#"sk-(proj-)?[A-Za-z0-9_\-]{16,}"#, "sk-…REDACTED"),
        (#"AIza[0-9A-Za-z_\-]{30,}"#, "AIza…REDACTED"),
        (#"(?i)(bearer\s+)[A-Za-z0-9._\-]{12,}"#, "$1…REDACTED"),
        (#"(?i)((?:api[_-]?key|x-api-key|api-key|x-goog-api-key)\s*[:=]\s*\"?)[^\s\",]{8,}"#, "$1…REDACTED"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String) -> String {
        var out = text
        for (re, template) in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    /// Masked display form for Settings: "sk-…a9F2".
    public static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = key.hasPrefix("sk-ant-") ? "sk-ant-" : key.hasPrefix("sk-") ? "sk-" : String(key.prefix(3))
        return "\(prefix)…\(key.suffix(4))"
    }
}
