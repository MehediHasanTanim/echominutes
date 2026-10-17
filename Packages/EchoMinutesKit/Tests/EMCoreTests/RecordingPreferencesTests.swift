import EMCore
import Foundation
import Testing

@Suite(.serialized) struct RecordingPreferencesTests {
    private func withDefaults(_ values: [String: Any], _ body: () -> Void) {
        let keys = [RecordingPreferences.includeMicKey, RecordingPreferences.micDeviceUIDKey,
                    RecordingPreferences.bitRateKey, RecordingPreferences.echoDedupKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        values.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
        body()
        for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) }
    }

    @Test func defaults() {
        withDefaults([:]) {
            #expect(RecordingPreferences.includeMic)
            #expect(RecordingPreferences.micDeviceUID == nil)
            #expect(RecordingPreferences.bitRate == 64_000)
            #expect(RecordingPreferences.echoDedup)
        }
    }

    @Test func storedValues() {
        withDefaults([RecordingPreferences.includeMicKey: false, RecordingPreferences.micDeviceUIDKey: "BuiltInMic",
                      RecordingPreferences.bitRateKey: 128_000, RecordingPreferences.echoDedupKey: false]) {
            #expect(!RecordingPreferences.includeMic)
            #expect(RecordingPreferences.micDeviceUID == "BuiltInMic")
            #expect(RecordingPreferences.bitRate == 128_000)
            #expect(!RecordingPreferences.echoDedup)
        }
    }

    @Test func invalidValuesFallBack() {
        withDefaults([RecordingPreferences.micDeviceUIDKey: "", RecordingPreferences.bitRateKey: 12_345]) {
            #expect(RecordingPreferences.micDeviceUID == nil)
            #expect(RecordingPreferences.bitRate == RecordingPreferences.defaultBitRate)
        }
    }

    @Test func sizeEstimate() {
        #expect(RecordingPreferences.megabytesPerHour(64_000) == 29)
        #expect(RecordingPreferences.megabytesPerHour(128_000) == 58)
    }
}
