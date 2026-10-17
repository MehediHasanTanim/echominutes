import AppKit
import EMCore
import EMDetection
import EMSummarization
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ AI Summary ▸ Templates (EM-170…173): built-ins (duplicate to customise), your templates
/// (edit, delete, auto-rules), import / export.
struct TemplatesSection: View {
    @Environment(AppState.self) private var state
    @State private var editing: UserTemplate?
    @State private var message: String?

    var body: some View {
        Section("Templates") {
            ForEach(state.userTemplates) { t in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name)
                        Text(ruleText(t)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = t }.controlSize(.small)
                    Menu {
                        Button("Duplicate") { editing = state.duplicateTemplate(SummaryTemplate(user: t)) }
                        Button("Delete", role: .destructive) { state.deleteTemplate(t.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            DisclosureGroup("Built-in templates") {
                ForEach(SummaryTemplate.all) { t in
                    HStack {
                        Text(t.name)
                        Spacer()
                        Button("Duplicate to customise") { editing = state.duplicateTemplate(t) }.controlSize(.small)
                    }
                }
            }
            HStack {
                Button("New template…") { editing = UserTemplate(name: "", instructions: "") }
                Spacer()
                Button("Import…") { importFile() }
                Button("Export…") { exportFile() }.disabled(state.userTemplates.isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Automatic choice: your templates' rules are checked first (in priority order), then the built-ins' keywords; otherwise General.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { t in
            TemplateEditor(template: t, isNew: !state.userTemplates.contains { $0.id == t.id }) { editing = nil }
        }
    }

    private func ruleText(_ t: UserTemplate) -> String {
        guard let r = t.rule, !r.isEmpty else { return "Used when chosen by hand" }
        var parts: [String] = []
        if !r.appIDs.isEmpty { parts.append(r.appIDs.map { SessionGrouping.appDisplayName($0) }.joined(separator: ", ")) }
        if let p = r.titlePattern, !p.isEmpty { parts.append("title ~ \(p)") }
        if !r.weekdays.isEmpty { parts.append(r.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")) }
        if let s = r.startMinute, let e = r.endMinute { parts.append(String(format: "%02d:%02d–%02d:%02d", s / 60, s % 60, e / 60, e % 60)) }
        return "Auto: " + parts.joined(separator: " · ") + " · priority \(t.priority)"
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { message = "Imported \(try state.importTemplates(from: url)) template(s)." }
        catch { message = error.localizedDescription }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "EchoMinutes templates.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try state.exportTemplates(to: url); message = "Exported \(state.userTemplates.count) template(s)." }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }
}

/// Edit one user template: name, focus instructions, headings, auto-rule; preview on a past meeting;
/// test the rule against recent meetings (EM-171/172).
struct TemplateEditor: View {
    @Environment(AppState.self) private var state
    @State var template: UserTemplate
    let isNew: Bool
    let done: () -> Void

    @State private var sectionsText = ""
    @State private var useRule = false
    @State private var rule = TemplateRule()
    @State private var useTime = false
    @State private var error: String?
    @State private var previewSession: SessionID?
    @State private var preview: String?
    @State private var previewing = false
    @State private var ruleResults: [(session: Session, template: String, reason: TemplateLibrary.Reason)] = []

    init(template: UserTemplate, isNew: Bool, done: @escaping () -> Void) {
        _template = State(initialValue: template)
        self.isNew = isNew
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New template" : "Edit template").font(.headline)
            Form {
                TextField("Name", text: $template.name)
                VStack(alignment: .leading) {
                    Text("What the summary should focus on")
                    TextEditor(text: $template.instructions).font(.body).frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    Text("\(template.instructions.count)/\(UserTemplate.maxInstructionLength)").font(.caption2).foregroundStyle(.secondary)
                }
                TextField("Key-point headings (optional, comma separated)", text: $sectionsText, prompt: Text("e.g. Risks, Budget, Timeline"))

                Toggle("Pick this template automatically when…", isOn: $useRule)
                if useRule {
                    appPicker
                    TextField("Title matches (regular expression)", text: Binding(get: { rule.titlePattern ?? "" },
                                                                                  set: { rule.titlePattern = $0.isEmpty ? nil : $0 }),
                              prompt: Text("e.g. stand-?up|daily"))
                    weekdayPicker
                    Toggle("Only between", isOn: $useTime)
                    if useTime {
                        HStack {
                            DatePicker("", selection: minutes(\.startMinute, 9 * 60), displayedComponents: .hourAndMinute).labelsHidden()
                            Text("and")
                            DatePicker("", selection: minutes(\.endMinute, 10 * 60), displayedComponents: .hourAndMinute).labelsHidden()
                        }
                    }
                    Stepper("Priority \(template.priority) (lower wins when several match)", value: $template.priority, in: 1...999)
                    HStack {
                        Button("Test against my last 20 meetings") { ruleResults = state.testTemplateRules(draftLibrary) }
                        if !ruleResults.isEmpty {
                            Text("\(ruleResults.filter { $0.reason == .rule(draft.name) }.count) would use this template")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !ruleResults.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(ruleResults.enumerated()), id: \.offset) { _, r in
                                    HStack {
                                        Text(r.session.title).lineLimit(1)
                                        Spacer()
                                        Text(r.template).foregroundStyle(r.reason == .rule(draft.name) ? Color.accentColor : .secondary)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }

                HStack {
                    Picker("Preview on", selection: $previewSession) {
                        Text("Choose a meeting…").tag(SessionID?.none)
                        ForEach(previewCandidates) { s in
                            Text(s.title).tag(SessionID?.some(s.id))
                        }
                    }
                    Button(previewing ? "Running…" : "Preview") { Task { await runPreview() } }
                        .disabled(previewSession == nil || previewing)
                }
                if let preview {
                    ScrollView { Text(LocalizedStringKey(preview)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 200)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear {
            sectionsText = template.sections.joined(separator: ", ")
            if let r = template.rule, !r.isEmpty { useRule = true; rule = r; useTime = r.startMinute != nil }
        }
    }

    /// Recent meetings with a transcript (checked lazily: only the newest 40).
    private var previewCandidates: [Session] {
        Array(state.sessions.prefix(40).filter { !state.transcript(for: $0.id).segments.isEmpty }.prefix(20))
    }

    /// The template as it would be saved now.
    private var draft: UserTemplate {
        var t = template
        t.sections = sectionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var r = rule
        if !useTime { r.startMinute = nil; r.endMinute = nil }
        t.rule = useRule && !r.isEmpty ? r : nil
        return t
    }

    private var draftLibrary: [UserTemplate] { state.userTemplates.filter { $0.id != template.id } + [draft] }

    private func save() {
        do { try state.saveTemplate(draft); done() }
        catch { self.error = error.localizedDescription }
    }

    private func runPreview() async {
        guard let id = previewSession else { return }
        previewing = true; preview = nil; error = nil
        defer { previewing = false }
        do { preview = try await state.previewSummary(draft, on: id) }
        catch { self.error = "Preview failed: \(error.localizedDescription)" }
    }

    private var appPicker: some View {
        let apps = state.currentRuleSet()?.rules.map(\.app) ?? []
        return Menu(rule.appIDs.isEmpty ? "Any app" : rule.appIDs.map { SessionGrouping.appDisplayName($0) }.joined(separator: ", ")) {
            Button("Any app") { rule.appIDs = [] }
            Divider()
            ForEach(apps, id: \.id) { a in
                Button((rule.appIDs.contains(a.id) ? "✓ " : "") + a.name) {
                    if let i = rule.appIDs.firstIndex(of: a.id) { rule.appIDs.remove(at: i) } else { rule.appIDs.append(a.id) }
                }
            }
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            Text("Days")
            ForEach(1...7, id: \.self) { d in
                let on = rule.weekdays.contains(d)
                Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                    if on { rule.weekdays.removeAll { $0 == d } } else { rule.weekdays.append(d) }
                }
                .buttonStyle(.bordered).tint(on ? .accentColor : .gray)
            }
            Text(rule.weekdays.isEmpty ? "(any day)" : "").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func minutes(_ key: WritableKeyPath<TemplateRule, Int?>, _ fallback: Int) -> Binding<Date> {
        Binding(
            get: {
                let m = rule[keyPath: key] ?? fallback
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                rule[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                if key == \TemplateRule.startMinute, rule.endMinute == nil { rule.endMinute = fallback + 60 }
                if key == \TemplateRule.endMinute, rule.startMinute == nil { rule.startMinute = 9 * 60 }
            })
    }
}
