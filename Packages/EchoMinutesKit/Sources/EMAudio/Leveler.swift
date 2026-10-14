import Foundation

/// Speech-level measurement and gain for the mixed track (EM-054 follow-up).
///
/// The raw mic is captured without the meeting app's AGC, so the local voice is typically 15–25 dB quieter than
/// the remote voices (which the meeting app already normalises). Each track's speech level is measured
/// (percentile of 50 ms RMS windows above a silence gate) and gained to a common target before mixing;
/// a soft limiter catches overlaps.
public struct LevelMeter: Sendable {
    public static let windowSeconds = 0.05
    public static let gateDB: Float = -55          // windows quieter than this are silence / noise floor
    public static let percentile: Float = 0.85     // "loud speech" level, robust to pauses and a few spikes

    private let window: Int
    private var sumSquares: Double = 0
    private var fill = 0
    public private(set) var windowsDB: [Float] = []

    public init(sampleRate: Double) { window = max(1, Int(sampleRate * Self.windowSeconds)) }

    public mutating func add(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            let v = Double(samples[i])
            sumSquares += v * v
            fill += 1
            if fill == window {
                let rms = (sumSquares / Double(window)).squareRoot()
                windowsDB.append(rms > 0 ? Float(20 * log10(rms)) : -120)
                sumSquares = 0; fill = 0
            }
        }
    }

    /// Seconds of audio above the gate.
    public var activeSeconds: Double { Double(windowsDB.filter { $0 > Self.gateDB }.count) * Self.windowSeconds }

    /// Speech level in dBFS, or nil if there is too little speech (< 2 s) to judge.
    public var speechLevelDB: Float? {
        let active = windowsDB.filter { $0 > Self.gateDB }.sorted()
        guard Double(active.count) * Self.windowSeconds >= 2 else { return nil }
        let idx = min(active.count - 1, Int(Float(active.count - 1) * Self.percentile))
        return active[idx]
    }
}

public enum Leveler {
    public static let targetDB: Float = -18
    /// Never cut a track by more than this, never boost by more than the per-track maximum.
    public static let minGainDB: Float = -6

    /// Gain in dB that brings `level` to the target, clamped. 0 dB when the level is unknown.
    public static func gainDB(level: Float?, maxBoostDB: Float) -> Float {
        guard let level else { return 0 }
        return min(maxBoostDB, max(minGainDB, targetDB - level))
    }

    public static func linear(_ db: Float) -> Float { powf(10, db / 20) }

    /// Transparent below 0.89 (−1 dBFS), smoothly saturating to ±1 above it.
    @inline(__always)
    public static func softLimit(_ x: Float) -> Float {
        let t: Float = 0.89, a = abs(x)
        guard a > t else { return x }
        let y = t + (1 - t) * tanhf((a - t) / (1 - t))
        return x < 0 ? -y : y
    }
}
