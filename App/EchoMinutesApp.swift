import EMCore
import EMUI
import SwiftUI

/// EchoMinutes — menu bar agent (LSUIElement). Composition root: wires the EchoMinutesKit modules together.
@main
struct EchoMinutesApp: App {
    @State private var state = AppState.live()
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(version: version).environment(state)
        } label: {
            MenuBarIcon().environment(state)
        }

        Window("EchoMinutes", id: LibraryView.windowID) {
            LibraryView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView().environment(state)
        }
    }
}
