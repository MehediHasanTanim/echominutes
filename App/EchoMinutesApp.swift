import AppKit
import SwiftUI

/// EchoMinutes — menu bar agent (LSUIElement). EM-020 skeleton; real menu & state arrive in EM-028.
@main
struct EchoMinutesApp: App {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    var body: some Scene {
        MenuBarExtra("EchoMinutes", systemImage: "waveform.circle") {
            Text("EchoMinutes \(version)")
            Text("Idle — not monitoring yet")
            Divider()
            Button("Quit EchoMinutes") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
