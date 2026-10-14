import EMCore
import SwiftUI

/// Main window: meeting library (EM-029 shell; real detail view in EM-120…127).
public struct LibraryView: View {
    public static let windowID = "library"
    @Environment(AppState.self) private var state

    public init() {}

    public var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            Group {
                if state.sessions.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Join a call in Teams, Zoom or WhatsApp — EchoMinutes will record it automatically."))
                } else {
                    List(selection: $state.selectedSessionID) {
                        ForEach(SessionGrouping.group(state.sessions, now: Date())) { group in
                            Section(group.title) {
                                ForEach(group.sessions) { s in
                                    SessionRowView(session: s)
                                        .tag(s.id)
                                        .contextMenu {
                                            Button("Delete…", role: .destructive) { state.deleteSession(s.id) }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .toolbar {
                #if DEBUG
                ToolbarItem {
                    Button { state.addSampleSession() } label: { Label("Add sample meeting", systemImage: "plus") }
                        .help("Debug: insert a fake meeting")
                }
                #endif
            }
        } detail: {
            if let s = state.session(state.selectedSessionID) {
                SessionDetailPlaceholder(session: s)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "rectangle.stack",
                                       description: Text("Pick a meeting in the sidebar."))
            }
        }
        .navigationTitle("EchoMinutes")
        .onAppear { state.reloadSessions() }
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

struct SessionDetailPlaceholder: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.title2.bold())
            Label(SessionGrouping.appDisplayName(session.sourceAppID), systemImage: SessionGrouping.appSymbol(session.sourceAppID))
            Text("\(session.startedAt.formatted(date: .complete, time: .shortened)) · \(SessionGrouping.durationText(session))")
                .foregroundStyle(.secondary)
            Divider()
            Text("Player, transcript, summary and action items arrive in Sprint 11.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
