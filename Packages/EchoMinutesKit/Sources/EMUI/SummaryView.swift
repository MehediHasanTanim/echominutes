import AppKit
import EMCore
import EMSummarization
import SwiftUI

/// Summary of a meeting (EM-114…117): TL;DR, key points, decisions, action items (tick off, click time to play),
/// open questions, next steps; Regenerate with another template/provider; version history; copy as Markdown.
struct SummarySection: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    let session: Session
    @State private var versions: [Summary] = []
    @State private var shownID: String?
    @State private var actions: [ActionItem] = []

    private var shown: Summary? { versions.first { $0.id == shownID } ?? versions.first { $0.isCurrent } ?? versions.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let p = state.summaryProgress[session.id] {
                ProgressView(value: p.fraction) { Text(p.message).font(.caption) }
            }
            if let note = state.summaryNotes[session.id] {
                HStack {
                    Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    if note.contains("Settings ▸ Providers") || note.contains("API key") || note.contains("No AI provider") {
                        Button("Open Settings") { NSApp.activate(); openSettings() }.controlSize(.small)
                    }
                }
            }
            if let s = shown {
                if let c = s.content { content(c) } else {
                    Text(s.markdown).textSelection(.enabled)
                    Text("The model's answer didn't match the summary structure, so it is shown as plain text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                meta(s)
            } else if state.summaryProgress[session.id] == nil, state.summaryNotes[session.id] == nil {
                Text(state.summaryProviderProblem.map { "No summary yet. \($0)" } ?? "No summary yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.summaryVersion) { load() }
        .onChange(of: session.id) { shownID = nil; load() }
    }

    private var header: some View {
        HStack {
            Text("Summary").font(.headline)
            if versions.count > 1 {
                Picker("", selection: Binding(get: { shown?.id ?? "" }, set: { shownID = $0 })) {
                    ForEach(versions) { v in
                        Text("\(v.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(state.templateLibrary.name(v.templateID))\(v.isCurrent ? " ✓" : "")").tag(v.id)
                    }
                }
                .labelsHidden().fixedSize()
                if let s = shown, !s.isCurrent { Button("Use this version") { state.makeSummaryCurrent(s) }.controlSize(.small) }
            }
            Spacer()
            if state.summaryProgress[session.id] == nil {
                Menu(versions.isEmpty ? "Summarize" : "Regenerate") {
                    Section("Template") {
                        Button("Automatic") { state.summarize(session.id, template: "auto") }
                        ForEach(state.templateLibrary.all) { t in Button(t.name) { state.summarize(session.id, template: t.id) } }
                    }
                    if state.readyProviders.count > 1 {
                        Section("Provider") {
                            ForEach(state.readyProviders) { p in Button(p.displayName) { state.summarize(session.id, provider: p) } }
                        }
                    }
                }
                .fixedSize()
                .disabled(state.transcript(for: session.id).segments.isEmpty)
                if let s = shown {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s.markdown, forType: .string)
                    }
                }
            }
        }
    }

    @ViewBuilder private func content(_ c: SummaryContent) -> some View {
        Text(c.tldr).font(.body).textSelection(.enabled)
        list("Key points", c.keyPoints, icon: "circle.fill")
        list("Decisions", c.decisions, icon: "checkmark.seal")
        if !actions.isEmpty || !c.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Action items").font(.subheadline.bold())
                ForEach(actions.isEmpty ? c.actionItems.map { ActionItem(sessionID: session.id, summaryID: nil, text: $0.task, owner: $0.owner, due: $0.due) } : actions) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle("", isOn: Binding(get: { a.isDone }, set: { state.setActionItem(a, done: $0); load() }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(a.text).strikethrough(a.isDone).foregroundStyle(a.isDone ? .secondary : .primary).textSelection(.enabled)
                        if let o = a.owner { Text(o).font(.caption.bold()).foregroundStyle(.purple) }
                        if let d = a.due { Text("due \(d)").font(.caption).foregroundStyle(.secondary) }
                        if let ms = a.timestampMs {
                            Button(TranscriptSegment.format(ms: ms)) { state.play(session.id, atMs: ms) }
                                .buttonStyle(.link).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }
        list("Open questions", c.openQuestions, icon: "questionmark.circle")
        list("Next steps", c.nextSteps, icon: "arrow.right.circle")
    }

    @ViewBuilder private func list(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    Label { Text(t).textSelection(.enabled) } icon: { Image(systemName: icon).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func meta(_ s: Summary) -> some View {
        var parts = [s.provider?.displayName, s.model].compactMap { $0 }
        if let i = s.tokensIn, let o = s.tokensOut { parts.append("\(i + o) tokens") }
        if let c = s.costUSD { parts.append(c == 0 ? "free (local)" : String(format: "≈ $%.3f", c)) }
        parts.append(state.templateLibrary.name(s.templateID))
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }

    private func load() {
        versions = state.summaries(for: session.id)
        actions = state.actionItems(for: session.id)
    }
}
