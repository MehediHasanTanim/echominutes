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
    let diarizer: SpeakerDiarizer?

    public init(db: AppDatabase, paths: AppPaths, settings: @escaping @Sendable () -> TranscriptionSettings,
                engine: @escaping EngineProvider, diarizer: SpeakerDiarizer? = nil) {
        self.db = db; self.paths = paths; self.settings = settings; self.engine = engine; self.diarizer = diarizer
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

            // Keep names the user gave speakers on a previous run (re-transcribe).
            let previousNames = Dictionary(((try? TranscriptRepository(db).speakers(sid)) ?? []).compactMap { sp in
                sp.displayName.map { (sp.label, $0) } }, uniquingKeysWith: { a, _ in a })
            func speaker(_ label: String, isMe: Bool = false) -> Speaker {
                let fallback = isMe && !cfg.myName.trimmingCharacters(in: .whitespaces).isEmpty ? cfg.myName : nil
                return Speaker(sessionID: sid, label: label, displayName: previousNames[label] ?? fallback, isMe: isMe)
            }
            let me = speaker("Me", isMe: true)
            let others = speaker("Others")
            let options = STTOptions(language: cfg.language, vocabulary: cfg.vocabulary)
            let transcriber = TrackTranscriber(engine: engine)
            let diarize = cfg.identifySpeakers && diarizer != nil && tracks.contains { $0.0 == .system }
            let sttShare = diarize ? 0.85 : 1.0
            var segments: [TranscriptSegment] = []
            var systemSamples: [Float] = []
            let t0 = Date()
            var audioSeconds = 0.0, speechSeconds = 0.0

            for (i, (kind, url)) in tracks.enumerated() {
                try Task.checkCancellation()
                let label = kind == .mic ? "your voice" : "the call"
                let span = sttShare / Double(tracks.count)
                let samples = try AudioLoader.load16kMono(url)
                if kind == .system { systemSamples = samples }
                let out = try await transcriber.transcribe(samples: samples, options: options) { p in
                    let f = (Double(i) + p) * span
                    progress(f, String(format: "Transcribing %@… %.0f%%", label, f * 100))
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
            var echoRemoved = 0
            if RecordingPreferences.echoDedup {   // Settings ▸ Recording
                let deduped = EchoDeduplicator.dedupe(segments)
                if !deduped.removed.isEmpty {
                    Log.info(.stt, "Echo: removed \(deduped.removed.count) mic segment(s) that repeated the call audio")
                }
                segments = deduped.segments
                echoRemoved = deduped.removed.count
            }

            // 3. Who is who on the call (Speaker 1…N); falls back to a single "Others".
            var speakers = [me]
            var needOthers = segments.contains { $0.track == .system }
            if diarize, let diarizer, needOthers {
                try Task.checkCancellation()
                progress(sttShare, "Identifying speakers…")
                do {
                    let turns = try await diarizer.diarize(samples: systemSamples) { p in
                        progress(sttShare + p * (1 - sttShare), String(format: "Identifying speakers… %.0f%%", p * 100))
                    }
                    let sysIdx = segments.indices.filter { segments[$0].track == .system }
                    if let a = SpeakerAssigner.assign(sysIdx.map { segments[$0] }, turns: turns) {
                        let numbered = (1...a.speakerCount).map { speaker("Speaker \($0)") }
                        speakers += numbered
                        needOthers = false
                        for (k, idx) in sysIdx.enumerated() {
                            if let n = a.speakerOfSegment[k] { segments[idx].speakerID = numbered[n - 1].id }
                            else { needOthers = true }
                        }
                        Log.info(.stt, "Speakers on the call: \(a.speakerCount)")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.error(.stt, "Speaker identification failed, keeping \"Others\": \(error)")
                }
            }
            if needOthers { speakers.append(others) }
            try TranscriptRepository(db).replace(sid, speakers: speakers, segments: segments)

            var s = try sessions.fetch(sid) ?? session
            if echoRemoved > 0 { s.echoRisk = true }
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
