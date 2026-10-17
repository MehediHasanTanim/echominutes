import AppKit
import EMCore
import EMStorage
import SwiftUI

/// Retention & storage (EM-133) and consent reminder (EM-134) preferences.
public enum PrivacyPreferences {
    public static let audioRetentionDaysKey = "privacy.audioRetentionDays"     // 0 = keep forever
    public static let consentReminderKey = "privacy.consentReminder"
    public static let consentMessageKey = "privacy.consentMessage"
    public static let defaultConsentMessage = "Heads-up: I'm recording this call for my notes."

    public static var audioRetentionDays: Int { UserDefaults.standard.integer(forKey: audioRetentionDaysKey) }
    public static var consentReminder: Bool { UserDefaults.standard.bool(forKey: consentReminderKey) }
    public static var consentMessage: String {
        let s = UserDefaults.standard.string(forKey: consentMessageKey) ?? ""
        return s.isEmpty ? defaultConsentMessage : s
    }
}

extension AppState {
    /// Deletes the audio (not the text) of meetings older than the retention period. Runs at launch and daily.
    @discardableResult
    public func applyRetention(now: Date = Date()) -> Int {
        let days = PrivacyPreferences.audioRetentionDays
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let old = sessions.filter { $0.startedAt < cutoff && $0.status == .ready && hasAudio($0.id) }
        old.forEach { deleteAudio($0.id) }
        if !old.isEmpty { Log.info(.storage, "Retention: deleted audio of \(old.count) meeting(s) older than \(days) days") }
        return old.count
    }

    func startRetentionTimer() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))                 // after launch work settles
            while !Task.isCancelled {
                self?.applyRetention()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    public struct StorageUsage: Sendable, Equatable { public var audio: Int64 = 0; public var other: Int64 = 0; public var models: Int64 = 0 }

    /// Disk usage of the library (computed off the main thread).
    public func storageUsage() async -> StorageUsage {
        guard let paths else { return StorageUsage() }
        return await Task.detached(priority: .utility) {
            var u = StorageUsage()
            let fm = FileManager.default
            if let e = fm.enumerator(at: paths.sessionsDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let url as URL in e {
                    let size = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                    if url.pathExtension == "m4a" || url.lastPathComponent == "waveform.bin" { u.audio += size } else { u.other += size }
                }
            }
            u.other += Int64((try? paths.databaseURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            if let e = fm.enumerator(at: paths.modelsDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let url as URL in e { u.models += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
            }
            return u
        }.value
    }
}

/// Settings ▸ Privacy.
struct StorageSettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrivacyPreferences.audioRetentionDaysKey) private var days = 0
    @AppStorage(PrivacyPreferences.consentReminderKey) private var consent = false
    @AppStorage(PrivacyPreferences.consentMessageKey) private var message = ""
    @State private var usage: AppState.StorageUsage?
    @State private var cleaned: String?

    var body: some View {
        Form {
            Section("Consent") {
                Toggle("Remind me to tell participants when a recording starts", isOn: $consent)
                if consent {
                    TextField("Message", text: $message, prompt: Text(PrivacyPreferences.defaultConsentMessage))
                    Text("The notification has a “Copy message” button so you can paste it into the meeting chat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Recording laws differ: some places require everyone's consent. You are responsible for informing participants.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keep audio") {
                Picker("Delete recordings' audio after", selection: $days) {
                    Text("Never").tag(0); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }
                Text("Transcripts, summaries, notes and action items are always kept.").font(.caption).foregroundStyle(.secondary)
                if days > 0 {
                    HStack {
                        Button("Clean up now") {
                            let n = state.applyRetention()
                            cleaned = n == 0 ? "Nothing to clean up." : "Deleted the audio of \(n) meeting\(n == 1 ? "" : "s")."
                            Task { usage = await state.storageUsage() }
                        }
                        if let cleaned { Text(cleaned).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Storage") {
                if let u = usage {
                    LabeledContent("Meeting audio", value: fmt(u.audio))
                    LabeledContent("Transcripts, summaries & database", value: fmt(u.other))
                    LabeledContent("Speech & speaker models", value: fmt(u.models))
                } else { ProgressView().controlSize(.small) }
                if let p = state.paths {
                    Button("Show library folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.root]) }
                }
            }
        }
        .formStyle(.grouped)
        .task { usage = await state.storageUsage() }
    }

    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
