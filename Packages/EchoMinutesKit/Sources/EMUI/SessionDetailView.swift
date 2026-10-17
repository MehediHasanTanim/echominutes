import AppKit
import EMCore
import EMExport
import SwiftUI

/// Meeting page (EM-122…127): editable title, player, tabs Summary / Transcript / Action items / Notes,
/// export and delete.
struct SessionDetailView: View {
    @Environment(AppState.self) private var state
    let session: Session
    @State private var playback = SessionPlayback()
    @State private var tab: Tab = .summary
    @State private var title = ""
    @State private var showExport = false
    @State private var confirmDelete: DeleteKind?

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", transcript = "Transcript", actions = "Action items", notes = "Notes"
        var id: String { rawValue }
    }
    enum DeleteKind: Identifiable { case meeting, audio; var id: Int { self == .meeting ? 0 : 1 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch session.status {
            case .ready, .transcribing, .summarizing:
                if let dir = state.paths?.sessionDir(session.id) {
                    PlayerView(session: session, directory: dir, playback: playback)
                }
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                tabContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .interrupted:
                Label("This recording was interrupted (app quit or crashed).", systemImage: "exclamationmark.triangle")
                Button("Recover recording") { Task { await state.recoverSession(session.id) } }
            case .finalizing:
                ProgressView("Saving recording…")
            case .failed:
                Label("Saving this recording failed.", systemImage: "xmark.octagon").foregroundStyle(.red)
                Button("Try again") { Task { await state.recoverSession(session.id) } }
            default:
                Text("Recording in progress…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { title = session.title; honour(state.playRequest) }
        .onChange(of: session.title) { _, t in title = t }
        .onChange(of: state.playRequest) { _, r in honour(r) }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showExport) { ExportSheet(sessionID: session.id) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { kind in
            Button(kind == .meeting ? "Delete meeting" : "Delete audio", role: .destructive) {
                playback.stop()
                if kind == .meeting { state.deleteSession(session.id) } else { state.deleteAudio(session.id) }
            }
        } message: { kind in
            Text(kind == .meeting ? "The recording, transcript, summary, notes and action items are removed. This can't be undone."
                                  : "Frees disk space. The transcript, summary, notes and action items are kept.")
        }
    }

    private var confirmTitle: String { confirmDelete == .meeting ? "Delete “\(session.title)”?" : "Delete the audio of “\(session.title)”?" }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain).font(.title2.bold())
                    .onSubmit { state.renameSession(session.id, to: title) }
                    .help("Click to rename")
                HStack(spacing: 8) {
                    Label(SessionGrouping.appDisplayName(session.sourceAppID), systemImage: SessionGrouping.appSymbol(session.sourceAppID))
                    Text("·")
                    Text("\(session.startedAt.formatted(date: .complete, time: .shortened)) · \(SessionGrouping.durationText(session))")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Menu {
                Button("Delete audio only…") { confirmDelete = .audio }.disabled(!state.hasAudio(session.id))
                Button("Delete meeting…", role: .destructive) { confirmDelete = .meeting }
            } label: { Image(systemName: "trash") }
            .fixedSize()
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .summary: ScrollView { SummarySection(session: session).padding(.trailing, 8) }
        case .transcript: TranscriptSection(session: session, playback: playback)
        case .actions: ActionItemsTab(session: session, playback: playback)
        case .notes: NotesTab(session: session)
        }
    }

    /// Search hits / notifications / bookmarks ask AppState to play a moment; route it to this player.
    private func honour(_ r: AppState.PlayRequest?) {
        guard let r, r.sessionID == session.id, r.nonce != state.handledPlayNonce else { return }
        state.handledPlayNonce = r.nonce
        if tab == .summary || tab == .notes { tab = .transcript }
        let pb = playback
        Task { @MainActor in pb.play(atMs: r.ms) }               // after the player view has loaded the file
    }
}

/// Editable action items with checkboxes (EM-124).
struct ActionItemsTab: View {
    @Environment(AppState.self) private var state
    let session: Session
    let playback: SessionPlayback
    @State private var items: [ActionItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(items.filter { !$0.isDone }.count) open of \(items.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Copy as checklist") { state.copyChecklist(session.id) }.disabled(items.isEmpty)
            }
            if items.isEmpty {
                Text("No action items — they come from the summary.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($items) { $item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Toggle("", isOn: $item.isDone).toggleStyle(.checkbox).labelsHidden()
                                .onChange(of: item.isDone) { state.updateActionItem(item) }
                            TextField("Task", text: $item.text, axis: .vertical)
                                .textFieldStyle(.plain).strikethrough(item.isDone)
                                .onSubmit { state.updateActionItem(item) }
                            TextField("Owner", text: Binding(get: { item.owner ?? "" }, set: { item.owner = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 110)
                                .onSubmit { state.updateActionItem(item) }
                            TextField("Due", text: Binding(get: { item.due ?? "" }, set: { item.due = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 90)
                                .onSubmit { state.updateActionItem(item) }
                            if let ms = item.timestampMs {
                                Button(TranscriptSegment.format(ms: ms)) { playback.play(atMs: ms) }
                                    .buttonStyle(.link).font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
            }
            Text("Edit a field and press Return to save.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { items = state.actionItems(for: session.id) }
        .onChange(of: state.summaryVersion) { items = state.actionItems(for: session.id) }
    }
}

/// Free-form notes, saved automatically while typing (EM-125).
struct NotesTab: View {
    @Environment(AppState.self) private var state
    let session: Session
    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var saved = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text(saved ? "Saved · Markdown supported · included in search and exports" : "Saving…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { text = session.notesMarkdown ?? "" }
        .onChange(of: text) { _, new in
            guard new != (session.notesMarkdown ?? "") else { return }
            saved = false
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                state.saveNotes(session.id, new)
                saved = true
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if text != (session.notesMarkdown ?? "") { state.saveNotes(session.id, text) }
        }
    }
}

/// Export options (EM-126).
struct ExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let sessionID: SessionID
    @State private var sections: Set<MeetingExporter.Section> = [.summary, .actionItems, .transcript, .notes]
    @State private var format: MeetingExporter.Format = .markdown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export meeting").font(.headline)
            ForEach(MeetingExporter.Section.allCases) { s in
                Toggle(s.title, isOn: Binding(get: { sections.contains(s) }, set: { if $0 { sections.insert(s) } else { sections.remove(s) } }))
            }
            Picker("Format", selection: $format) {
                Text("Markdown (.md)").tag(MeetingExporter.Format.markdown)
                Text("Plain text (.txt)").tag(MeetingExporter.Format.text)
            }
            .pickerStyle(.radioGroup)
            Divider()
            HStack {
                Menu("Download audio…") {
                    Button("Everyone (balanced mix)") { state.exportAudio(sessionID, track: .mixed) }
                    Button("Only me") { state.exportAudio(sessionID, track: .mic) }
                    Button("Only the call") { state.exportAudio(sessionID, track: .system) }
                }
                .fixedSize()
                .disabled(!state.hasAudio(sessionID))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    if state.exportToFile(sessionID, sections: sections, format: format) != nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sections.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
