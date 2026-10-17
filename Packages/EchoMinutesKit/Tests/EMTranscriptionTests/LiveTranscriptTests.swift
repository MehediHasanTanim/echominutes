import EMCore
import Foundation
import Testing
@testable import EMTranscription

// MARK: - LiveWindow (EM-142 commit logic)

@Suite("Live window")
struct LiveWindowTests {
    func seg(_ text: String, _ start: Double, _ end: Double) -> RawSegment { RawSegment(start: start, end: end, text: text) }

    @Test func firstPassIsAllTentative() {
        var w = LiveWindow()
        let r = w.ingest([seg("hello there", 0, 2), seg("how are", 2.2, 4)], bufferSeconds: 6)
        #expect(r.committed.isEmpty)
        #expect(r.tentative.count == 2)
        #expect(r.advance == 0)
    }

    @Test func commitsWhenTwoPassesAgree() {
        var w = LiveWindow()
        _ = w.ingest([seg("Hello there.", 0, 2), seg("how are", 2.2, 4)], bufferSeconds: 4.5)
        let r = w.ingest([seg("hello there", 0.1, 2), seg("how are you", 2.2, 5)], bufferSeconds: 6)
        #expect(r.committed.map(\.text) == ["hello there"])
        #expect(r.tentative.map(\.text) == ["how are you"])
        #expect(r.advance == 2)
        // The next pass is relative to the new start (2 s later): "how are you" at 0.2 now matches.
        let r2 = w.ingest([seg("how are you", 0.2, 3), seg("fine", 3.2, 3.8)], bufferSeconds: 5)
        #expect(r2.committed.map(\.text) == ["how are you"])
        #expect(r2.advance == 3)
    }

    @Test func doesNotCommitWhileStillSpeaking() {
        var w = LiveWindow()
        _ = w.ingest([seg("hello", 0, 3)], bufferSeconds: 3.5)
        let r = w.ingest([seg("hello", 0, 3)], bufferSeconds: 4)     // ends only 1 s before the audio end
        #expect(r.committed.isEmpty)
    }

    @Test func changedTextIsNotCommitted() {
        var w = LiveWindow()
        _ = w.ingest([seg("I think we", 0, 2)], bufferSeconds: 5)
        let r = w.ingest([seg("I think we should", 0, 2.5)], bufferSeconds: 6.5)
        #expect(r.committed.isEmpty)
    }

    @Test func longWindowCommitsAllButLast() {
        var w = LiveWindow()
        let r = w.ingest([seg("a b", 0, 5), seg("c d", 5, 10), seg("e f", 10, 15.5)], bufferSeconds: 16)
        #expect(r.committed.map(\.text) == ["a b", "c d"])
        #expect(r.advance == 10)
    }

    @Test func hardCapCommitsEverything() {
        var w = LiveWindow()
        let r = w.ingest([seg("one", 0, 20), seg("two", 20, 26.5)], bufferSeconds: 27)
        #expect(r.committed.count == 2)
        #expect(r.tentative.isEmpty)
        #expect(r.advance == 26.5)
    }

    @Test func dropsLongUnintelligibleAudio() {
        var w = LiveWindow()
        let r = w.ingest([], bufferSeconds: 16)
        #expect(r.advance == 15)
        #expect(r.committed.isEmpty)
    }
}

// MARK: - LiveTranscriber (EM-142 / EM-148)

/// "Speech" made of 2-s blocks of constant amplitude; block n has amplitude 0.1 + 0.01·n and is "heard" as "word<n>".
/// The engine turns each run of equal samples into one segment, so a block still being recorded comes back shorter.
final class BlockEngine: TranscriptionEngine, @unchecked Sendable {
    static let blockSeconds = 2.0
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    var identifier: String { "block" }
    func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws { status(.ready) }

    func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        lock.withLock { _calls += 1 }
        var out: [RawSegment] = []
        var i = 0
        while i < samples.count {
            let v = samples[i]
            var j = i
            while j < samples.count, samples[j] == v { j += 1 }
            if v > 0.05 {
                let id = Int(((v - 0.1) / 0.01).rounded())
                out.append(RawSegment(start: Double(i) / 16_000, end: Double(j) / 16_000, text: "word\(id)"))
            }
            i = j
        }
        return out
    }

    static func block(_ id: Int, seconds: Double = blockSeconds) -> [Float] {
        [Float](repeating: 0.1 + 0.01 * Float(id), count: Int(seconds * 16_000))
    }
}

