import Foundation
import Security

enum InfoCommand {
    static func run(_ args: [String]) async -> Int32 {
        let b = Bundle.main
        var failed = false
        Log.line("Bundle ID:   \(b.bundleIdentifier ?? "nil (not running as .app!)")")
        Log.line("Version:     \(b.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(b.infoDictionary?["CFBundleVersion"] ?? "?"))")
        Log.line("Executable:  \(b.executablePath ?? "?")")
        Log.line("macOS:       \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Log.line("PID:         \(getpid())")

        if b.bundleIdentifier == nil { Log.error("Not launched as an app bundle — use run.sh"); failed = true }

        for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"] {
            if let v = b.infoDictionary?[key] as? String, !v.isEmpty { Log.ok("\(key) present") }
            else { Log.error("\(key) missing from Info.plist"); failed = true }
        }

        // Code signing details of the running process
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            Log.error("SecCodeCopySelf failed"); return 1
        }
        var staticCode: SecStaticCode?
        SecCodeCopyStaticCode(code, [], &staticCode)
        var info: CFDictionary?
        if let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
           let dict = info as? [String: Any] {
            let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
            let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            Log.line("Team ID:     \(team ?? "none (ad-hoc?)")")
            if team == nil { Log.warn("No team ID — permissions will not persist across rebuilds"); failed = true }
            if flags & 0x10000 != 0 { Log.ok("Hardened Runtime enabled") } else { Log.error("Hardened Runtime NOT enabled"); failed = true }
            if ents["com.apple.security.device.audio-input"] as? Bool == true { Log.ok("Entitlement com.apple.security.device.audio-input") }
            else { Log.error("Missing entitlement com.apple.security.device.audio-input"); failed = true }
            if ents["com.apple.security.app-sandbox"] as? Bool == true { Log.warn("App Sandbox is ON (spike expects it OFF)") }
        } else {
            Log.error("Could not read signing information"); failed = true
        }
        return failed ? 1 : 0
    }
}
