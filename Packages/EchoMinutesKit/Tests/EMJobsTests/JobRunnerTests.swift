import AVFoundation
import EMCore
import EMStorage
import EMTranscription
import Foundation
import Testing
@testable import EMJobs

/// Handler whose behaviour is scripted per call.
actor ScriptedHandler: JobHandler {
    enum Step: Sendable { case succeed, fail, failPermanently, slow(Duration) }
    var steps: [Step]
    private(set) var runs: [String] = []
    private(set) var maxConcurrent = 0
    private var current = 0

    init(_ steps: [Step]) { self.steps = steps }

    nonisolated func run(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let step = await next(job)
        defer { Task { await self.done() } }
        progress(0.5, "half")
        switch step {
        case .succeed: return
        case .fail: throw EMError.invalidData("boom")
        case .failPermanently: throw JobFailure.permanent("nope")
        case .slow(let d): try await Task.sleep(for: d)
        }
    }

    private func next(_ job: Job) -> Step {
        runs.append(job.id); current += 1; maxConcurrent = max(maxConcurrent, current)
        return steps.isEmpty ? .succeed : steps.removeFirst()
    }
    private func done() { current -= 1 }
}

/// Collects runner events until a predicate holds (or times out).
func waitFor(_ runner: JobRunner, timeout: Duration = .seconds(5), until: @escaping @Sendable ([JobEvent]) -> Bool) async -> [JobEvent] {
    let stream = runner.events
    let task = Task {
        var seen: [JobEvent] = []
        for await e in stream {
            seen.append(e)
            if until(seen) { break }
        }
        return seen
    }
    let timer = Task { try? await Task.sleep(for: timeout); task.cancel() }
    let r = await task.value
    timer.cancel()
    return r
}

func finishedCount(_ es: [JobEvent]) -> Int { es.filter { if case .finished = $0 { true } else { false } }.count }

@Suite("JobRunner", .serialized)
struct JobRunnerTests {
    func session(_ db: AppDatabase) throws -> SessionID {
        let s = Session(title: "t", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        try SessionRepository(db).insert(s)
        return s.id
    }

    @Test func runsQueuedJobsAndMarksThemDone() async throws {
        let db = try AppDatabase.inMemory()
        let sid = try session(db)
        let h = ScriptedHandler([.succeed])
        let runner = JobRunner(db: db, handlers: [.transcribe: h], power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        await runner.enqueue(.transcribe, sessionID: sid)
        await runner.start()
        let events = await waitFor(runner) { finishedCount($0) == 1 }
        #expect(finishedCount(events) == 1)
        #expect(events.contains { e in
            if case .progress(_, let s, let k, let f, let m) = e { return s == sid && k == .transcribe && f == 0.5 && m == "half" }
            return false
        })
        #expect(try JobRepository(db).jobs(for: sid).map(\.status) == [.done])
        await runner.stop()
    }

