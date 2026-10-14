import AppKit
import EMCore
import UserNotifications

/// User notifications with actions (EM-071, EM-076): recording started (Stop / Discard), "Record this call?"
/// (Record / Ignore), recording saved (Open), other-app and error notices.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let started = "RECORDING_STARTED"
        static let ask = "ASK_RECORD"
        static let saved = "RECORDING_SAVED"
        static let info = "INFO"
    }
    enum Action {
        static let stop = "STOP"
        static let discard = "DISCARD"
        static let record = "RECORD"
        static let ignore = "IGNORE"
        static let open = "OPEN"
    }
    private static let startedID = "recording-started"

    private weak var state: AppState?
    private var configured = false

    public override init() { super.init() }

    /// Needs a real app bundle (not unit tests).
    public func setup(state: AppState) {
        self.state = state
        guard !configured, Bundle.main.bundleIdentifier != nil else { return }
        configured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.started, actions: [
                UNNotificationAction(identifier: Action.stop, title: "Stop & Save"),
                UNNotificationAction(identifier: Action.discard, title: "Discard", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.ask, actions: [
                UNNotificationAction(identifier: Action.record, title: "Record"),
                UNNotificationAction(identifier: Action.ignore, title: "Ignore"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.saved, actions: [
                UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.info, actions: [], intentIdentifiers: []),
        ])
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Log.info(.ui, "Notification permission: \(granted)")
            } catch {
                Log.error(.ui, "Notification permission request failed: \(error)")
            }
        }
    }

    // MARK: - Posting

    func recordingStarted(sessionID: SessionID, appName: String) {
        post(id: Self.startedID, title: "Recording \(appName) call",
             body: "EchoMinutes is recording this meeting. It stops automatically when the call ends.",
             category: Category.started, userInfo: ["sessionID": sessionID.description])
    }

    func removeRecordingStarted() { remove(Self.startedID) }

    func recordingSaved(sessionID: SessionID, title: String, durationSec: Int) {
        remove(Self.startedID)
        let d = durationSec >= 60 ? "\(durationSec / 60) min \(durationSec % 60) s" : "\(durationSec) s"
        post(id: "saved-\(sessionID)", title: "Recording saved", body: "\(title) · \(d)",
             category: Category.saved, userInfo: ["sessionID": sessionID.description])
    }

    func ask(appID: String, appName: String) {
        post(id: "ask-\(appID)", title: "Record this \(appName) call?",
             body: "Choose Record to save it (the last few seconds are kept). Ignored automatically in 20 s.",
             category: Category.ask, userInfo: ["appID": appID], sound: true)
    }

    func removeAsk(appID: String) { remove("ask-\(appID)") }

    func otherApp(appName: String, recordingAppName: String) {
        post(id: "other-\(appName)", title: "\(appName) call detected",
             body: "Still recording \(recordingAppName). Stop that recording to record \(appName).",
             category: Category.info, userInfo: [:])
    }

    func failed(_ message: String) {
        post(id: "error-\(UUID().uuidString)", title: "EchoMinutes", body: message, category: Category.info, userInfo: [:])
    }

    private func post(id: String, title: String, body: String, category: String, userInfo: [String: String], sound: Bool = false) {
        guard configured else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.error(.ui, "Notification failed: \(error)") }
        }
    }

    private func remove(_ id: String) {
        guard configured else { return }
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [id])
        c.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Delegate

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let sessionID = content.userInfo["sessionID"] as? String
        await handle(action: action, category: category, sessionID: sessionID)
    }

    private func handle(action: String, category: String, sessionID: String?) async {
        guard let state else { return }
        Log.info(.ui, "Notification action \(action) on \(category)")
        switch (category, action) {
        case (Category.started, Action.stop): await state.stopRecording()
        case (Category.started, Action.discard): await state.discardRecording()
        case (Category.ask, Action.record): await state.respondToAsk(accept: true)
        case (Category.ask, Action.ignore): await state.respondToAsk(accept: false)
        case (Category.saved, _), (Category.started, UNNotificationDefaultActionIdentifier):
            if let sessionID, let id = SessionID(string: sessionID) { state.selectedSessionID = id }
            state.reloadSessions()
            state.libraryOpenRequest += 1
        default: break
        }
    }
}
