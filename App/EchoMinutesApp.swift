import EMCore
import EMUI
import SwiftUI

/// EchoMinutes — menu bar agent (LSUIElement). Composition root: wires the EchoMinutesKit modules together.
@main
struct EchoMinutesApp: App {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    var body: some Scene {
        MenuBarExtra("EchoMinutes", systemImage: "waveform.circle") {
            MenuContentView(version: version)
        }
    }
}
