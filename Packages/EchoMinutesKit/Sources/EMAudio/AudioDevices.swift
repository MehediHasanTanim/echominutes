import CoreAudio
import Foundation

/// Input devices for Settings ▸ Recording.
public enum AudioDevices {
    public struct Input: Identifiable, Hashable, Sendable {
        public let uid: String
        public let name: String
        public var id: String { uid }
    }

    /// Every device with input channels, excluding our own private aggregates.
    public static func inputs() -> [Input] {
        CA.objectIDs(CA.system, kAudioHardwarePropertyDevices).compactMap { dev in
            guard CA.streamChannels(dev, scope: kAudioObjectPropertyScopeInput).reduce(0, +) > 0,
                  let uid = CA.string(dev, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("echominutes-") else { return nil }
            return Input(uid: uid, name: CA.string(dev, kAudioObjectPropertyName) ?? uid)
        }
    }

    /// The device with this UID, if it is connected and has input channels.
    static func inputDevice(uid: String) -> AudioObjectID? {
        CA.objectIDs(CA.system, kAudioHardwarePropertyDevices).first { dev in
            CA.string(dev, kAudioDevicePropertyDeviceUID) == uid
                && CA.streamChannels(dev, scope: kAudioObjectPropertyScopeInput).reduce(0, +) > 0
        }
    }
}
