import AppKit
import EMCore
import EMExport
import EMStorage
import Foundation
import UniformTypeIdentifiers

/// Library filters (EM-121).
public struct LibraryFilter: Equatable {
    public enum Range: String, CaseIterable, Identifiable {
        case any = "Any time", today = "Today", week = "Last 7 days", month = "Last 30 days"
        public var id: String { rawValue }
        func start(_ now: Date) -> Date? {
            switch self {
            case .any: nil
            case .today: Calendar.current.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86_400)
            case .month: now.addingTimeInterval(-30 * 86_400)
            }
        }
    }
    public var appID: String?            // nil = all apps
    public var range: Range = .any
    public var openActionsOnly = false
    public var isActive: Bool { appID != nil || range != .any || openActionsOnly }
    public init() {}
}

extension AppState {
    public func filteredSessions(_ f: LibraryFilter, now: Date = Date()) -> [Session] {
        let open: Set<SessionID> = f.openActionsOnly ? (database.flatMap { try? SummaryRepository($0).withOpenActionItems() } ?? []) : []
        let start = f.range.start(now)
        return sessions.filter { s in
            (f.appID == nil || s.sourceAppID == f.appID)
                && (start.map { s.startedAt >= $0 } ?? true)
                && (!f.openActionsOnly || open.contains(s.id))
        }
    }

    /// Apps that appear in the library (for the filter menu).
    public var libraryApps: [String] { Array(Set(sessions.compactMap(\.sourceAppID))).sorted() }

    public func renameSession(_ id: SessionID, to title: String) {
        guard let database, var s = session(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != s.title else { return }
        s.title = t
        s.titleIsUserEdited = true
        try? SessionRepository(database).update(s)
    }

    public func saveNotes(_ id: SessionID, _ notes: String) {
        guard let database else { return }
        try? SessionRepository(database).setNotes(id, notes)
    }

    public func editSegment(_ segment: TranscriptSegment, text: String) {
        guard let database, let sid = segment.id else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != segment.text else { return }
        do { try TranscriptRepository(database).editSegment(id: sid, text: t); transcriptVersion += 1 }
        catch { lastError = "Edit failed: \(error.localizedDescription)" }
    }

    public func updateActionItem(_ item: ActionItem) {
        guard let database else { return }
        try? SummaryRepository(database).updateActionItem(item)
        summaryVersion += 1
    }

    // MARK: - Delete (EM-127)

    public func hasAudio(_ id: SessionID) -> Bool {
        guard let paths else { return false }
        return FileManager.default.fileExists(atPath: paths.sessionDir(id).appendingPathComponent("mixed.m4a").path)
    }

    /// Frees disk space but keeps transcript, summary, notes and action items.
    public func deleteAudio(_ id: SessionID) {
        guard let paths, let database else { return }
        let dir = paths.sessionDir(id)
        for name in ["mixed.m4a", "mic.m4a", "system.m4a", "waveform.bin", "chunks"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        try? SessionRepository(database).saveTracks(id, [])
        Log.info(.storage, "Deleted audio of \(id)")
        transcriptVersion += 1
    }

    // MARK: - Export (EM-126)

    func exportMeeting(_ id: SessionID) -> MeetingExporter.Meeting? {
        guard let s = session(id) else { return nil }
        let t = transcript(for: id)
        let names = Dictionary(uniqueKeysWithValues: t.speakers.map { ($0.id, $0.name) })
        let current = summaries(for: id).first { $0.isCurrent }
        return MeetingExporter.Meeting(
            title: s.title, app: SessionGrouping.appDisplayName(s.sourceAppID), date: s.startedAt,
            durationText: SessionGrouping.durationText(s), summary: current?.content,
            summaryMarkdown: current?.content == nil ? current?.markdown : nil,
            actionItems: actionItems(for: id),
            lines: t.segments.map { .init(startMs: $0.startMs, speaker: $0.speakerID.flatMap { names[$0] } ?? "?", text: $0.text) },
            notes: s.notesMarkdown ?? "")
    }

    /// Shows a save panel and writes the export. Returns the saved URL.
    @discardableResult
    public func exportToFile(_ id: SessionID, sections: Set<MeetingExporter.Section>, format: MeetingExporter.Format) -> URL? {
        guard let m = exportMeeting(id) else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingExporter.fileName(title: m.title, date: m.date, format: format)
        panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try MeetingExporter.render(m, sections: sections, format: format).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { lastError = "Export failed: \(error.localizedDescription)"; return nil }
    }

    public func exportAudio(_ id: SessionID, track: TrackKind = .mixed) {
        guard let paths, let s = session(id) else { return }
        let src = paths.sessionDir(id).appendingPathComponent("\(track.rawValue).m4a")
        let panel = NSSavePanel()
        let base = MeetingExporter.fileName(title: s.title, date: s.startedAt, format: .text).replacingOccurrences(of: ".txt", with: "")
        panel.nameFieldStringValue = base + (track == .mixed ? "" : " (\(track == .mic ? "me" : "others"))") + ".m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: src, to: url)
        } catch { lastError = "Audio export failed: \(error.localizedDescription)" }
    }

    public func copyChecklist(_ id: SessionID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingExporter.checklist(actionItems(for: id)), forType: .string)
    }
}
