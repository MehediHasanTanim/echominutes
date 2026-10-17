import Atomics
import AVFoundation
import EMCore
import Foundation

/// A copy of the recorded audio for the live transcript (EM-141).
///
/// The chunk writer pushes each track into a lock-free ring on its drain queue — no allocation, no locks, and
/// when the transcriber falls behind the newest audio is simply dropped (the recording never waits).
/// A single consumer drains the rings as 16 kHz mono, the format the speech model wants.
public final class LiveAudioTap: @unchecked Sendable {
    public static let outputRate: Double = 16_000

    let systemRing: SPSCRingBuffer
    let micRing: SPSCRingBuffer?
    private let rate = ManagedAtomic<Int>(48_000)
    // Consumer-only state (one draining task).
    private var converters: [TrackKind: (rate: Int, converter: AVAudioConverter)] = [:]

    /// - Parameter bufferSeconds: how much audio may wait for the consumer before it is dropped.
    public init(includesMic: Bool, bufferSeconds: Double = 40, maxInputRate: Double = 48_000) {
        let capacity = Int(maxInputRate * bufferSeconds)
        systemRing = SPSCRingBuffer(minimumCapacity: capacity)
        micRing = includesMic ? SPSCRingBuffer(minimumCapacity: capacity) : nil
    }

    public var includesMic: Bool { micRing != nil }
    public var tracks: [TrackKind] { includesMic ? [.mic, .system] : [.system] }
    /// Samples dropped because the consumer was too slow (or not started yet).
    public var dropped: Int { systemRing.overruns + (micRing?.overruns ?? 0) }

    // MARK: Producer (chunk writer queue)

    func push(_ track: TrackKind, _ samples: UnsafePointer<Float>, count: Int, rate inputRate: Double) {
        rate.store(Int(inputRate), ordering: .relaxed)
        _ = (track == .mic ? micRing : systemRing)?.write(samples, count: count)
    }

    /// Test hook: push from an array.
    public func push(_ track: TrackKind, _ samples: [Float], rate inputRate: Double) {
        samples.withUnsafeBufferPointer { push(track, $0.baseAddress!, count: $0.count, rate: inputRate) }
    }

    // MARK: Consumer

    /// Everything waiting for `track`, resampled to 16 kHz mono. Call from one task only.
    public func drain16k(_ track: TrackKind) -> [Float] {
        guard let ring = track == .mic ? micRing : systemRing else { return [] }
        let n = ring.availableToRead
        guard n > 0 else { return [] }
        let input = ring.read(maxCount: n)
        let inputRate = rate.load(ordering: .relaxed)
        return inputRate == Int(Self.outputRate) ? input : resample(input, track: track, from: inputRate)
    }

    private func resample(_ input: [Float], track: TrackKind, from inputRate: Int) -> [Float] {
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(inputRate), channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false)
        else { return [] }
        if converters[track]?.rate != inputRate {
            guard let c = AVAudioConverter(from: inFmt, to: outFmt) else { return [] }
            converters[track] = (inputRate, c)
        }
        guard let converter = converters[track]?.converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(input.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }
        let capacity = AVAudioFrameCount(Double(input.count) * Self.outputRate / Double(inputRate)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else { return [] }
        var supplied = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return inBuf
        }
        if err != nil { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
