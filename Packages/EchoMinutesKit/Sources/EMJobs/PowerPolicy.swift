import Foundation
import IOKit.ps

/// Battery / Low Power Mode check for heavy local work (EM-088).
public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var lowPowerMode: Bool

    public init(onBattery: Bool, batteryPercent: Int?, lowPowerMode: Bool) {
        self.onBattery = onBattery; self.batteryPercent = batteryPercent; self.lowPowerMode = lowPowerMode
    }

    /// Defer transcription on battery below 20 % or in Low Power Mode.
    public var shouldDeferHeavyWork: Bool { lowPowerMode || (onBattery && (batteryPercent ?? 100) < 20) }

    public var reason: String? {
        if lowPowerMode { return "Low Power Mode is on" }
        if onBattery, let p = batteryPercent, p < 20 { return "battery at \(p) %" }
        return nil
    }

    public static func current() -> PowerState {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: low)
        }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = cur * 100 / max
                }
            }
        }
        return PowerState(onBattery: type == kIOPSBatteryPowerValue, batteryPercent: percent, lowPowerMode: low)
    }
}
