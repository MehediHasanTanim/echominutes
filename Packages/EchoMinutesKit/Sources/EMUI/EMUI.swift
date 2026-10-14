import AppKit
import EMCore
import SwiftUI

/// EMUI — SwiftUI views and view models.
public enum EMUIModule {
    public static let name = "EMUI"
    public static let dependencies: [String] = ["EMCore"]
}

/// Menu bar content (placeholder until EM-028).
public struct MenuContentView: View {
    private let version: String
    public init(version: String) { self.version = version }

    public var body: some View {
        Text("EchoMinutes \(version)")
        Text("Idle — not monitoring yet")
        Text("\(EchoMinutes.allModules.count) modules loaded")
        Divider()
        Button("Quit EchoMinutes") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
