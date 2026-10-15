import EMCore
import EMStorage
import EMTranscription
import Foundation

/// `transcribe` job (EM-081/084): mic track → "Me", call track → "Others"; replaces the session's transcript.
/// Session status goes `transcribing` → `ready` (audio stays playable throughout).
public struct TranscribeJobHandler: JobHandler {
    public typealias EngineProvider = @Sendable (_ model: String) -> TranscriptionEngine

    let db: AppDatabase
    let paths: AppPaths
    let settings: @Sendable () -> TranscriptionSettings
    let engine: EngineProvider

    public init(db: AppDatabase, paths: AppPaths, settings: @escaping @Sendable () -> TranscriptionSettings, engine: @escaping EngineProvider) {
        self.db = db; self.paths = paths; self.settings = settings; self.engine = engine
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard let sid = job.sessionID, let session = try SessionRepository(db).fetch(sid) else {
            throw JobFailure.permanent("Session not found")
        }
        let cfg = settings()
        let engine = engine(cfg.model)
        let sessions = SessionRepository(db)
        let previous = session.status
        try sessions.setStatus(sid, .transcribing)

        do {
            // 1. Model (download on first use + one-time Core ML optimisation)
            try await engine.prepare { status in
                switch status {
                case .downloading(let f): progress(0, String(format: "Downloading speech model… %.0f%%", f * 100))
                case .loading: progress(0, "Optimizing speech model for this Mac (first time only)…")
                case .ready: progress(0, "Transcribing…")
                }
            }

            // 2. Tracks: mic (me) then system (others). Weight by audio length.
            let dir = paths.sessionDir(sid)
            var tracks: [(TrackKind, URL)] = []
            for kind in [TrackKind.mic, .system] {
                let url = dir.appendingPathComponent("\(kind.rawValue).m4a")
                if FileManager.default.fileExists(atPath: url.path) { tracks.append((kind, url)) }
            }
            guard !tracks.isEmpty else { throw JobFailure.permanent("No audio tracks found for this recording") }

            let me = Speaker(sessionID: sid, label: "Me", isMe: true)
            let others = Speaker(sessionID: sid, label: "Others")
            let options = STTOptions(language: cfg.language, vocabulary: cfg.vocabulary)
            let transcriber = TrackTranscriber(engine: engine)
            var segments: [TranscriptSegment] = []
            let t0 = Date()
            var audioSeconds = 0.0, speechSeconds = 0.0

            for (i, (kind, url)) in tracks.enumerated() {
                try Task.checkCancellation()
                let label = kind == .mic ? "your voice" : "the call"
                let span = 1.0 / Double(tracks.count)
                let out = try await transcriber.transcribe(url, options: options) { p in
                    progress((Double(i) + p) * span, String(format: "Transcribing %@… %.0f%%", label, ((Double(i) + p) * span) * 100))
                }
                audioSeconds = max(audioSeconds, out.audioSeconds)
                speechSeconds += out.speechSeconds
                let speakerID = kind == .mic ? me.id : others.id
                segments += out.segments.map { s in
                    TranscriptSegment(sessionID: sid, speakerID: speakerID, track: kind,
                                      startMs: Int(s.start * 1000), endMs: Int(s.end * 1000),
                                      text: s.text, confidence: exp(s.avgLogprob))
                }
            }
            segments.sort { ($0.startMs, $0.track.rawValue) < ($1.startMs, $1.track.rawValue) }
            try TranscriptRepository(db).replace(sid, speakers: [me, others], segments: segments)

            var s = try sessions.fetch(sid) ?? session
            s.sttEngine = engine.identifier
            s.status = .ready
            try sessions.update(s)
            let secs = Date().timeIntervalSince(t0)
            Log.info(.stt, String(format: "Transcribed %@: %d segments, %.0f s audio (%.0f s speech) in %.0f s (RTF %.2f)",
                                  sid.description, segments.count, audioSeconds, speechSeconds, secs, audioSeconds > 0 ? secs / audioSeconds : 0))
            progress(1, "Transcript ready")
        } catch {
            try? sessions.setStatus(sid, previous == .transcribing ? .ready : previous)
            if Task.isCancelled || (error as? TranscriptionError) == .cancelled { throw CancellationError() }
            if case TranscriptionError.audioUnreadable(let f)? = error as? TranscriptionError {
                throw JobFailure.permanent("Couldn't read \(f)")
            }
            throw error
        }
    }
}
