import AVFoundation
import EMCore
import Foundation
import Testing
@testable import EMTranscription

/// 16 kHz test signal: silence (with optional noise floor) and tone "speech" bursts at given second ranges.
func signal(seconds: Double, bursts: [ClosedRange<Double>], amplitude: Float = 0.2, noise: Float = 0.0005) -> [Float] {
    let rate = AudioLoader.sampleRate
    var g = SystemRandomNumberGenerator()
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let n = Float.random(in: -noise...noise, using: &g)
        return bursts.contains { $0.contains(t) } ? amplitude * Float(sin(2 * .pi * 300 * t)) + n : n
    }
}

@Suite("SpeechRegionDetector")
struct SpeechRegionTests {
    @Test func findsBurstsWithPaddingAndSkipsSilence() {
        let s = signal(seconds: 60, bursts: [5...10, 30...32])
        let r = SpeechRegionDetector.detect(s)
        #expect(r.count == 2)
        #expect(abs(Double(r[0].start) / 16_000 - 4.6) < 0.1)          // 0.4 s pad before
        #expect(abs(Double(r[0].end) / 16_000 - 10.6) < 0.1)           // 0.6 s pad after
        #expect(abs(Double(r[1].start) / 16_000 - 29.6) < 0.1)
        let speech = r.reduce(0.0) { $0 + $1.duration }
        #expect(speech < 10)                                           // ~50 s of silence skipped
    }

    @Test func mergesShortGapsAndDropsBlips() {
        let s = signal(seconds: 20, bursts: [2...4, 4.8...6, 15...15.1])   // 0.8 s gap merges; 0.1 s blip dropped
        let r = SpeechRegionDetector.detect(s)
        #expect(r.count == 1)
        #expect(abs(Double(r[0].end) / 16_000 - 6.6) < 0.1)
    }

    @Test func quietSpeechOverComfortNoiseStillDetected() {
        // Teams-style comfort noise at ≈ −60 dBFS, quiet speaker at ≈ −35 dBFS.
        let s = signal(seconds: 30, bursts: [10...14], amplitude: 0.025, noise: 0.002)
        #expect(SpeechRegionDetector.detect(s).count == 1)
    }

    @Test func allSilenceGivesNoRegions() {
        #expect(SpeechRegionDetector.detect([Float](repeating: 0, count: 16_000 * 30)).isEmpty)
    }
}

@Suite("HallucinationGuard")
struct HallucinationGuardTests {
    @Test func spikeFixtures() {
        let segs: [RawSegment] = [
            RawSegment(start: 0, end: 2, text: " Hello, can you hear me?"),
            RawSegment(start: 2, end: 30, text: "Продолжение следует...", avgLogprob: -0.4, noSpeechProb: 0.3),  // Zoom silence
            RawSegment(start: 30, end: 31, text: "[Music]"),
            RawSegment(start: 31, end: 32, text: "Hello!", avgLogprob: -0.95, compressionRatio: 3.0, temperature: 1.0),  // S3 run 2
            RawSegment(start: 32, end: 33, text: "I know that.", avgLogprob: -0.55, compressionRatio: 1.07),
            RawSegment(start: 33, end: 34, text: "mumble", avgLogprob: -1.3),
            RawSegment(start: 34, end: 35, text: "hmm", noSpeechProb: 0.8),
            RawSegment(start: 35, end: 36, text: " "),
        ]
        let r = HallucinationGuard.filter(segs)
        #expect(r.kept.map(\.text) == ["Hello, can you hear me?", "I know that."])
        let reasons = Dictionary(grouping: r.dropped, by: { $0.1 }).mapValues(\.count)
        #expect(reasons[.blacklisted] == 2)
        #expect(reasons[.fallbackLoop] == 1)
        #expect(reasons[.lowConfidence] == 1)
        #expect(reasons[.noSpeech] == 1)
        #expect(reasons[.empty] == 1)
    }

