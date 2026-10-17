import Foundation

/// When a user template is picked automatically (EM-172). Every condition that is set must hold;
/// a rule with no conditions never matches (the template is only used when chosen by hand).
public struct TemplateRule: Codable, Sendable, Equatable {
    /// Detection app ids ("teams", "meet", …); empty = any app.
    public var appIDs: [String]
    /// Regular expression matched case-insensitively against the meeting title.
    public var titlePattern: String?
    /// 1 = Sunday … 7 = Saturday; empty = any day.
    public var weekdays: [Int]
    /// Start-time window in minutes since midnight (may wrap midnight); nil = any time.
    public var startMinute: Int?
    public var endMinute: Int?

    public init(appIDs: [String] = [], titlePattern: String? = nil, weekdays: [Int] = [], startMinute: Int? = nil, endMinute: Int? = nil) {
        self.appIDs = appIDs; self.titlePattern = titlePattern; self.weekdays = weekdays
        self.startMinute = startMinute; self.endMinute = endMinute
    }

    public var isEmpty: Bool {
        appIDs.isEmpty && (titlePattern ?? "").isEmpty && weekdays.isEmpty && startMinute == nil
    }

    /// nil when the pattern is a valid regular expression (or empty).
    public var patternError: String? {
        guard let p = titlePattern, !p.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: p, options: [.caseInsensitive]); return nil }
        catch { return "Invalid title pattern: \(p)" }
    }

    public func matches(appID: String?, title: String, date: Date, calendar: Calendar = .current) -> Bool {
        guard !isEmpty else { return false }
        if !appIDs.isEmpty, !appIDs.contains(appID ?? "") { return false }
        if let p = titlePattern, !p.isEmpty, title.range(of: p, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        if !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: date)) { return false }
        if let s = startMinute, let e = endMinute, s != e {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            let inside = s < e ? (m >= s && m < e) : (m >= s || m < e)
            if !inside { return false }
        }
        return true
    }
}

/// A summary template written by the user (EM-170). Same idea as the built-ins: focus instructions on top of
/// the shared summary schema, plus optional headings for the key points.
public struct UserTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var instructions: String
    /// Optional headings the key points are grouped under ("Risks", "Budget"…).
    public var sections: [String]
    public var rule: TemplateRule?
    /// Lower = checked first when several rules match.
    public var priority: Int
    /// Built-in template it was duplicated from.
    public var basedOn: String?

    public init(id: String = "user-" + UUID().uuidString.prefix(8).lowercased(), name: String, instructions: String,
                sections: [String] = [], rule: TemplateRule? = nil, priority: Int = 100, basedOn: String? = nil) {
        self.id = id; self.name = name; self.instructions = instructions; self.sections = sections
        self.rule = rule; self.priority = priority; self.basedOn = basedOn
    }

    public static let maxInstructionLength = 4_000

    /// Problems that prevent saving / importing; empty when valid.
    public var problems: [String] {
        var p: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Name is empty") }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append("\(name): instructions are empty") }
        if instructions.count > Self.maxInstructionLength { p.append("\(name): instructions longer than \(Self.maxInstructionLength) characters") }
        if let e = rule?.patternError { p.append("\(name): \(e)") }
        return p
    }
}

/// File format for template import / export (EM-173).
public struct TemplateFile: Codable, Sendable, Equatable {
    public var format: String
    public var version: Int
    public var templates: [UserTemplate]
    public init(templates: [UserTemplate]) { format = "echominutes-templates"; version = 1; self.templates = templates }
}

/// One turn of "Ask the meeting" (EM-176).
public struct AskMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, error }
    public var id: String
    public var sessionID: SessionID
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var provider: ProviderID?
    public var model: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?

    public init(id: String = UUID().uuidString, sessionID: SessionID, role: Role, text: String, createdAt: Date = Date(),
                provider: ProviderID? = nil, model: String? = nil, tokensIn: Int? = nil, tokensOut: Int? = nil, costUSD: Double? = nil) {
        self.id = id; self.sessionID = sessionID; self.role = role; self.text = text; self.createdAt = createdAt
        self.provider = provider; self.model = model; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.costUSD = costUSD
    }
}
