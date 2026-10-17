import AppKit
import EMCore
import EMSummarization
import SwiftUI

/// First-run setup (EM-130): welcome + consent → permissions → AI provider → apps → speech model → test call.
/// Re-open any time from the menu ▸ Setup Guide…
public struct OnboardingView: View {
    public static let windowID = "onboarding"
    public static let doneKey = "onboarding.done"
    public static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step = 0
    @State private var perms = PermissionsModel()
    @State private var provider: ProviderID = .anthropic
    @AppStorage(LLMPreferences.summaryProviderKey) private var summaryProvider = ""
    @AppStorage(PrivacyPreferences.consentReminderKey) private var consentReminder = false
    @AppStorage(TranscriptionPreferences.myNameKey) private var myName = ""

    private let titles = ["Welcome", "Permissions", "AI summaries", "Apps to watch", "Speech model", "Test call"]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Text(titles[i]).font(.caption.weight(i == step ? .bold : .regular))
                        .foregroundStyle(i == step ? .primary : .secondary)
                    if i < titles.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(.vertical, 12)
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: summaries
                case 3: DetectionSettingsView()
                case 4: TranscriptionSettingsView()
                default: testCall
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step == 2 { Button("Skip for now") { step += 1 } }
                if step < titles.count - 1 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                        .disabled(step == 0 && myName.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Finish") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 720, height: 600)
        .task { await perms.refresh() }
    }

    private var welcome: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("EchoMinutes records your Teams, Zoom and WhatsApp calls automatically, transcribes them on this Mac, and writes a summary with decisions and action items.")
                    Text("Audio and transcripts stay on this Mac. Only the transcript text is sent to the AI provider you choose for summaries — or nothing at all if you use Ollama locally.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Your name") {
                TextField("Shown instead of “Me” in transcripts", text: $myName)
            }
            Section("Recording consent") {
                Text("Recording laws differ by country and state — some require that everyone on the call agrees. You are responsible for telling participants that you record.")
                Toggle("Remind me with a ready-to-paste message whenever a recording starts", isOn: $consentReminder)
            }
        }
        .formStyle(.grouped)
    }

    private var permissions: some View {
        Form {
            Section {
                PermissionRow(title: "Microphone", detail: "Records your side of the call", status: perms.mic,
                              action: perms.mic == .granted ? nil : ("Allow", { Task { await perms.requestMic() } }),
                              settings: { PermissionsModel.open(.microphone) })
                PermissionRow(title: "Notifications", detail: "“Recording started”, Stop / Discard, “Summary ready”", status: perms.notifications,
                              action: perms.notifications == .granted ? nil : ("Allow", { Task { await perms.requestNotifications() } }),
                              settings: { PermissionsModel.open(.notifications) })
                PermissionRow(title: "System audio recording", detail: "Records the other people — run the test below; macOS asks the first time",
                              status: perms.systemAudio, action: nil, settings: { PermissionsModel.open(.systemAudio) })
            }
            Section("Audio test") {
                HStack {
                    Button(perms.testing ? "Testing… say something" : "Run 5-second audio test") { Task { await perms.runAudioTest() } }
                        .disabled(perms.testing)
                    if perms.testing { ProgressView().controlSize(.small) }
                }
                if let r = perms.lastTest {
                    if let e = r.error { Text(e).foregroundStyle(.red) }
                    else {
                        Text(r.systemOK ? "✓ Call audio captured" : "✗ Call audio not captured — allow EchoMinutes in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then test again.")
                            .foregroundStyle(r.systemOK ? .green : .red)
                        Text(r.micOK ? "✓ Microphone works" : "! Microphone was silent — check the input device in System Settings ▸ Sound.")
                            .foregroundStyle(r.micOK ? .green : .orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var summaries: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Provider", selection: $provider) {
                ForEach(ProviderID.allCases) { Text($0.displayName).tag($0) }
            }
            .padding([.horizontal, .top], 20)
            Text("Pick a cloud provider and paste its key, or choose Ollama to keep everything on this Mac.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            ProviderDetailView(provider: provider, summaryProvider: $summaryProvider) {}
                .id(provider)
        }
    }

    private var testCall: some View {
        Form {
            Section("Try it") {
                Text("1. Start a call — e.g. Teams ▸ Calls ▸ “Make a test call”, or a Zoom test meeting (zoom.us/test).")
                Text("2. Within a few seconds a red dot appears in the menu bar and a “Recording…” notification shows.")
                Text("3. Hang up. About 15 s later the recording is saved, then transcribed and summarised automatically.")
                Button("Open Detection Monitor to watch it live") { openWindow(id: DetectionMonitorView.windowID); NSApp.activate() }
            }
            Section("Good to know") {
                Text("• The menu bar icon controls everything: stop, discard, bookmark, open the Library.")
                Text("• Shortcuts: ⌃⌥⌘R start/stop · ⌃⌥⌘B bookmark · ⌃⌥⌘W mini widget.")
                Text("• Use headphones for the cleanest transcripts; on speakers the echo is filtered out.")
                Toggle("Launch EchoMinutes at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { try? LoginItem.set(enabled: $0) }))
            }
        }
        .formStyle(.grouped)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        state.applyDetectionSettings()
        dismissWindow(id: Self.windowID)
    }
}
