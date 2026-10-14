import AVFoundation

enum MicCommand {
    static func run(_ args: [String]) async -> Int32 {
        let before = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.line("Microphone permission: \(describe(before))")
        switch before {
        case .authorized:
            Log.ok("Microphone access granted"); return 0
        case .notDetermined:
            Log.line("Requesting access — click Allow in the macOS prompt…")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            granted ? Log.ok("Granted") : Log.error("Denied")
            return granted ? 0 : 1
        default:
            Log.error("Denied/restricted. Fix: System Settings ▸ Privacy & Security ▸ Microphone ▸ enable SpikeLab")
            Log.line("Or reset: tccutil reset Microphone com.tanimkabir.echominutes.spikelab")
            return 1
        }
    }

    static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }
}