    @Test func repeatedLinesAndLoops() {
        let segs = (0..<5).map { RawSegment(start: Double($0), end: Double($0) + 1, text: "Thank you.") }
            + [RawSegment(start: 6, end: 9, text: "the plan is the plan is the plan is the plan is the plan is fine")]
        let r = HallucinationGuard.filter(segs)
        #expect(r.kept.filter { $0.text == "Thank you." }.count == 2)          // 3rd+ identical line dropped
        #expect(r.kept.last?.text == "the plan is fine")
    }

    @Test func longSentenceMentioningMusicIsKept() {
        let s = RawSegment(start: 0, end: 5, text: "We should add some background music playing during the product demo next week")
        #expect(HallucinationGuard.filter([s]).kept.count == 1)
    }
}

/// Returns canned segments per call and records the slices it was given.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    let lock = NSLock()
    var calls: [Int] = []
    var identifier: String { "fake" }
    func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws { status(.ready) }
    func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        lock.withLock { calls.append(samples.count) }
        progress(0.5); progress(1)
        let d = Double(samples.count) / AudioLoader.sampleRate
        return [RawSegment(start: 0.4, end: d - 0.6, text: "region of \(Int(d.rounded())) s"),
                RawSegment(start: 0, end: 1, text: "[Music]")]
    }
}

@Suite("TrackTranscriber")
struct TrackTranscriberTests {
    @Test func transcribesOnlySpeechRegionsOnTheSessionTimeline() async throws {
        let engine = FakeEngine()
        let samples = signal(seconds: 120, bursts: [10...20, 90...95])
        let seen = ProgressLog()
        let out = try await TrackTranscriber(engine: engine).transcribe(samples: samples, options: STTOptions(language: "en")) { seen.add($0) }
        #expect(engine.calls.count == 2)                                   // two regions, not 120 s
        #expect(out.segments.count == 2)                                   // "[Music]" dropped by the guard
        #expect(out.dropped == 2)
        #expect(abs(out.segments[0].start - 10) < 0.15)                    // shifted back onto the timeline
        #expect(abs(out.segments[1].start - 90) < 0.15)
        #expect(out.speechSeconds < 20)
        #expect(seen.values == seen.values.sorted())                       // progress never goes backwards
        #expect(seen.values.last == 1)
    }

    @Test func loaderResamplesTo16k() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("em-stt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.m4a")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                  AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000 * 3)!
            buf.frameLength = 48_000 * 3
            for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = 0.3 * Float(sin(2 * .pi * 440 * Double(i) / 48_000)) }
            try f.write(from: buf)
        }
        let s = try AudioLoader.load16kMono(url)
        #expect(abs(s.count - 48_000) < 2_048)                             // 3 s at 16 kHz (AAC priming tolerance)
        #expect((s.map(abs).max() ?? 0) > 0.2)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Double] = []
    func add(_ x: Double) { lock.withLock { v.append(x) } }
    var values: [Double] { lock.withLock { v } }
}

@Suite("EchoDeduplicator")
struct EchoDedupTests {
    let sid = SessionID()
    func seg(_ track: TrackKind, _ s: Double, _ e: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(sessionID: sid, speakerID: track.rawValue, track: track, startMs: Int(s * 1000), endMs: Int(e * 1000), text: text)
    }

    /// The Teams "test call" transcript from 2026-10-15 (playback through the Mac speakers).
    @Test func teamsSpeakerEchoFixture() {
        let input = [
            seg(.mic, 0, 5, "To test your call quality, record a short message after the beep."),
            seg(.system, 0, 5, "To test your call quality, record a short message after the beep."),
            seg(.system, 6, 9, "Then your message will be played back to you."),
            seg(.mic, 7, 10, "Then your message will be played back to you."),
            seg(.mic, 10, 17, "Hello, this is another test call for testing my EcoMinutes utility tool."),
            seg(.mic, 18, 19, "Thank you."),
            seg(.mic, 21, 24, "Hello, this is another test call for testing my Ecominutes utility tool."),
            seg(.system, 24, 30, "Hello, this is another test call for testing my Ecominutes utility tool. Thank you."),
            seg(.mic, 30, 31, "Thank you."),
            seg(.system, 33, 37, "If you're happy with the quality of your message, then you've configured Teams correctly."),
            seg(.mic, 33, 37, "If you're happy with the quality of your message, then you've configured Teams correctly."),
            seg(.system, 37, 40, "If not, check your device settings and try again."),
            seg(.mic, 37, 40, "If not, check your device settings and try again."),
        ]
        let r = EchoDeduplicator.dedupe(input)
        let mine = r.segments.filter { $0.track == .mic }.map { "\($0.startMs / 1000) \($0.text)" }
        #expect(mine == ["10 Hello, this is another test call for testing my EcoMinutes utility tool.", "18 Thank you."])
        #expect(r.removed.count == 6)
        #expect(r.segments.filter { $0.track == .system }.count == 5)       // the call track is never touched
    }