    @Test func failureIsRetriedWithBackoffPermanentIsNot() async throws {
        let db = try AppDatabase.inMemory()
        let a = try session(db), b = try session(db)
        let h = ScriptedHandler([.fail, .failPermanently])
        let runner = JobRunner(db: db, handlers: [.transcribe: h], power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        await runner.enqueue(.transcribe, sessionID: a)
        await runner.enqueue(.transcribe, sessionID: b)
        await runner.start()
        let events = await waitFor(runner) { es in es.filter { if case .failed = $0 { true } else { false } }.count == 2 }
        let fails = events.compactMap { e -> Bool? in if case .failed(_, _, let retry) = e { retry } else { nil } }
        #expect(fails == [true, false])
        let ja = try #require(JobRepository(db).jobs(for: a).first)
        #expect(ja.status == .queued)                                   // waits for backoff
        #expect((ja.notBefore ?? .distantPast) > Date().addingTimeInterval(20))
        #expect(try JobRepository(db).jobs(for: b).first?.status == .failed)
        #expect(JobRunner.backoff(attempt: 1) == 30)
        #expect(JobRunner.backoff(attempt: 3) == 480)
        #expect(JobRunner.backoff(attempt: 9) == 3600)
        await runner.stop()
    }

    @Test func onlyOneTranscriptionAtATime() async throws {
        let db = try AppDatabase.inMemory()
        let h = ScriptedHandler([.slow(.milliseconds(150)), .slow(.milliseconds(150)), .slow(.milliseconds(150))])
        let runner = JobRunner(db: db, handlers: [.transcribe: h], power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        for _ in 0..<3 { await runner.enqueue(.transcribe, sessionID: try session(db)) }
        await runner.start()
        _ = await waitFor(runner) { finishedCount($0) == 3 }
        #expect(await h.runs.count == 3)
        #expect(await h.maxConcurrent == 1)
        await runner.stop()
    }

    @Test func lowBatteryDefersUnlessForced() async throws {
        let db = try AppDatabase.inMemory()
        let a = try session(db), b = try session(db)
        let h = ScriptedHandler([])
        let runner = JobRunner(db: db, handlers: [.transcribe: h], power: { PowerState(onBattery: true, batteryPercent: 12, lowPowerMode: false) })
        await runner.enqueue(.transcribe, sessionID: a)
        await runner.enqueue(.transcribe, sessionID: b, force: true)       // "Transcribe now"
        await runner.start()
        let events = await waitFor(runner) { es in finishedCount(es) == 1 && es.contains { if case .deferred = $0 { true } else { false } } }
        #expect(events.contains { if case .deferred(let j, let r) = $0 { j.sessionID == a && r.contains("12") } else { false } })
        #expect(try JobRepository(db).jobs(for: b).first?.status == .done)
        let ja = try #require(JobRepository(db).jobs(for: a).first)
        #expect(ja.status == .queued && ja.attempts == 0)                 // deferral doesn't use up retries
        await runner.stop()
    }

    @Test func jobsLeftRunningByACrashResume() async throws {
        let db = try AppDatabase.inMemory()
        let sid = try session(db)
        let repo = JobRepository(db)
        try repo.enqueue(.transcribe, sessionID: sid)
        _ = try repo.claimNext()                                          // "crash" while running
        let runner = JobRunner(db: db, handlers: [.transcribe: ScriptedHandler([])], power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        await runner.start()
        _ = await waitFor(runner) { finishedCount($0) == 1 }
        #expect(try repo.jobs(for: sid).first?.status == .done)
        await runner.stop()
    }

    @Test func powerStateRules() {
        #expect(PowerState(onBattery: true, batteryPercent: 19, lowPowerMode: false).shouldDeferHeavyWork)
        #expect(!PowerState(onBattery: true, batteryPercent: 20, lowPowerMode: false).shouldDeferHeavyWork)
        #expect(!PowerState(onBattery: false, batteryPercent: 5, lowPowerMode: false).shouldDeferHeavyWork)
        #expect(PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: true).shouldDeferHeavyWork)
    }
}

/// Engine that "hears" a fixed sentence in every speech region.
struct EchoEngine: TranscriptionEngine {
    var identifier: String { "echo-test" }
    func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws { status(.loading); status(.ready) }
    func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        progress(1)
        return [RawSegment(start: 0.4, end: Double(samples.count) / 16_000 - 0.6, text: "speech in \(options.language)")]
    }
}

@Suite("TranscribeJobHandler", .serialized)
struct TranscribeJobHandlerTests {
    func writeTrack(_ url: URL, bursts: [ClosedRange<Double>], seconds: Double) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                              AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000],
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * 48_000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let t = Double(i) / 48_000
            buf.floatChannelData![0][i] = bursts.contains { $0.contains(t) } ? 0.2 * Float(sin(2 * .pi * 300 * t)) : 0
        }
        try f.write(from: buf)
    }

    @Test func writesTranscriptForBothTracksAndRestoresStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("em-tj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(root: root)
        let db = try AppDatabase.inMemory()
        let s = Session(title: "Zoom call", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        try SessionRepository(db).insert(s)
        let dir = try paths.createSessionDirectories(s.id)
        try writeTrack(dir.appendingPathComponent("mic.m4a"), bursts: [2...5], seconds: 20)
        try writeTrack(dir.appendingPathComponent("system.m4a"), bursts: [8...12], seconds: 20)

        let h = TranscribeJobHandler(db: db, paths: paths, settings: { TranscriptionSettings(language: "bn") }, engine: { _ in EchoEngine() })
        let job = Job(id: "j1", sessionID: s.id, kind: .transcribe, status: .running, attempts: 1, lastError: nil, notBefore: nil)
        let log = MessageLog()
        try await h.run(job) { f, m in log.add(f, m) }

        let segs = try TranscriptRepository(db).segments(s.id)
        #expect(segs.count == 2)
        #expect(segs.map(\.track) == [.mic, .system])                    // sorted by time
        #expect(abs(segs[0].startMs - 2_000) < 150)
        #expect(abs(segs[1].startMs - 8_000) < 150)
        #expect(segs.allSatisfy { $0.text == "speech in bn" })
        let speakers = try TranscriptRepository(db).speakers(s.id)
        #expect(speakers.first?.isMe == true)
        #expect(segs[0].speakerID == speakers.first { $0.isMe }?.id)
        let after = try #require(SessionRepository(db).fetch(s.id))
        #expect(after.status == .ready)
        #expect(after.sttEngine == "echo-test")
        #expect(log.messages.contains { $0.contains("Optimizing") })
        #expect(log.fractions.last == 1)
    }

    @Test func missingAudioIsAPermanentFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("em-tj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(root: root)
        let db = try AppDatabase.inMemory()
        let s = Session(title: "x", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        try SessionRepository(db).insert(s)
        _ = try paths.createSessionDirectories(s.id)
        let h = TranscribeJobHandler(db: db, paths: paths, settings: { TranscriptionSettings() }, engine: { _ in EchoEngine() })
        let job = Job(id: "j2", sessionID: s.id, kind: .transcribe, status: .running, attempts: 1, lastError: nil, notBefore: nil)
        await #expect(throws: JobFailure.self) { try await h.run(job) { _, _ in } }
        #expect(try SessionRepository(db).fetch(s.id)?.status == .ready)
    }
}

final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var f: [Double] = [], m: [String] = []
    func add(_ x: Double, _ s: String) { lock.withLock { f.append(x); m.append(s) } }
    var fractions: [Double] { lock.withLock { f } }
    var messages: [String] { lock.withLock { m } }
}
