import CoreAudio
import Foundation

/// Smoke test for the Core Audio process-tap API (macOS 14.2+).
/// Creates a private global tap (all processes) and destroys it immediately — no audio is read.
/// The "System Audio Recording" permission prompt may only appear once audio IO actually starts (EM-005).
enum TapProbeCommand {
    static func run(_ args: [String]) async -> Int32 {
        guard #available(macOS 14.2, *) else {
            Log.error("Process taps need macOS 14.2+"); return 1
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "SpikeLab tap probe"
        desc.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            Log.error("AudioHardwareCreateProcessTap failed: \(describeStatus(status))")
            return 1
        }
        Log.ok("Created process tap id=\(tapID) uuid=\(desc.uuid.uuidString)")

        // Read back the tap's stream format to prove the object is live.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let fmtStatus = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        if fmtStatus == noErr {
            Log.ok("Tap format: \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel)-bit")
        } else {
            Log.warn("Could not read tap format: \(describeStatus(fmtStatus))")
        }

        let destroy = AudioHardwareDestroyProcessTap(tapID)
        destroy == noErr ? Log.ok("Destroyed tap") : Log.warn("Destroy failed: \(describeStatus(destroy))")
        return 0
    }
}
