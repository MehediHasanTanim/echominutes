import EMCore
import ServiceManagement
import SwiftUI

/// Settings window with all tabs from Feature Spec §10 (EM-029). Only General is functional so far.
public struct SettingsView: View {
    public init() {}
    public var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            PlaceholderSettings(title: "Detection", detail: "Watched apps and Auto / Ask / Never per app — EM-075").tabItem { Label("Detection", systemImage: "dot.radiowaves.left.and.right") }
            PlaceholderSettings(title: "Recording", detail: "Input device, quality, echo handling — Sprint 4").tabItem { Label("Recording", systemImage: "record.circle") }
            PlaceholderSettings(title: "Transcription", detail: "Local model, language, vocabulary — EM-087").tabItem { Label("Transcription", systemImage: "text.bubble") }
            PlaceholderSettings(title: "AI Summary", detail: "Provider, model, templates — Sprint 10").tabItem { Label("AI Summary", systemImage: "sparkles") }
            PlaceholderSettings(title: "Providers", detail: "API keys (stored in Keychain) with Test connection — EM-106").tabItem { Label("Providers", systemImage: "key") }
            PlaceholderSettings(title: "Privacy & Storage", detail: "Retention, local-only apps, storage usage — EM-133").tabItem { Label("Privacy", systemImage: "lock.shield") }
            PlaceholderSettings(title: "Diagnostics", detail: "Permissions, audio test, log export — EM-132").tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 600, height: 380)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("myName") private var myName = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                Toggle("Launch EchoMinutes at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(enabled: on); loginError = nil }
                        catch { loginError = error.localizedDescription; launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
                if LoginItem.requiresApproval {
                    Text("Approve EchoMinutes in System Settings ▸ General ▸ Login Items.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                TextField("Your name (shown instead of \"Me\")", text: $myName)
            }
            Section("Storage") {
                LabeledContent("Library folder", value: state.paths?.root.path ?? "unavailable")
                LabeledContent("Meetings", value: "\(state.sessions.count)")
            }
        }
        .formStyle(.grouped)
    }
}

struct PlaceholderSettings: View {
    let title: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text(detail))
    }
}

/// Launch-at-login via SMAppService (EM-030).
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    public static func set(enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        Log.info(.app, "Launch at login → \(enabled) (status \(SMAppService.mainApp.status.rawValue))")
    }
}
