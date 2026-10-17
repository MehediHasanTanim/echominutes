import EMAudio
import EMCore
import SwiftUI

/// Settings ▸ Recording: microphone, audio quality, echo handling. Applies to the next recording.
struct RecordingSettingsView: View {
    @AppStorage(RecordingPreferences.includeMicKey) private var includeMic = true
    @AppStorage(RecordingPreferences.micDeviceUIDKey) private var micUID = ""
    @AppStorage(RecordingPreferences.bitRateKey) private var bitRate = RecordingPreferences.defaultBitRate
    @AppStorage(RecordingPreferences.echoDedupKey) private var echoDedup = true
    @State private var inputs: [AudioDevices.Input] = []

    var body: some View {
        Form {
            Section("Microphone") {
                Toggle("Record my microphone", isOn: $includeMic)
                Picker("Input device", selection: $micUID) {
                    Text("System default").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                    if !micUID.isEmpty, !inputs.contains(where: { $0.uid == micUID }) {
                        Text("Not connected (uses system default)").tag(micUID)
                    }
                }
                .disabled(!includeMic)
                Text(includeMic
                     ? "If the chosen device isn't connected when a call starts, the system default microphone is used."
                     : "Only the other people on the call are recorded. Your own voice won't be in the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quality") {
                Picker("Audio quality", selection: $bitRate) {
                    ForEach(RecordingPreferences.bitRates, id: \.self) { rate in
                        Text(label(rate)).tag(rate)
                    }
                }
                Text("Applies to new recordings. Transcription works equally well at every setting; higher quality only sounds nicer on playback and uses more disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Echo handling") {
                Toggle("Remove echo when using speakers", isOn: $echoDedup)
                Text("Without headphones your microphone also picks up the other people, so their words would appear twice. This removes those repeated lines from the transcript. Headphones give the cleanest result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { inputs = AudioDevices.inputs() }
    }

    private func label(_ rate: Int) -> String {
        let name = switch rate { case 48_000: "Compact"; case 64_000: "Standard"; case 96_000: "High"; default: "Best" }
        return "\(name) — \(rate / 1000) kbps (~\(RecordingPreferences.megabytesPerHour(rate)) MB per hour per track)"
    }
}
