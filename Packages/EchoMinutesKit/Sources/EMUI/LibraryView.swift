import EMCore
import SwiftUI

/// Main window: meeting library (EM-029 shell; real detail view in EM-120…127).
public struct LibraryView: View {
    public static let windowID = "library"
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var filter = LibraryFilter()
    @State private var pendingDelete: Session?

    public init() {}

    public var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView(query: query)
                } else if state.sessions.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Join a call in Teams, Zoom or WhatsApp — EchoMinutes will record it automatically."))
                } else if state.filteredSessions(filter).isEmpty {
                    ContentUnavailableView("No matching meetings", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Change or clear the filter."))
                } else {
                    List(selection: $state.selectedSessionID) {
                        ForEach(SessionGrouping.group(state.filteredSessions(filter), now: Date())) { group in
                            Section(group.title) {
                                ForEach(group.sessions) { s in
                                    SessionRowView(session: s)
                                        .tag(s.id)
                                        .contextMenu {
                                            if state.hasAudio(s.id) { Button("Delete audio only") { state.deleteAudio(s.id) } }
                                            Button("Delete…", role: .destructive) { pendingDelete = s }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .searchable(text: $query, placement: .sidebar, prompt: "Search transcripts, summaries, notes")
            .safeAreaInset(edge: .top) { filterBar }
            #if DEBUG
            .toolbar {
                ToolbarItem {
                    Button { state.addSampleSession() } label: { Label("Add sample meeting", systemImage: "plus") }
                        .help("Debug: insert a fake meeting")
                }
            }
            #endif
        } detail: {
            if let s = state.session(state.selectedSessionID) {
                SessionDetailView(session: s).id(s.id)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "rectangle.stack",
                                       description: Text("Pick a meeting in the sidebar."))
            }
        }
        .navigationTitle("EchoMinutes")
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete meeting", role: .destructive) { if let s = pendingDelete { state.deleteSession(s.id) } }
        } message: {
            Text("The recording, transcript, summary, notes and action items are removed. This can't be undone.")
        }
        .onAppear { state.reloadSessions() }
    }
}

extension LibraryView {
    private var filterBar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("App", selection: $filter.appID) {
                    Text("All apps").tag(String?.none)
                    ForEach(state.libraryApps, id: \.self) { Text(SessionGrouping.appDisplayName($0)).tag(String?.some($0)) }
                }
                Picker("Date", selection: $filter.range) {
                    ForEach(LibraryFilter.Range.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Has open action items", isOn: $filter.openActionsOnly)
                if filter.isActive { Divider(); Button("Clear filter") { filter = LibraryFilter() } }
            } label: {
                Label(filterLabel, systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Text("\(state.filteredSessions(filter).count) meetings").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var filterLabel: String {
        guard filter.isActive else { return "Filter" }
        var parts: [String] = []
        if let a = filter.appID { parts.append(SessionGrouping.appDisplayName(a)) }
        if filter.range != .any { parts.append(filter.range.rawValue) }
        if filter.openActionsOnly { parts.append("Open actions") }
        return parts.joined(separator: " · ")
    }
}

struct SessionRowView: View {
    let session: Session
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SessionGrouping.appSymbol(session.sourceAppID))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(SessionGrouping.durationText(session))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.status != .ready {
                Text(session.status.rawValue.capitalized)
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

