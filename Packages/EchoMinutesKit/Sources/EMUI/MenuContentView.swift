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

        RecordingMenuSection()
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
        Button("Debug: Detection Monitor…") {
            openWindow(id: DetectionMonitorView.windowID)
            NSApp.activate()
        }
        #endif
        Button("Open Library…") { showLibrary() }
            .keyboardShortcut("l")
        Button("Setup Guide…") {
            openWindow(id: OnboardingView.windowID)
            NSApp.activate()
        }
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

/// Menu bar icon reflecting the app status (EM-072): idle (outline), watching (filled), recording (red dot +
/// elapsed time), processing (hourglass). Also opens the Library on request, since this label is always alive.
public struct MenuBarIcon: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    public init() {}

    public var body: some View {
        // A single, rarely-changing image: a label that re-renders every second (timer text) can make the
        // status item stop responding to clicks. Elapsed time is shown in the menu and the mini widget instead.
        Group {
            if case .recording = state.status {
                Image(nsImage: Self.redDot)
            } else {
                Image(systemName: state.status.symbolName)
            }
        }
        .onChange(of: state.libraryOpenRequest) {
            openWindow(id: LibraryView.windowID)
            NSApp.activate()
        }
        .task {
            // First launch: show the setup guide (EM-130).
            if !OnboardingView.isDone {
                try? await Task.sleep(for: .milliseconds(600))
                openWindow(id: OnboardingView.windowID)
                NSApp.activate()
            }
        }
    }

    /// Non-template image so the menu bar keeps it red.
    @MainActor static let redDot: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [.systemRed]))
        let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config) ?? NSImage()
        img.isTemplate = false
        return img
    }()
}
