import Carbon.HIToolbox
import EMCore
import Foundation

/// System-wide hotkeys via Carbon `RegisterEventHotKey` (EM-074): works in an LSUIElement app and needs no
/// Accessibility permission. Defaults: ⌃⌥⌘R start/stop, ⌃⌥⌘B bookmark, ⌃⌥⌘W show/hide the mini widget.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()
    public nonisolated static let enabledKey = "hotkeys.enabled"

    public struct Shortcut: Sendable {
        public let id: UInt32
        public let title: String
        public let display: String
        let keyCode: UInt32
    }
    public static let defaults: [Shortcut] = [
        Shortcut(id: 1, title: "Start / stop recording", display: "⌃⌥⌘R", keyCode: UInt32(kVK_ANSI_R)),
        Shortcut(id: 2, title: "Bookmark this moment", display: "⌃⌥⌘B", keyCode: UInt32(kVK_ANSI_B)),
        Shortcut(id: 3, title: "Show / hide mini widget", display: "⌃⌥⌘W", keyCode: UInt32(kVK_ANSI_W)),
    ]
    private static let modifiers = UInt32(cmdKey | optionKey | controlKey)
    private static let signature: OSType = 0x454D_484B          // 'EMHK'

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var savedActions: [UInt32: () -> Void] = [:]

    public static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func registerDefaults(toggleRecording: @escaping () -> Void, bookmark: @escaping () -> Void, toggleWidget: @escaping () -> Void) {
        savedActions = [1: toggleRecording, 2: bookmark, 3: toggleWidget]
        apply()
    }

    /// Re-applies after the Settings toggle changes.
    public func apply() {
        unregisterAll()
        guard Self.enabled, !savedActions.isEmpty else { return }
        installHandlerIfNeeded()
        for s in Self.defaults {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(s.keyCode, Self.modifiers, EventHotKeyID(signature: Self.signature, id: s.id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[s.id] = savedActions[s.id]
            } else {
                Log.error(.ui, "Hotkey \(s.display) unavailable (status \(status)) — another app may use it")
            }
        }
        Log.info(.ui, "Registered \(refs.count) hotkeys")
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &handler)
    }
}

/// Carbon delivers hotkey events on the main thread.
private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr else { return status }
    let id = hk.id
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
    return noErr
}
