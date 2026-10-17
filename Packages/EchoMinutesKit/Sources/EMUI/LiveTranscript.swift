import EMAudio
import EMCore
import EMJobs
import EMTranscription
import Foundation
import Observation

public enum LiveTranscriptStatus: Equatable, Sendable {
    case off
    case preparing(String)
    case running
    case paused(String)
    case failed(String)
}

enum LiveTranscriptUpdate: Sendable {
    case status(LiveTranscriptStatus)
    case snapshot(LiveTranscriber.Snapshot)
}

/// Runs the live transcript while a recording is active (EM-141…146) and publishes it for the mini-widget.
///
/// The work loop runs off the main thread: drain the recording's `LiveAudioTap` → `LiveTranscriber.step()`
/// → publish a snapshot. It pauses on Low Power Mode / low battery / a hot Mac, and the small model is
/// unloaded when the recording ends.
@MainActor
@Observable
public final class LiveTranscript {
    public typealias Status = LiveTranscriptStatus

    public private(set) var status: Status = .off
    /// Committed lines (echo of the call on your mic removed when that setting is on).
    public private(set) var lines: [LiveTranscriber.Line] = []
    public private(set) var tentative: [TrackKind: String] = [:]
    public private(set) var averagePassSeconds: Double?
    /// Bumped on every update (for auto-scroll).
    public private(set) var revision = 0

    @ObservationIgnored private(set) var sessionID: SessionID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var echoRemoved = Set<Int>()
    @ObservationIgnored private var allLines: [LiveTranscriber.Line] = []

    public init() {}

    public var isActive: Bool { sessionID != nil }

    /// Starts for `sessionID` unless already running for it.
    func start(sessionID: SessionID, tap: LiveAudioTap, modelsDir: URL, sessionDirectory: URL) {
        guard self.sessionID != sessionID else { return }
        stop()
        self.sessionID = sessionID
        lines = []; allLines = []; tentative = [:]; echoRemoved = []; averagePassSeconds = nil
        status = .preparing("Loading live model…")
        revision += 1

        let cfg = TranscriptionPreferences.current
        let options = STTOptions(language: cfg.language, vocabulary: cfg.vocabulary)
        let engine = WhisperKitEngine(variant: LivePreferences.model, models: STTModelManager(modelsDir: modelsDir))
        let log = LiveTranscriptLog(sessionDirectory: sessionDirectory)
        let transcriber = LiveTranscriber(engine: engine, options: options, tracks: tap.tracks) { log.append($0) }
        Log.info(.stt, "Live transcript: starting with \(LivePreferences.model) for \(sessionID)")

        let publish: @Sendable (Update) async -> Void = { [weak self] update in
            await self?.apply(update, for: sessionID)
        }
        task = Task.detached(priority: .utility) {
            await Self.run(tap: tap, engine: engine, transcriber: transcriber, publish: publish)
        }
    }

    /// Recording ended: the loop flushes the tentative tail into the draft and unloads the model.
    func stop() {
        guard sessionID != nil else { return }
        task?.cancel(); task = nil
        sessionID = nil
        status = .off
    }

    // MARK: - Work loop (off main)

    typealias Update = LiveTranscriptUpdate

    private nonisolated static func run(tap: LiveAudioTap, engine: WhisperKitEngine, transcriber: LiveTranscriber,
                                        publish: @escaping @Sendable (Update) async -> Void) async {
        do {
            try await engine.prepare { s in
                let text: String
                switch s {
                case .downloading(let f): text = String(format: "Downloading live model… %.0f%%", f * 100)
                case .loading: text = "Preparing live model (first time takes a minute)…"
                case .ready: text = "Listening…"
                }
                let st: LiveTranscriptStatus = s == .ready ? .running : .preparing(text)
                Task { await publish(.status(st)) }
            }
        } catch {
            Log.error(.stt, "Live transcript: model unavailable: \(error)")
            await publish(.status(.failed("Live model unavailable")))
            return
        }
        await publish(.status(.running))

        var pauseReason: String?
        var lastPowerCheck = Date.distantPast
        while !Task.isCancelled {
            for track in tap.tracks {
                let samples = tap.drain16k(track)
                if !samples.isEmpty { await transcriber.append(samples, track: track) }
            }
            if Date().timeIntervalSince(lastPowerCheck) > 10 {
                lastPowerCheck = Date()
                let reason = Self.pauseReason()
                if reason != pauseReason {
                    pauseReason = reason
                    Log.info(.stt, "Live transcript \(reason.map { "paused: \($0)" } ?? "resumed")")
                    await publish(.status(reason.map { .paused($0) } ?? .running))
                }
            }
            if pauseReason != nil {
                await transcriber.skipPending()
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            do {
                if try await transcriber.step() {
                    await publish(.snapshot(await transcriber.current))
                } else {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            } catch {
                if Task.isCancelled { break }
                Log.error(.stt, "Live pass failed: \(error)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await transcriber.flush()
        await publish(.snapshot(await transcriber.current))
        await engine.unload()
        Log.info(.stt, "Live transcript: stopped (\(tap.dropped) samples dropped while busy)")
    }

    /// Why live transcription should pause right now, if it should.
    nonisolated static func pauseReason() -> String? {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "Mac is running hot"
        }
        let power = PowerState.current()
        return power.shouldDeferHeavyWork ? (power.reason ?? "saving power") : nil
    }

    private func apply(_ update: Update, for sid: SessionID) {
        guard sid == sessionID else {
            // Final flush after stop(): only lines matter (the widget is hidden by then).
            if case .snapshot(let s) = update { allLines = s.lines }
            return
        }
        switch update {
        case .status(let s):
            if s != status { status = s }
        case .snapshot(let s):
            allLines = s.lines
            tentative = s.tentative
            averagePassSeconds = s.averagePassSeconds
            lines = RecordingPreferences.echoDedup ? removeEcho(s.lines, sid: sid) : s.lines
            revision += 1
        }
    }

    /// Hides mic lines that repeat the call (speakers instead of headphones), like the final transcript does.
    /// Only the recent lines are re-checked; earlier decisions are kept.
    private func removeEcho(_ all: [LiveTranscriber.Line], sid: SessionID) -> [LiveTranscriber.Line] {
        let recent = all.suffix(60)
        let segs = recent.map {
            TranscriptSegment(id: Int64($0.id), sessionID: sid, speakerID: nil, track: $0.track,
                              startMs: Int($0.start * 1000), endMs: Int($0.end * 1000), text: $0.text)
        }
        for s in EchoDeduplicator.dedupe(segs).removed { if let id = s.id { echoRemoved.insert(Int(id)) } }
        return all.filter { !echoRemoved.contains($0.id) }
    }
}

// MARK: - AppState wiring

extension AppState {
    /// Starts / stops the live transcript with the recording (called from `recordingStateDidChange`).
    func updateLiveTranscript() {
        guard recording.isActive, let sid = recording.info?.sessionID else {
            live.stop()
            return
        }
        guard live.sessionID != sid, LivePreferences.enabled, let recorder, let paths, !liveStarting else { return }
        liveStarting = true
        Task { [weak self] in
            let tap = await recorder.liveTap
            guard let self else { return }
            self.liveStarting = false
            guard let tap, self.recording.info?.sessionID == sid, self.recording.isActive else { return }
            self.live.start(sessionID: sid, tap: tap, modelsDir: paths.modelsDir, sessionDirectory: paths.sessionDir(sid))
        }
    }
}
