import EMCore
import Foundation

/// Markdown / plain-text export of one meeting (EM-126). Pure: callers load the data, this only formats it.
public enum MeetingExporter {
    public enum Format: String, Sendable, CaseIterable { case markdown = "md", text = "txt" }
    public enum Section: String, Sendable, CaseIterable, Identifiable {
        case summary, actionItems, transcript, notes
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .summary: "Summary"
            case .actionItems: "Action items"
            case .transcript: "Transcript"
            case .notes: "Notes"
            }
        }
    }

    public struct Line: Sendable, Equatable {
        public var startMs: Int; public var speaker: String; public var text: String
        public init(startMs: Int, speaker: String, text: String) { self.startMs = startMs; self.speaker = speaker; self.text = text }
    }

    public struct Meeting: Sendable {
        public var title: String
        public var app: String
        public var date: Date
        public var durationText: String
        public var summary: SummaryContent?
        /// Plain Markdown summary when the structured one isn't available.
        public var summaryMarkdown: String?
        public var actionItems: [ActionItem]
        public var lines: [Line]
        public var notes: String
        public init(title: String, app: String, date: Date, durationText: String, summary: SummaryContent?, summaryMarkdown: String?,
                    actionItems: [ActionItem], lines: [Line], notes: String) {
            self.title = title; self.app = app; self.date = date; self.durationText = durationText; self.summary = summary
            self.summaryMarkdown = summaryMarkdown; self.actionItems = actionItems; self.lines = lines; self.notes = notes
        }
    }

    public static func render(_ m: Meeting, sections: Set<Section>, format: Format) -> String {
        let md = format == .markdown
        let df = DateFormatter(); df.dateStyle = .full; df.timeStyle = .short
        var out = md ? "# \(m.title)\n\n" : "\(m.title)\n\(String(repeating: "=", count: m.title.count))\n\n"
        out += (md ? "*" : "") + "\(m.app) · \(df.string(from: m.date)) · \(m.durationText)" + (md ? "*" : "") + "\n"

        func heading(_ t: String) -> String { md ? "\n## \(t)\n\n" : "\n\(t.uppercased())\n\(String(repeating: "-", count: t.count))\n" }
        func bullets(_ items: [String]) -> String { items.map { "- \($0)" }.joined(separator: "\n") + "\n" }

        if sections.contains(.summary) {
            if let s = m.summary {
                out += heading("Summary") + s.tldr + "\n"
                for (title, items) in [("Key points", s.keyPoints), ("Decisions", s.decisions), ("Open questions", s.openQuestions), ("Next steps", s.nextSteps)] where !items.isEmpty {
                    out += (md ? "\n### \(title)\n\n" : "\n\(title):\n") + bullets(items)
                }
            } else if let raw = m.summaryMarkdown, !raw.isEmpty {
                out += heading("Summary") + raw.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
        }
        if sections.contains(.actionItems), !m.actionItems.isEmpty {
            out += heading("Action items") + checklist(m.actionItems, markdown: md)
        }
        if sections.contains(.notes), !m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += heading("Notes") + m.notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        if sections.contains(.transcript), !m.lines.isEmpty {
            out += heading("Transcript") + m.lines.map { l in
                let ts = TranscriptSegment.format(ms: l.startMs)
                return md ? "**[\(ts)] \(l.speaker):** \(l.text)  " : "[\(ts)] \(l.speaker): \(l.text)"
            }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// "- [ ] Task — Owner, due Friday (12:34)" — also used for "Copy as checklist".
    public static func checklist(_ items: [ActionItem], markdown: Bool = true) -> String {
        items.map { a in
            var meta: [String] = []
            if let o = a.owner { meta.append(o) }
            if let d = a.due { meta.append("due \(d)") }
            var line = (markdown ? (a.isDone ? "- [x] " : "- [ ] ") : (a.isDone ? "[x] " : "[ ] ")) + a.text
            if !meta.isEmpty { line += " — " + meta.joined(separator: ", ") }
            if let ms = a.timestampMs { line += " (\(TranscriptSegment.format(ms: ms)))" }
            return line
        }.joined(separator: "\n") + "\n"
    }

    /// File-system safe name: "2026-10-16 Weekly sync.md".
    public static func fileName(title: String, date: Date, format: Format) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(df.string(from: date)) \(clean.isEmpty ? "Meeting" : String(clean.prefix(80))).\(format.rawValue)"
    }
}
