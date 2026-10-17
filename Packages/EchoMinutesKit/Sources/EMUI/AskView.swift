import EMCore
import EMSummarization
import SwiftUI

/// "Ask" tab (EM-175): questions about this meeting, answered from its transcript; `[mm:ss]` citations jump
/// the player to that moment. History is kept per meeting (EM-176).
struct AskView: View {
    @Environment(AppState.self) private var state
    let session: Session
    var playback: SessionPlayback
    @State private var question = ""

    var body: some View {
        let messages = state.askMessages(session.id)
        let busy = state.askBusy.contains(session.id)
        let hasTranscript = !state.transcript(for: session.id).segments.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if !hasTranscript {
                Text("Questions can be asked once the meeting has a transcript.").foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if messages.isEmpty { suggestions }
                            ForEach(messages) { bubble($0) }
                            if busy {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the transcript…").foregroundStyle(.secondary) }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.trailing, 8)
                    }
                    .onChange(of: state.askVersion) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
                HStack {
                    TextField("Ask about this meeting…", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Ask", action: send).disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !messages.isEmpty {
                        Menu {
                            Button("Clear conversation", role: .destructive) { state.clearAsk(session.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                Text("Answers come only from the transcript (sent to your AI provider; “Local only” apps use Ollama). Click a [mm:ss] to hear that moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "echominutes-seek", let ms = Int(url.host ?? "") else { return .systemAction }
            playback.play(atMs: ms)
            return .handled
        })
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !state.askBusy.contains(session.id) else { return }
        question = ""
        Task { await state.ask(q, about: session.id) }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try asking").font(.caption).foregroundStyle(.secondary)
            FlowButtons(items: state.suggestedQuestions(session.id)) { q in
                question = ""
                Task { await state.ask(q, about: session.id) }
            }
        }
    }

    @ViewBuilder private func bubble(_ m: AskMessage) -> some View {
        switch m.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(m.text)
                    .padding(8).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.linked(m.text)).textSelection(.enabled)
                if let meta = Self.meta(m) { Text(meta).font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .error:
            Label(m.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
    }

    /// Markdown with each `[mm:ss]` turned into a link that seeks the player.
    static func linked(_ text: String) -> AttributedString {
        let ns = text as NSString
        var md = ""
        var last = 0
        for m in Citations.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            md += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let raw = ns.substring(with: m.range)
            if let ms = Citations.ms(raw) { md += "[\(raw)](echominutes-seek://\(ms))" } else { md += raw }
            last = m.range.location + m.range.length
        }
        md += ns.substring(from: last)
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func meta(_ m: AskMessage) -> String? {
        var parts = [m.model].compactMap { $0 }
        if let c = m.costUSD { parts.append(c == 0 ? "free (local)" : String(format: "≈ $%.4f", c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Buttons that wrap onto several lines.
struct FlowButtons: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { q in
                Button(q) { action(q) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}
