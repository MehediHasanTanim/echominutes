import AppKit
import EMCore
import SwiftUI

/// Menu bar dropdown (EM-028, Feature Spec §5.7).
public struct MenuContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let version: String

    public init(version: String) { self.version = version }

    public var body: some View {
        Text("EchoMinutes \(version)")
        Text(state.status.label)
        if let err = state.startupError { Text("⚠︎ \(err)") }
        Divider()

        Button("Start Recording Now") {}          // EM-055
            .disabled(true)
        Divider()

        if !state.recentSessions.isEmpty {
            Text("Recent")
            ForEach(state.recentSessions) { s in
                Button("\(s.title) · \(SessionGrouping.durationText(s))") {
                    state.selectedSessionID = s.id
                    showLibrary()
                }
            }
            Divider()
        }

        #if DEBUG
        Button("Debug: Capture Test…") {
            openWindow(id: DebugCaptureView.windowID)
            NSApp.activate()
        }
        #endif
        Button("Open Library…") { showLibrary() }
            .keyboardShortcut("l")
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit EchoMinutes") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showLibrary() {
        state.reloadSessions()
        openWindow(id: LibraryView.windowID)
        NSApp.activate()
    }
}

/// Menu bar icon reflecting the app status.
public struct MenuBarIcon: View {
    @Environment(AppState.self) private var state
    public init() {}
    public var body: some View { Image(systemName: state.status.symbolName) }
}
