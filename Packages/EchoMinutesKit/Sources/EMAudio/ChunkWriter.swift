import Atomics
import AVFoundation
import EMCore
import Foundation

/// Anything that fills a mic ring and a system ring with aligned mono Float32 samples.
public protocol CaptureSource: AnyObject, Sendable {
    var micRing: SPSCRingBuffer { get }
    var systemRing: SPSCRingBuffer { get }
    var includesMic: Bool { get }
    /// Current rate of the samples in the rings (may change mid-session, e.g. Bluetooth 48 k → 16 k).
    var sampleRate: Double { get }
}

extension AggregateCapture: CaptureSource {}

/// Drains a `CaptureSource` every 100 ms on a utility queue and writes crash-safe 30 s AAC chunks per track
/// (Technical Design §7.4–7.5; EM-050…053, EM-057).
///
/// * Output: 48 kHz mono AAC 64 kbps `.m4a` chunks in `<session>/chunks/{mic,system}/NNNNNN.m4a`.
/// * Rate changes are resampled to 48 kHz; samples are clamped to ±1 (built-in mic can exceed 0 dBFS).
/// * Modes: `.candidate` keeps only the last N seconds (pre-roll), `.persisting` writes, `.paused` drops.
public final class ChunkWriter: @unchecked Sendable {
    public enum Mode: Sendable, Equatable { case candidate(preRollSeconds: Double), persisting, paused }
    public enum Event: Sendable, Equatable {
        case chunkClosed(track: TrackKind, index: Int)
        case sampleRateChanged(Double)
        case lowDisk(availableBytes: Int64)
        case diskFullStopped(availableBytes: Int64)
        case error(String)
    }

    public static let outputRate: Double = 48_000

    public let sessionDirectory: URL
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let source: CaptureSource
    private let chunkFrames: Int
    private let warnBytes: Int64
    private let stopBytes: Int64
    // .workItem: every drain gets its own autorelease pool. Without it AVAudioFile objects released at a chunk
    // rotation could stay alive in a never-drained pool → the .m4a is never finalised (unreadable chunk).
    private let queue = DispatchQueue(label: "echominutes.chunkwriter", qos: .utility, autoreleaseFrequency: .workItem)
    // Lock-free mirrors for readers on other threads (meters, bookmarks) — never block on `queue`.
    private let micPeakBits = ManagedAtomic<UInt32>(0)
    private let sysPeakBits = ManagedAtomic<UInt32>(0)
    private let persistedMsAtomic = ManagedAtomic<Int>(0)
    private var timer: DispatchSourceTimer?
    private var mode: Mode
    private var manifest: RecordingManifest
    private var mic: TrackWriter?
    private let sys: TrackWriter
    private var sourceRate: Double = 0
    private var scratchMic = [Float](repeating: 0, count: 48_000)
    private var scratchSys = [Float](repeating: 0, count: 48_000)
    private var micPeak: Float = 0
    private var sysPeak: Float = 0
    private var warnedLowDisk = false
    private var stoppedForDisk = false

    public init(source: CaptureSource, sessionDirectory: URL, startedAt: Date = Date(), mode: Mode,
                chunkSeconds: Double = 30, warnBelowBytes: Int64 = 2_000_000_000, stopBelowBytes: Int64 = 500_000_000,
                devices: String? = nil) throws {
        self.source = source
        self.sessionDirectory = sessionDirectory
        self.mode = mode
        self.chunkFrames = Int(chunkSeconds * Self.outputRate)
        self.warnBytes = warnBelowBytes
        self.stopBytes = stopBelowBytes
        self.manifest = RecordingManifest(startedAt: startedAt, includesMic: source.includesMic)
        manifest.devices = devices
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        sys = try TrackWriter(track: .system, sessionDir: sessionDirectory, chunkFrames: chunkFrames)
        if source.includesMic { mic = try TrackWriter(track: .mic, sessionDir: sessionDirectory, chunkFrames: chunkFrames) }
        try manifest.save(to: sessionDirectory)
    }

