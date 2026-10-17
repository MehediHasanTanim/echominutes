import EMCore
import Foundation

/// Near-real-time transcript while recording (EM-142, Technical Design §9.5).
///
/// Audio arrives per track as 16 kHz mono (`append`). Each `step()` transcribes one track's audio since its
/// last commit point with a small local model, and `LiveWindow` decides what is final. Silence is skipped
/// cheaply (energy VAD) and the hallucination guard runs on every pass. Results are only for display: the
/// stored transcript always comes from the full-quality pass after the call.
public actor LiveTranscriber {
    public struct Line: Sendable, Equatable, Identifiable, Codable {
        public var id: Int
        public var track: TrackKind
        /// Seconds from the start of the recording (pauses excluded, like the saved audio).
        public var start: Double
        public var end: Double
        public var text: String
    }

    public struct Snapshot: Sendable, Equatable {
        public var lines: [Line] = []
        public var tentative: [TrackKind: String] = [:]
        /// Compute time of the last pass, and the average over all passes (seconds).
        public var lastPassSeconds: Double?
        public var averagePassSeconds: Double?
        public var passes = 0
        public init() {}
    }

    struct TrackState {
        var buffer: [Float] = []
        var bufferStart: Double = 0          // seconds on the recording timeline
        var newSamples = 0
        var lastPass = Date.distantPast
        var window = LiveWindow()
        var tentative: [RawSegment] = []
        var generation = 0                    // bumped when audio is skipped, invalidates a pass in flight
    }

    public static let rate = 16_000.0
    /// Run a pass once a track has this much new audio.
    public var minNewSeconds = 1.5

    private let engine: TranscriptionEngine
    private let options: STTOptions
    private let onCommit: (@Sendable (Line) -> Void)?
    private var tracks: [TrackKind: TrackState]
    private var snapshot = Snapshot()
    private var nextID = 0
    private var totalPassSeconds = 0.0

    public init(engine: TranscriptionEngine, options: STTOptions, tracks: [TrackKind],
                onCommit: (@Sendable (Line) -> Void)? = nil) {
        self.engine = engine; self.options = options; self.onCommit = onCommit
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0, TrackState()) })
    }

    public var current: Snapshot { snapshot }

    public func setMinNewSeconds(_ s: Double) { minNewSeconds = s }

    /// New 16 kHz audio for `track`.
    public func append(_ samples: [Float], track: TrackKind) {
        guard !samples.isEmpty, var t = tracks[track] else { return }
        t.buffer += samples
        t.newSamples += samples.count
        // Never let the buffer outgrow what one pass can handle (e.g. while the model loads).
        let cap = Int(LiveWindow.hardCapSeconds * Self.rate)
        if t.buffer.count > cap {
            let drop = t.buffer.count - cap
            t.buffer.removeFirst(drop)
            t.bufferStart += Double(drop) / Self.rate
            t.window.reset(); t.tentative = []
        }
        tracks[track] = t
    }

    /// Drops all waiting audio without transcribing it (power saving). The timeline keeps advancing.
    public func skipPending() {
        for (k, var t) in tracks {
            t.bufferStart += Double(t.buffer.count) / Self.rate
            t.buffer = []; t.newSamples = 0
            t.window.reset(); t.tentative = []
            t.generation += 1
            tracks[k] = t
            snapshot.tentative[k] = nil
        }
    }

    /// Runs one pass on the track that waited longest with enough new audio. Returns false when idle.
    @discardableResult
    public func step() async throws -> Bool {
        let minNew = Int(minNewSeconds * Self.rate)
        guard let kind = tracks.filter({ $0.value.newSamples >= minNew })
                .min(by: { $0.value.lastPass < $1.value.lastPass })?.key,
              var t = tracks[kind] else { return false }
        t.newSamples = 0
        t.lastPass = Date()
        let samples = t.buffer
        let bufferSeconds = Double(samples.count) / Self.rate
        let generation = t.generation

        // Silence: nothing to transcribe. Keep the last second as context for the next words.
        if SpeechRegionDetector.detect(samples, rate: Self.rate).isEmpty {
            let keep = Int(Self.rate)
            if t.buffer.count > keep {
                let drop = t.buffer.count - keep
                t.buffer.removeFirst(drop)
                t.bufferStart += Double(drop) / Self.rate
            }
            t.window.reset(); t.tentative = []
            tracks[kind] = t
            snapshot.tentative[kind] = nil
            return true
        }
        tracks[kind] = t

        let t0 = Date()
        let raw = try await engine.transcribe(samples: samples, options: options) { _ in }
        let elapsed = Date().timeIntervalSince(t0)
        let segments = HallucinationGuard.filter(raw).kept.map { s -> RawSegment in
            var x = s; x.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            x.end = min(max(x.end, x.start), bufferSeconds)
            return x
        }

        // Audio may have been appended (or skipped) while the model ran.
        guard var cur = tracks[kind], cur.generation == generation else { return true }
        let r = cur.window.ingest(segments, bufferSeconds: bufferSeconds)
        for s in r.committed { commit(kind, start: cur.bufferStart + s.start, end: cur.bufferStart + s.end, text: s.text) }
        let drop = min(cur.buffer.count, Int(r.advance * Self.rate))
        cur.buffer.removeFirst(drop)
        cur.bufferStart += Double(drop) / Self.rate
        cur.tentative = r.tentative.map { $0.shifted(by: -Double(drop) / Self.rate) }
        tracks[kind] = cur

        let tentativeText = r.tentative.map(\.text).joined(separator: " ")
        snapshot.tentative[kind] = tentativeText.isEmpty ? nil : tentativeText
        snapshot.passes += 1
        totalPassSeconds += elapsed
        snapshot.lastPassSeconds = elapsed
        snapshot.averagePassSeconds = totalPassSeconds / Double(snapshot.passes)
        if snapshot.passes == 1 || snapshot.passes % 50 == 0 {
            Log.info(.stt, String(format: "Live pass #%d (%@, %.1f s audio) took %.2f s; average %.2f s",
                                  snapshot.passes, kind.rawValue, bufferSeconds, elapsed, snapshot.averagePassSeconds ?? 0))
        }
        return true
    }

    /// Recording stopped: keep what was still tentative so the draft has the last words too.
    public func flush() {
        for (k, var t) in tracks {
            for s in t.tentative { commit(k, start: t.bufferStart + s.start, end: t.bufferStart + s.end, text: s.text) }
            t.tentative = []
            tracks[k] = t
            snapshot.tentative[k] = nil
        }
    }

    private func commit(_ track: TrackKind, start: Double, end: Double, text: String) {
        guard !text.isEmpty else { return }
        let line = Line(id: nextID, track: track, start: start, end: max(end, start), text: text)
        nextID += 1
        snapshot.lines.append(line)
        onCommit?(line)
    }
}

/// Appends committed live lines to `live.jsonl` in the session folder (EM-145), so a crash keeps the draft.
public final class LiveTranscriptLog: @unchecked Sendable {
    public static let fileName = "live.jsonl"
    private let lock = NSLock()
    private let handle: FileHandle?

    public init(sessionDirectory: URL) {
        let url = sessionDirectory.appendingPathComponent(Self.fileName)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    public func append(_ line: LiveTranscriber.Line) {
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0A)
        lock.withLock { try? handle?.write(contentsOf: data) }
    }

    /// Lines saved for a session (oldest first), or empty.
    public static func read(sessionDirectory: URL) -> [LiveTranscriber.Line] {
        guard let text = try? String(contentsOf: sessionDirectory.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(LiveTranscriber.Line.self, from: Data($0.utf8)) }
            .sorted { $0.start < $1.start }
    }

    public static func delete(sessionDirectory: URL) {
        try? FileManager.default.removeItem(at: sessionDirectory.appendingPathComponent(fileName))
    }
}