    @Test func overlappingButDifferentSpeechIsKept() {
        let r = EchoDeduplicator.dedupe([
            seg(.system, 10, 14, "Can you send me the budget numbers by Friday?"),
            seg(.mic, 12, 15, "Sure, I will share the spreadsheet tomorrow morning."),
        ])
        #expect(r.removed.isEmpty)
    }

    @Test func sameWordsFarApartAreKept() {
        let r = EchoDeduplicator.dedupe([
            seg(.system, 10, 12, "Sounds good, thank you."),
            seg(.mic, 60, 62, "Sounds good, thank you."),
        ])
        #expect(r.removed.isEmpty)
    }

    @Test func lonelyYouIsAHallucination() {
        let r = HallucinationGuard.filter([RawSegment(start: 40, end: 41, text: " you"), RawSegment(start: 41, end: 42, text: "Thank you, see you.")])
        #expect(r.kept.map(\.text) == ["Thank you, see you."])
    }
}

@Suite("SpeakerAssigner")
struct SpeakerAssignerTests {
    let sid = SessionID()
    func seg(_ s: Double, _ e: Double) -> TranscriptSegment {
        TranscriptSegment(sessionID: sid, speakerID: nil, track: .system, startMs: Int(s * 1000), endMs: Int(e * 1000), text: "x")
    }

    @Test func assignsByMaxOverlapAndNumbersByFirstAppearance() throws {
        let turns = [SpeakerTurn(speaker: 7, start: 0, end: 10), SpeakerTurn(speaker: 3, start: 10, end: 20),
                     SpeakerTurn(speaker: 7, start: 20, end: 30)]
        let a = try #require(SpeakerAssigner.assign([seg(1, 9), seg(8, 18), seg(21, 29), seg(29, 31)], turns: turns))
        #expect(a.speakerCount == 2)
        #expect(a.speakerOfSegment == [1, 2, 1, 1])        // 7 appears first → Speaker 1; 8–18 overlaps 3 most
    }

    @Test func nearestTurnWithinOneSecondElseUnknown() throws {
        let turns = [SpeakerTurn(speaker: 0, start: 0, end: 5), SpeakerTurn(speaker: 1, start: 10, end: 15)]
        let a = try #require(SpeakerAssigner.assign([seg(1, 4), seg(5.3, 5.8), seg(7, 8), seg(11, 14)], turns: turns))
        #expect(a.speakerOfSegment == [1, 1, nil, 2])
    }

    @Test func tinyClustersAreFoldedIntoNeighbours() throws {
        // 30 lines alternating A/B; the diarizer also invents speakers 7 and 8 for two lines.
        var turns: [SpeakerTurn] = []
        var segs: [TranscriptSegment] = []
        for i in 0..<30 {
            let t = Double(i * 5)
            let spk = i == 10 ? 7 : (i == 20 ? 8 : i % 2)
            turns.append(SpeakerTurn(speaker: spk, start: t, end: t + 4))
            segs.append(seg(t + 0.5, t + 3.5))
        }
        let a = try #require(SpeakerAssigner.assign(segs, turns: turns))
        #expect(a.speakerCount == 2)
        #expect(a.speakerOfSegment.allSatisfy { $0 != nil })
    }

    @Test func singleSpeakerKeepsOthers() {
        #expect(SpeakerAssigner.assign([seg(1, 4), seg(6, 9)], turns: [SpeakerTurn(speaker: 0, start: 0, end: 10)]) == nil)
        #expect(SpeakerAssigner.assign([seg(1, 4)], turns: []) == nil)
    }
}