    /// Starts the 100 ms drain timer.
    public func start() {
        queue.sync {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in autoreleasepool { self?.pumpLocked() } }
            t.resume()
            timer = t
        }
    }

    public func setMode(_ newMode: Mode) {
        queue.sync {
            pumpLocked()
            let at = currentMs
            switch (mode, newMode) {
            case (.candidate, .persisting): addMarker("start", at)
            case (.persisting, .paused): addMarker("pause", at)
            case (.paused, .persisting): addMarker("resume", at)
            default: break
            }
            mode = newMode
        }
    }

    public var currentMode: Mode { queue.sync { mode } }

    /// Peak level (dBFS, −120…0) of each track over the last drain, decaying ~20 dB/s — for meters (EM-073).
    public struct Levels: Sendable, Equatable { public var micDB: Float; public var systemDB: Float }
    public var levels: Levels {
        func db(_ bits: UInt32) -> Float { let x = Float(bitPattern: bits); return x > 0 ? max(-120, 20 * log10(x)) : -120 }
        return Levels(micDB: db(micPeakBits.load(ordering: .relaxed)), systemDB: db(sysPeakBits.load(ordering: .relaxed)))
    }
    /// Milliseconds of audio persisted so far.
    public var persistedMs: Int { persistedMsAtomic.load(ordering: .relaxed) }

    /// Drains immediately (tests / before mode changes).
    public func pump() { queue.sync { autoreleasepool { pumpLocked() } } }

    /// Final drain, closes open chunks, writes the manifest and returns it.
    @discardableResult
    public func finish() -> RecordingManifest {
        queue.sync {
            timer?.cancel(); timer = nil
            pumpLocked()
            addMarker("stop", currentMs)
            closeChunks()
            saveManifest()
            continuation.finish()
            return manifest
        }
    }

    // MARK: - Queue-confined

    private var currentMs: Int { Int(Double(sys.totalFrames) / Self.outputRate * 1000) }

    private func pumpLocked() {
        drainLocked()
        micPeakBits.store(micPeak.bitPattern, ordering: .relaxed)
        sysPeakBits.store(sysPeak.bitPattern, ordering: .relaxed)
        persistedMsAtomic.store(currentMs, ordering: .relaxed)
    }

    private func drainLocked() {
        micPeak *= 0.8; sysPeak *= 0.8                        // per 100 ms ≈ −2 dB → meters fall smoothly
        guard !stoppedForDisk else { source.systemRing.discardAll(); source.micRing.discardAll(); return }
        let rate = source.sampleRate
        guard rate > 0 else { return }
        if rate != sourceRate {
            if sourceRate != 0 {
                manifest.rateChanges += 1
                addMarker("rateChange", currentMs, "\(Int(sourceRate))→\(Int(rate))")
                continuation.yield(.sampleRateChanged(rate))
            }
            sourceRate = rate
            sys.inputRate = rate; mic?.inputRate = rate
        }
        manifest.overruns = source.systemRing.overruns + source.micRing.overruns

        switch mode {
        case .candidate(let preRoll):
            let keep = Int(preRoll * rate)
            source.systemRing.discardAllButLast(keep)
            if source.includesMic { source.micRing.discardAllButLast(keep) }
        case .paused:
            source.systemRing.discardAll(); source.micRing.discardAll()
        case .persisting:
            while true {
                var n = source.systemRing.availableToRead
                if source.includesMic { n = min(n, source.micRing.availableToRead) }
                n = min(n, scratchSys.count)
                if n == 0 { break }
                do {
                    try scratchSys.withUnsafeMutableBufferPointer { b in
                        _ = source.systemRing.read(into: b.baseAddress!, maxCount: n)
                        for i in 0..<n { sysPeak = max(sysPeak, abs(b[i])) }
                        try sys.append(b.baseAddress!, count: n) { closed in self.chunkClosed(.system, closed) }
                    }
                    if let mic {
                        try scratchMic.withUnsafeMutableBufferPointer { b in
                            _ = source.micRing.read(into: b.baseAddress!, maxCount: n)
                            for i in 0..<n { micPeak = max(micPeak, abs(b[i])) }
                            try mic.append(b.baseAddress!, count: n) { closed in self.chunkClosed(.mic, closed) }
                        }
                    }
                } catch {
                    continuation.yield(.error("\(error)"))
                    Log.error(.audio, "Chunk write failed: \(error)")
                    return
                }
                if stoppedForDisk { return }
            }
        }
    }

    private func chunkClosed(_ track: TrackKind, _ chunk: RecordingManifest.Chunk) {
        if track == .system { manifest.systemChunks.append(chunk) } else { manifest.micChunks.append(chunk) }
        // Self-check: a closed chunk must already be a valid, readable file (it is what crash recovery relies on).
        if (try? AVAudioFile(forReading: sessionDirectory.appendingPathComponent(chunk.file)))?.length ?? 0 <= 0 {
            Log.error(.audio, "Closed chunk is not readable yet: \(chunk.file)")
            continuation.yield(.error("unreadable chunk \(chunk.file)"))
        } else if track == .system {
            Log.info(.audio, "Chunk \(chunk.index) closed (\(currentMs / 1000) s recorded)")
        }
        continuation.yield(.chunkClosed(track: track, index: chunk.index))
        saveManifest()
        if track == .system { checkDisk() }
    }

    private func checkDisk() {
        let free = (try? sessionDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if free < stopBytes {
            stoppedForDisk = true
            addMarker("diskFullStop", currentMs, "\(free)")
            closeChunks(); saveManifest()
            continuation.yield(.diskFullStopped(availableBytes: free))
            Log.error(.audio, "Recording stopped: only \(free) bytes free")
        } else if free < warnBytes, !warnedLowDisk {
            warnedLowDisk = true
            addMarker("lowDisk", currentMs, "\(free)")
            continuation.yield(.lowDisk(availableBytes: free))
        }
    }

    private func closeChunks() {
        if let c = sys.closeChunk() { manifest.systemChunks.append(c) }
        if let m = mic, let c = m.closeChunk() { manifest.micChunks.append(c) }
    }

    private func addMarker(_ type: String, _ atMs: Int, _ detail: String? = nil) {
        manifest.markers.append(.init(type: type, atMs: atMs, detail: detail))
    }

    private func saveManifest() {
        do { try manifest.save(to: sessionDirectory) } catch { Log.error(.audio, "Manifest save failed: \(error)") }
    }
}

