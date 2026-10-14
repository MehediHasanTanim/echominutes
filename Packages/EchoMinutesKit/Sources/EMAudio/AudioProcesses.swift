import CoreAudio
import EMCore
import Foundation

/// One Core Audio process object (Technical Design §6.2).
public struct AudioProcessInfo: Sendable, Equatable, Hashable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String          // kAudioProcessPropertyBundleID (may be empty)
    public let owningAppBundleID: String // outermost .app of the executable (helpers → parent app)
    public let executable: String
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, owningAppBundleID: String, executable: String,
                isRunningInput: Bool = false, isRunningOutput: Bool = false) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID; self.owningAppBundleID = owningAppBundleID
        self.executable = executable; self.isRunningInput = isRunningInput; self.isRunningOutput = isRunningOutput
    }
}

public enum AudioProcesses {
    /// Snapshot of all audio process objects with their current input/output state.
    public static func current() -> [AudioProcessInfo] {
        CA.objectIDs(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.pid(id) else { return nil }
            let path = ProcPath.path(pid) ?? ""
            return AudioProcessInfo(
                objectID: id, pid: pid,
                bundleID: CA.string(id, kAudioProcessPropertyBundleID) ?? "",
                owningAppBundleID: ProcPath.owningAppBundleID(path) ?? "",
                executable: (path as NSString).lastPathComponent,
                isRunningInput: (CA.uint32(id, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                isRunningOutput: (CA.uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
        }
    }

    /// All processes belonging to `app` (bundle prefix on audio bundle ID or owning app), excluding `selfPID` (EM-041).
    public static func resolve(_ app: DetectionRules.App, in processes: [AudioProcessInfo], selfPID: pid_t = getpid()) -> [AudioProcessInfo] {
        processes.filter { p in
            p.pid != selfPID && (app.matches(bundleID: p.bundleID) || (!p.owningAppBundleID.isEmpty && app.matches(bundleID: p.owningAppBundleID)))
        }
    }
}
