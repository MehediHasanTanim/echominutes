import AppKit
import EMCore
import EMTranscription
import SwiftUI

/// Transcript under the player (EM-081 demo): status / progress, actions, and the segments.
struct TranscriptSection: View {
    @Environment(AppState.self) private var state
    let session: Session
    @State private var segments: [TranscriptSegment] = []
    @State private var speakers: [String: Speaker] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                if state.jobProgress[session.id] != nil {
                    Button("Cancel") { state.cancelTranscription(session.id) }.controlSize(.small)
                } else if segments.isEmpty {
                    Button("Transcribe now") { state.transcribe(session.id, now: true) }
                } else {
                    Menu("Re-transcribe") {
                        Button("With current settings") { state.transcribe(session.id, now: true) }
                    }
                    .fixedSize()
                    Button("Copy") { copy() }
                }
            }
            if let p = state.jobProgress[session.id] {
                ProgressView(value: p.fraction) { Text(p.message).font(.caption) }
            }
            if let note = state.jobNotes[session.id] {
                Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if segments.isEmpty {
                if state.jobProgress[session.id] == nil, state.jobNotes[session.id] == nil {
                    Text(TranscriptionPreferences.current.autoTranscribe
                         ? "No transcript yet."
                         : "Automatic transcription is off (Settings ▸ Transcription).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(seg.timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                Text(name(seg)).font(.caption.bold())
                                    .foregroundStyle(seg.track == .mic ? Color.accentColor : Color.purple)
                                    .frame(width: 56, alignment: .leading)
                                Text(seg.text).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.transcriptVersion) { load() }
        .onChange(of: session.id) { load() }
    }

    private func load() {
        let t = state.transcript(for: session.id)
        segments = t.segments
        speakers = Dictionary(uniqueKeysWithValues: t.speakers.map { ($0.id, $0) })
    }

    private func name(_ seg: TranscriptSegment) -> String {
        seg.speakerID.flatMap { speakers[$0]?.name } ?? (seg.track == .mic ? "Me" : "Others")
    }

    private func copy() {
        let text = segments.map { "[\($0.timestamp)] \(name($0)): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