@Suite("Live transcriber")
struct LiveTranscriberTests {
    /// Feeds audio in 0.5 s pieces like the app does and runs passes until idle.
    func feed(_ t: LiveTranscriber, _ audio: [Float], track: TrackKind = .system) async throws {
        let piece = 8_000
        var i = 0
        while i < audio.count {
            await t.append(Array(audio[i..<min(audio.count, i + piece)]), track: track)
            i += piece
            while try await t.step() {}
        }
    }

    @Test func commitsEveryWordOnceInOrder() async throws {
        let engine = BlockEngine()
        let t = LiveTranscriber(engine: engine, options: STTOptions(language: "en"), tracks: [.system])
        let audio = (0..<10).flatMap { BlockEngine.block($0) }
        try await feed(t, audio)
        await t.setMinNewSeconds(0.01)          // one last pass over the final half second, as at Stop
        while try await t.step() {}
        await t.flush()
        let lines = await t.current.lines
        #expect(lines.map(\.text) == (0..<10).map { "word\($0)" })
        for (n, line) in lines.enumerated() {
            #expect(abs(line.start - Double(n) * 2) < 0.01)
            #expect(abs(line.end - Double(n + 1) * 2) < 0.01)
        }
        #expect(await t.current.tentative.isEmpty)
    }

    @Test func linesAppearWithinFiveSeconds() async throws {
        let engine = BlockEngine()
        let committedAt = Box()
        let t = LiveTranscriber(engine: engine, options: STTOptions(language: "en"), tracks: [.system]) { line in
            committedAt.set(line.text)
        }
        var fed = 0.0
        for id in 0..<6 {
            let block = BlockEngine.block(id)
            var i = 0
            while i < block.count {
                await t.append(Array(block[i..<i + 8_000]), track: .system)
                i += 8_000; fed += 0.5
                while try await t.step() {}
                committedAt.tick(fed)
            }
        }
        // word n ends at 2(n+1) s; it must be committed (not just shown) by 5 s after that.
        for n in 0..<4 {
            let at = try #require(committedAt.time(of: "word\(n)"))
            #expect(at - Double(n + 1) * 2 <= 5, "word\(n) committed at \(at) s")
        }
    }

    @Test func silenceIsSkippedWithoutTheModel() async throws {
        let engine = BlockEngine()
        let t = LiveTranscriber(engine: engine, options: STTOptions(language: "en"), tracks: [.mic, .system])
        try await feed(t, [Float](repeating: 0, count: 16_000 * 6), track: .mic)
        #expect(engine.calls == 0)
        #expect(await t.current.lines.isEmpty)
    }

    @Test func skippedAudioKeepsTheTimeline() async throws {
        let engine = BlockEngine()
        let t = LiveTranscriber(engine: engine, options: STTOptions(language: "en"), tracks: [.system])
        await t.append(BlockEngine.block(1, seconds: 6), track: .system)
        await t.skipPending()                                   // e.g. paused for Low Power Mode
        try await feed(t, BlockEngine.block(2) + BlockEngine.block(3))
        await t.flush()
        let lines = await t.current.lines
        #expect(lines.map(\.text) == ["word2", "word3"])
        #expect(abs((lines.first?.start ?? 0) - 6) < 0.01)
    }

    @Test func logRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = LiveTranscriptLog(sessionDirectory: dir)
        log.append(.init(id: 1, track: .system, start: 4, end: 6, text: "second"))
        log.append(.init(id: 0, track: .mic, start: 1, end: 2, text: "first"))
        #expect(LiveTranscriptLog.read(sessionDirectory: dir).map(\.text) == ["first", "second"])
        LiveTranscriptLog.delete(sessionDirectory: dir)
        #expect(LiveTranscriptLog.read(sessionDirectory: dir).isEmpty)
    }
}

/// Records when (in fed-audio seconds) each line was committed.
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var times: [String: Double] = [:]
    func set(_ text: String) { lock.withLock { pending.append(text) } }
    func tick(_ now: Double) { lock.withLock { for p in pending where times[p] == nil { times[p] = now }; pending = [] } }
    func time(of text: String) -> Double? { lock.withLock { times[text] } }
}
