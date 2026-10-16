import CoreAudio
import Foundation

/// Where the call audio is being played (EM-092). Built-in speakers mean the mic hears the other side → the
/// session is flagged `echoRisk` and the transcript echo filter matters. Headphones / AirPods / headsets don't.
public struct OutputRoute: Sendable, Equatable {
    public var deviceName: String
    public var transportType: UInt32
    /// `kAudioDevicePropertyDataSource` FourCC on the output scope ("ispk" speakers, "hdpn" headphones), if any.
    public var dataSource: UInt32?

    public static let fourCCSpeakers: UInt32 = 0x6973_706B      // 'ispk'
    public static let fourCCHeadphones: UInt32 = 0x6864_706E    // 'hdpn'

    public init(deviceName: String, transportType: UInt32, dataSource: UInt32?) {
        self.deviceName = deviceName; self.transportType = transportType; self.dataSource = dataSource
    }

    /// Built-in output playing through the internal speakers (not the headphone jack).
    public var isBuiltInSpeakers: Bool {
        guard transportType == kAudioDeviceTransportTypeBuiltIn else {
            // External displays / AirPlay speakers also echo, but are rare for calls; USB/Bluetooth headsets don't.
            return transportType == kAudioDeviceTransportTypeDisplayPort || transportType == kAudioDeviceTransportTypeHDMI
        }
        if let ds = dataSource { return ds != Self.fourCCHeadphones }
        return !deviceName.localizedCaseInsensitiveContains("headphone")
    }

    public var summary: String { "\(deviceName)\(isBuiltInSpeakers ? " (speakers — echo likely)" : "")" }

    public static func current() -> OutputRoute {
        let dev = CA.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let name = CA.string(dev, kAudioObjectPropertyName) ?? "Unknown output"
        let transport = CA.uint32(dev, kAudioDevicePropertyTransportType) ?? 0
        let ds = CA.uint32(dev, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        return OutputRoute(deviceName: name, transportType: transport, dataSource: ds)
    }
}
