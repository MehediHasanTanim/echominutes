import EMCore
import Foundation

/// The structured summary every provider must return (Technical Design §10.3, EM-110).
public enum SummarySchema {
    public static let name = "meeting_summary"

    static let strings: JSONValue = ["type": "array", "items": ["type": "string"]]
    static let nullableString: JSONValue = ["type": ["string", "null"]]

    public static let json: JSONValue = .object([
        "type": "object",
        "required": ["title", "tldr", "key_points", "decisions", "action_items", "open_questions", "next_steps"],
        "properties": .object([
            "title": ["type": "string", "description": "Short meeting title, max 8 words"],
            "tldr": ["type": "string", "description": "2–3 sentence summary"],
            "key_points": strings,
            "decisions": strings,
            "action_items": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "required": ["task"],
                    "properties": .object([
                        "task": ["type": "string"],
                        "owner": nullableString,
                        "due": nullableString,
                        "timestamp": .object(["type": ["string", "null"], "description": "mm:ss where it was agreed"]),
                    ]),
                ]),
            ]),
            "open_questions": strings,
            "next_steps": strings,
        ]),
    ])
}

/// Lenient-but-checked decoding of a model's answer (EM-110): tolerates ```json fences and prose around the
/// object, `null` for empty lists and arrays of objects-with-text; reports precise problems for the retry prompt.
public enum SummaryValidator {
    public struct Invalid: Error, Equatable, Sendable, LocalizedError {
        public var problems: [String]
        public var errorDescription: String? { "Summary didn't match the schema: " + problems.joined(separator: "; ") }
    }

    public static func validate(_ text: String) throws -> SummaryContent {
        guard let v = extractJSON(text) else { throw Invalid(problems: ["answer is not a JSON object"]) }
        var problems: [String] = []
        func str(_ k: String, required: Bool = true) -> String {
            if let s = v[k]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            if required { problems.append("\"\(k)\" must be a non-empty string") }
            return ""
        }
        func list(_ k: String) -> [String] {
            switch v[k] {
            case .array(let a)?:
                return a.compactMap { $0.string ?? $0["text"]?.string ?? $0["task"]?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            case .null?, nil:
                if v[k] == nil { problems.append("missing \"\(k)\" (use [] when empty)") }
                return []
            case .string(let s)?:
                return s.isEmpty ? [] : [s]
            default:
                problems.append("\"\(k)\" must be an array of strings"); return []
            }
        }
        let title = str("title"), tldr = str("tldr")
        let keyPoints = list("key_points"), decisions = list("decisions"), questions = list("open_questions"), next = list("next_steps")
        var actions: [SummaryContent.Action] = []
        switch v["action_items"] {
        case .array(let a)?:
            for (i, item) in a.enumerated() {
                if let s = item.string { actions.append(.init(task: s)); continue }
                guard let task = item["task"]?.string ?? item["text"]?.string, !task.isEmpty else {
                    problems.append("action_items[\(i)] needs a \"task\" string"); continue
                }
                func opt(_ k: String) -> String? { item[k]?.string.flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 } }
                actions.append(.init(task: task, owner: opt("owner"), due: opt("due"), timestamp: opt("timestamp")))
            }
        case .null?: break
        case nil: problems.append("missing \"action_items\" (use [] when empty)")
        default: problems.append("\"action_items\" must be an array")
        }
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        return SummaryContent(title: title, tldr: tldr, keyPoints: keyPoints, decisions: decisions, actionItems: actions,
                              openQuestions: questions, nextSteps: next)
    }

    /// The first balanced {...} in the text (models sometimes add fences or a sentence).
    static func extractJSON(_ text: String) -> JSONValue? {
        if let v = try? JSONValue.parse(text), v.object != nil { return v }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return try? JSONValue.parse(String(text[start...i])) }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

/// Markdown view of a summary (stored alongside the JSON; used for copy/export and search).
public enum SummaryMarkdown {
    public static func render(_ s: SummaryContent) -> String {
        var out = "# \(s.title)\n\n\(s.tldr)\n"
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out += "\n## \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        section("Key points", s.keyPoints)
        section("Decisions", s.decisions)
        if !s.actionItems.isEmpty {
            out += "\n## Action items\n" + s.actionItems.map { a in
                var line = "- [ ] \(a.task)"
                var meta: [String] = []
                if let o = a.owner { meta.append("owner: \(o)") }
                if let d = a.due { meta.append("due: \(d)") }
                if let t = a.timestamp { meta.append("at \(t)") }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n") + "\n"
        }
        section("Open questions", s.openQuestions)
        section("Next steps", s.nextSteps)
        return out
    }

    /// "12:34" or "1:02:03" → milliseconds.
    public static func ms(fromTimestamp t: String?) -> Int? {
        guard let t else { return nil }
        let parts = t.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 } * 1000
    }
}
