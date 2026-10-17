import AppKit
import EMCore
import EMTranscription
import SwiftUI

/// Transcript under the player: status / progress, speakers (click to rename), lines (click to play from there).
struct TranscriptSection: View {
    @Environment(AppState.self) private var state
    let session: Session
    var playback: SessionPlayback?
    @State private var segments: [TranscriptSegment] = []
    @State private var follow = true
    @State private var editingIndex: Int?
    @State private var editText = ""
    @State private var speakers: [Speaker] = []
    @State private var renaming: Speaker?
    @State private var newName = ""

    private var byID: [String: Speaker] { Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let p = state.jobProgress[session.id] {
                ProgressView(value: p.fraction) { Text(p.message).font(.caption) }
            }
            if let note = state.jobNotes[session.id] {
                Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if !speakers.isEmpty { speakerChips }
            if session.echoRisk, !segments.isEmpty {
                Label("Recorded on the Mac's speakers — the call echo picked up by your mic was removed. Headphones give cleaner transcripts.",
                      systemImage: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
            }
            if segments.isEmpty {
                if state.jobProgress[session.id] == nil, state.jobNotes[session.id] == nil {
                    Text(TranscriptionPreferences.current.autoTranscribe ? "No transcript yet."
                         : "Automatic transcription is off (Settings ▸ Transcription).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                lines
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.transcriptVersion) { load() }
        .onChange(of: session.id) { load() }
    }

    private var header: some View {
        HStack {
            Text("Transcript").font(.headline)
            if !segments.isEmpty { Text("\(segments.count) lines").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if state.jobProgress[session.id] != nil {
                Button("Cancel") { state.cancelTranscription(session.id) }.controlSize(.small)
            } else if segments.isEmpty {
                Button("Transcribe now") { state.transcribe(session.id, now: true) }
            } else {
                Button("Re-transcribe") { state.transcribe(session.id, now: true) }
                    .help("Run transcription again with the current settings (keeps speaker names)")
                Button("Copy") { copy() }
            }
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) { chipRow }
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(speakers, id: \.id) { sp in
                Button {
                    newName = sp.displayName ?? ""
                    renaming = sp
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(sp)).frame(width: 8, height: 8)
                        Text(sp.name).lineLimit(1).fixedSize()
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Rename \(sp.name) in this meeting")
                .popover(isPresented: Binding(get: { renaming?.id == sp.id }, set: { if !$0 { renaming = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rename \(sp.label)").font(.headline)
                        TextField(sp.label, text: $newName).frame(width: 200).onSubmit { save(sp) }
                        HStack {
                            if sp.displayName != nil { Button("Reset") { newName = ""; save(sp) } }
                            Spacer()
                            Button("Save") { save(sp) }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    /// Index of the line being played (last line starting at or before the playhead) — binary search.
    private var currentIndex: Int? {
        guard let ms = playback?.currentMs, playback?.isPlaying == true || (playback?.currentTime ?? 0) > 0, !segments.isEmpty else { return nil }
        var lo = 0, hi = segments.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].startMs <= ms { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private var lines: some View {
        let current = currentIndex
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 4) {
                if playback != nil {
                    Toggle("Follow playback", isOn: $follow).toggleStyle(.checkbox).font(.caption)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                            line(i, seg, isCurrent: i == current).id(i)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .onChange(of: current) { _, c in
                guard follow, let c, editingIndex == nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(c, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func line(_ i: Int, _ seg: TranscriptSegment, isCurrent: Bool) -> some View {
        let sp = seg.speakerID.flatMap { byID[$0] }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(seg.timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(sp?.name ?? (seg.track == .mic ? "Me" : "Others")).font(.caption.bold())
                .foregroundStyle(sp.map(color) ?? Color.secondary)
                .frame(width: 84, alignment: .leading).lineLimit(1)
            if editingIndex == i {
                TextField("", text: $editText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(seg) }
                Button("Save") { commitEdit(seg) }.controlSize(.small)
                Button("Cancel") { editingIndex = nil }.controlSize(.small)
            } else {
                Text(seg.text + (seg.isEdited ? " ✎" : ""))
                    .onTapGesture(count: 2) { editText = seg.text; editingIndex = i }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if editingIndex != i { play(seg.startMs) } }
        .help("Click to play from \(seg.timestamp) · double-click the text to correct it")
    }

    private func play(_ ms: Int) {
        if let playback { playback.play(atMs: ms) } else { state.play(session.id, atMs: ms) }
    }

    private func commitEdit(_ seg: TranscriptSegment) {
        state.editSegment(seg, text: editText)
        editingIndex = nil
    }

    private func load() {
        let t = state.transcript(for: session.id)
        segments = t.segments
        speakers = t.speakers
    }

    private func save(_ sp: Speaker) {
        state.renameSpeaker(sp, to: newName)
        renaming = nil
    }

    private static let palette: [Color] = [.purple, .orange, .green, .pink, .teal, .brown, .indigo]
    private func color(_ sp: Speaker) -> Color {
        if sp.isMe { return .accentColor }
        let others = speakers.filter { !$0.isMe }
        let i = others.firstIndex { $0.id == sp.id } ?? 0
        return Self.palette[i % Self.palette.count]
    }

    private func copy() {
        let text = segments.map { s in
            "[\(s.timestamp)] \(s.speakerID.flatMap { byID[$0]?.name } ?? "?"): \(s.text)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Sidebar search results (FTS over transcripts). Click → open the meeting and play from that line.
struct SearchResultsView: View {
    @Environment(AppState.self) private var state
    let query: String

    var body: some View {
        let hits = state.search(query)
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                    Button {
                        if let ms = h.startMs { state.play(h.sessionID, atMs: ms) } else { state.selectedSessionID = h.sessionID }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(state.session(h.sessionID)?.title ?? "Meeting").font(.caption.bold())
                                Spacer()
                                if let ms = h.startMs { Text(TranscriptSegment.format(ms: ms)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            Self.highlighted(h.snippet).font(.callout).lineLimit(3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// FTS snippet marks matches as [word] → bold.
    static func highlighted(_ snippet: String) -> Text {
        var out = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            out += AttributedString(String(rest[..<open]))
            var match = AttributedString(String(rest[rest.index(after: open)..<close]))
            match.inlinePresentationIntent = .stronglyEmphasized
            out += match
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(String(rest))
        return Text(out)
    }
}