/// One track's chunk files: input rate → 48 kHz mono, clamp, AAC encode, rotate every `chunkFrames`.
final class TrackWriter {
    let track: TrackKind
    let dir: URL
    let relativeDir: String
    let chunkFrames: Int
    var inputRate: Double = ChunkWriter.outputRate {
        didSet { if inputRate != oldValue { converter = nil } }
    }
    private(set) var totalFrames = 0
    private var file: AVAudioFile?
    private var chunkIndex = 1
    private var framesInChunk = 0
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ChunkWriter.outputRate, channels: 1, interleaved: false)!

    static var aacSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: ChunkWriter.outputRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ] }

    init(track: TrackKind, sessionDir: URL, chunkFrames: Int) throws {
        self.track = track
        self.chunkFrames = chunkFrames
        relativeDir = "chunks/\(track.rawValue)"
        dir = sessionDir.appendingPathComponent(relativeDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func append(_ samples: UnsafePointer<Float>, count: Int, onClose: (RecordingManifest.Chunk) -> Void) throws {
        guard count > 0 else { return }
        let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(count)) else { return }
        inBuf.frameLength = AVAudioFrameCount(count)
        let dst = inBuf.floatChannelData![0]
        for i in 0..<count { dst[i] = min(1, max(-1, samples[i])) }      // limiter / clamp

        let out: AVAudioPCMBuffer
        if inputRate == ChunkWriter.outputRate {
            out = inBuf
        } else {
            if converter == nil { converter = AVAudioConverter(from: inFmt, to: outFormat) }
            guard let converter else { throw EMError.invalidData("no converter \(inputRate)→48000") }
            let capacity = AVAudioFrameCount(Double(count) * ChunkWriter.outputRate / inputRate + 1024)
            guard let o = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var err: NSError?
            _ = converter.convert(to: o, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            out = o
        }
        try write(out, onClose: onClose)
    }

    private func write(_ buf: AVAudioPCMBuffer, onClose: (RecordingManifest.Chunk) -> Void) throws {
        let total = Int(buf.frameLength)
        var offset = 0
        let src = buf.floatChannelData![0]
        while offset < total {
            if file == nil { try openChunk() }
            let n = min(chunkFrames - framesInChunk, total - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
            slice.frameLength = AVAudioFrameCount(n)
            slice.floatChannelData![0].update(from: src + offset, count: n)
            try file!.write(from: slice)
            framesInChunk += n; totalFrames += n; offset += n
            if framesInChunk >= chunkFrames, let c = closeChunk() { onClose(c) }
        }
    }

    private func openChunk() throws {
        let name = String(format: "%06d.m4a", chunkIndex)
        file = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: Self.aacSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Closes the open chunk (AVAudioFile finalises the .m4a on release). Returns its manifest entry.
    func closeChunk() -> RecordingManifest.Chunk? {
        guard file != nil else { return nil }
        autoreleasepool { file = nil }          // AVAudioFile writes the moov atom when it deallocates
        let chunk = RecordingManifest.Chunk(index: chunkIndex, file: "\(relativeDir)/\(String(format: "%06d.m4a", chunkIndex))", frames: framesInChunk)
        chunkIndex += 1; framesInChunk = 0
        return chunk
    }
}
