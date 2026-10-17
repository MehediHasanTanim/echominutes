import EMCore
import Foundation
import Testing
@testable import EMExport

@Suite("MeetingExporter")
struct ExporterTests {
    let sid = SessionID()
    var meeting: MeetingExporter.Meeting {
        MeetingExporter.Meeting(
            title: "Budget / Q1 sync", app: "Microsoft Teams", date: Date(timeIntervalSince1970: 1_800_000_000), durationText: "32 min",
            summary: SummaryContent(title: "Budget", tldr: "We approved it.", keyPoints: ["Costs up 5%"], decisions: ["Approve"]),
            summaryMarkdown: nil,
            actionItems: [ActionItem(sessionID: sid, summaryID: nil, text: "Send sheet", owner: "Rahim", due: "Fri", timestampMs: 192_000),
                          ActionItem(sessionID: sid, summaryID: nil, text: "Book room", isDone: true)],
            lines: [.init(startMs: 0, speaker: "Tanim", text: "Hello"), .init(startMs: 65_000, speaker: "Rahim", text: "Hi")],
            notes: "Remember the deck.")
    }

    @Test func markdownAllSections() {
        let md = MeetingExporter.render(meeting, sections: Set(MeetingExporter.Section.allCases), format: .markdown)
        #expect(md.hasPrefix("# Budget / Q1 sync\n"))
        #expect(md.contains("## Summary\n\nWe approved it."))
        #expect(md.contains("### Decisions\n\n- Approve"))
        #expect(md.contains("- [ ] Send sheet — Rahim, due Fri (03:12)"))
        #expect(md.contains("- [x] Book room"))
        #expect(md.contains("## Notes\n\nRemember the deck."))
        #expect(md.contains("**[01:05] Rahim:** Hi"))
    }

    @Test func textWithSelectedSectionsOnly() {
        let txt = MeetingExporter.render(meeting, sections: [.transcript], format: .text)
        #expect(txt.contains("TRANSCRIPT\n----------\n[00:00] Tanim: Hello\n[01:05] Rahim: Hi"))
        #expect(!txt.contains("Summary") && !txt.contains("Send sheet") && !txt.contains("Remember"))
    }

    @Test func fileNameIsSafe() {
        let name = MeetingExporter.fileName(title: "Budget / Q1: sync?", date: Date(timeIntervalSince1970: 1_800_000_000), format: .markdown)
        #expect(name.hasSuffix(" Budget - Q1- sync-.md"))
        #expect(!name.contains("/"))
    }
}
