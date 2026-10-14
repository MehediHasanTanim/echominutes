import EMCore
import Foundation

/// Owns the active capture and turns ring-buffer contents into level meters (EM-046 / EM-047).
/// Persisting to disk (chunk writer) arrives in EM-050; until then drained audio is discarded.
public actor RecordingService {
    public struct Levels: Sendable, Equatable {
        public var micDB: Float
        public var systemDB: Float
        public var sampleRate: Double
        public var elapsed: TimeInterval
        public var micSilentFor: TimeInterval      // seconds below -60 dBFS
        public var systemSilentFor: TimeInterval
        public var overruns: Int
        public var callbacks: Int
        public static let silenceThresholdDB: Float = -60
        public static let silenceWarningAfter: TimeInterval = 60
        public var micSilenceWarning: Bool { micSilentFor >= Self.silenceWarningAfter }
        public var systemSilenceWarning: Bool { systemSilentFor >= Self.silenceWarningAfter }
    }

    public struct Session: Sendable {
        public let app: DetectionRules.App
        public let processes: [AudioProcessInfo]
        public let deviceSummary: String
        public let startedAt: Date
    }

    public nonisolated let levels: AsyncStream<Levels>
    private let continuation: AsyncStream<Levels>.Continuation
    private var capture: AggregateCapture?
    private var drainTask: Task<Void, Never>?
    private var current: Session?
    private var scratch = [Float](repeating: 0, count: 96_000)
    private var micSilent: TimeInterval = 0
    private var sysSilent: TimeInterval = 0

    public init() {
        (levels, continuation) = AsyncStream.makeStream(of: Levels.self, bufferingPolicy: .bufferingNewest(1))
    }

    public var isRunning: Bool { capture != nil }
    public var session: Session? { current }

    /// Starts capturing `app` (all its audio processes) plus the default microphone.
    @discardableResult
    public func start(app: DetectionRules.App, includeMic: Bool = true) throws -> Session {
        stop()
        let procs = AudioProcesses.resolve(app, in: AudioProcesses.current())
        guard !procs.isEmpty else { throw AudioCaptureError.noTargetProcesses(app.name) }
        let cap = AggregateCapture(processObjectIDs: procs.map(\.objectID), includeMic: includeMic)
        try cap.start()
        capture = cap
        micSilent = 0; sysSilent = 0
        let s = Session(app: app, processes: procs, deviceSummary: cap.deviceSummary, startedAt: Date())
        current = s
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.drain()
            }
        }
        Log.info(.audio, "Recording service started for \(app.name): \(procs.map { "\($0.executable)(\($0.pid))" }.joined(separator: ", "))")
        return s
    }

    public func stop() {
        drainTask?.cancel(); drainTask = nil
        capture?.stop(); capture = nil
        current = nil
    }

    private func drain() {
        guard let cap = capture, let started = current?.startedAt else { return }
        let rate = max(cap.sampleRate, 1)
        let (micPeak, micN) = drainPeak(cap.micRing)
        let (sysPeak, sysN) = drainPeak(cap.systemRing)
        let dt = Double(max(micN, sysN)) / rate
        let micDB = Self.dB(micPeak), sysDB = Self.dB(sysPeak)
        micSilent = (cap.includesMic && micDB < Levels.silenceThresholdDB) ? micSilent + dt : 0
        sysSilent = sysDB < Levels.silenceThresholdDB ? sysSilent + dt : 0
        continuation.yield(Levels(micDB: micDB, systemDB: sysDB, sampleRate: rate, elapsed: Date().timeIntervalSince(started),
                                  micSilentFor: micSilent, systemSilentFor: sysSilent,
                                  overruns: cap.micRing.overruns + cap.systemRing.overruns, callbacks: cap.callbacks))
    }

    private func drainPeak(_ ring: SPSCRingBuffer) -> (Float, Int) {
        var peak: Float = 0, total = 0
        scratch.withUnsafeMutableBufferPointer { buf in
            while true {
                let n = ring.read(into: buf.baseAddress!, maxCount: buf.count)
                if n == 0 { break }
                total += n
                for i in 0..<n { peak = max(peak, abs(buf[i])) }
            }
        }
        return (peak, total)
    }

    static func dB(_ x: Float) -> Float { x > 0 ? max(20 * log10(x), -120) : -120 }
}
