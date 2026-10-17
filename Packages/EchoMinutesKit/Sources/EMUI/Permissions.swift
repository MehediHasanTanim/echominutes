import AppKit
import AVFoundation
import EMAudio
import EMCore
import EMDetection
import Observation
import UserNotifications

/// Permission status + System Settings deep links (EM-131).
@MainActor
@Observable
final class PermissionsModel {
    enum Status: Equatable { case unknown, granted, denied, notAsked, checking
        var symbol: String {
            switch self { case .granted: "checkmark.circle.fill"; case .denied: "xmark.circle.fill"; case .checking: "hourglass"; default: "circle" }
        }
    }

    var mic: Status = .unknown
    var notifications: Status = .unknown
    var systemAudio: Status = .notAsked
    /// Screen Recording = readable window titles for browser meeting detection (EM-151).
    var screenRecording: Status = .unknown
    var lastTest: AudioSelfTest.Result?
    var testing = false

    func refresh() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .notDetermined: mic = .notAsked
        default: mic = .denied
        }
        screenRecording = SystemWindowTitles.permitted ? .granted : .notAsked
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifications = .granted
        case .notDetermined: notifications = .notAsked
        default: notifications = .denied
        }
    }

    func requestMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await refresh()
        if mic == .denied { Self.open(.microphone) }
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
        if notifications == .denied { Self.open(.notifications) }
    }

    /// Shows the macOS prompt the first time; afterwards opens System Settings. macOS applies the change after
    /// EchoMinutes is reopened.
    func requestScreenRecording() async {
        if !CGRequestScreenCaptureAccess() { Self.open(.systemAudio) }
        await refresh()
    }

    /// Plays a test tone and records it (system audio) + the mic. First run shows the macOS prompts.
    func runAudioTest() async {
        testing = true; systemAudio = .checking
        let r = await AudioSelfTest.run(seconds: 5, includeMic: mic == .granted)
        lastTest = r
        systemAudio = r.systemOK ? .granted : .denied
        testing = false
        await refresh()
    }

    enum Pane { case microphone, systemAudio, notifications, loginItems }

    static func open(_ pane: Pane) {
        let s: String
        switch pane {
        case .microphone: s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .systemAudio: s = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications: s = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
        case .loginItems: s = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        }
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
