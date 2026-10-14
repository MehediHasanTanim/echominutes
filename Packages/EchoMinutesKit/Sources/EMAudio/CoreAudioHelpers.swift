import CoreAudio
import Foundation

/// Thin Core Audio property helpers (ported from SpikeLab, EM-003…006).
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var addr = address(selector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return id
    }

    static func nominalRate(_ dev: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v)
        return v
    }

    static func streamChannels(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    static func describe(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
        return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? "\(status) '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : "\(status)"
    }
}

/// Executable path / owning .app helpers (helpers live inside their parent app bundle).
enum ProcPath {
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// Bundle ID of the outermost `.app` containing the executable.
    static func owningAppBundleID(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<r.lowerBound]) + ".app")?.bundleIdentifier
    }
}
