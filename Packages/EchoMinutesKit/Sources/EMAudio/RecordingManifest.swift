import EMCore
import Foundation

/// `manifest.json` inside a session folder (Technical Design §7.5 / §11.1). Rewritten atomically after every
/// chunk rotation, so a crash leaves a manifest that lists every *closed* chunk (EM-052, EM-056).
public struct RecordingManifest: Codable, Sendable, Equatable {
    public struct Chunk: Codable, Sendable, Equatable {
        public var index: Int
        public var file: String          // relative to the session folder, e.g. "chunks/mic/000001.m4a"
        public var frames: Int           // at `sampleRate`
    }
    public struct Marker: Codable, Sendable, Equatable {
        public var type: String          // start | pause | resume | rateChange | lowDisk | diskFullStop | stop
        public var atMs: Int
        public var detail: String?
    }

    /// What the finalizer measured and applied when building mixed.m4a.
    public struct MixInfo: Codable, Sendable, Equatable {
        public var systemLevelDB: Float?
        public var micLevelDB: Float?
        public var systemGainDB: Float
        public var micGainDB: Float
        public var micActiveSeconds: Double?
    }

    public var version = 1
    public var sampleRate: Double = ChunkWriter.outputRate
    public var startedAt: Date
    public var includesMic: Bool
    public var micChunks: [Chunk] = []
    public var systemChunks: [Chunk] = []
    public var markers: [Marker] = []
    public var overruns = 0
    public var rateChanges = 0
    public var finalized = false
    /// Capture devices, e.g. "out: MacBook Pro Speakers @ 48000 Hz, mic: AirPods Pro @ 24000 Hz" (optional: older manifests lack it).
    public var devices: String?
    public var mix: MixInfo?

    public init(startedAt: Date, includesMic: Bool) {
        // Whole seconds: the ISO-8601 JSON encoding has no sub-second part, so a reloaded manifest compares equal.
        self.startedAt = Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded(.down))
        self.includesMic = includesMic
    }

    public var totalFrames: Int { systemChunks.reduce(0) { $0 + $1.frames } }
    public var durationMs: Int { Int(Double(totalFrames) / sampleRate * 1000) }

    public static func url(in sessionDir: URL) -> URL { sessionDir.appendingPathComponent("manifest.json") }

    public static func load(from sessionDir: URL) throws -> RecordingManifest {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(RecordingManifest.self, from: Data(contentsOf: url(in: sessionDir)))
    }

    public func save(to sessionDir: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(in: sessionDir), options: .atomic)
    }
}
