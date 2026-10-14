import AVFoundation
import EMCore
import Foundation
import Testing
@testable import EMAudio

/// Test double: rings filled synchronously with a sine (system) and a different sine (mic).
final class FakeSource: CaptureSource, @unchecked Sendable {
    let micRing = SPSCRingBuffer(minimumCapacity: 48_000 * 20)
    let systemRing = SPSCRingBuffer(minimumCapacity: 48_000 * 20)
    let includesMic: Bool
    var sampleRate: Double
    private var phase = 0

    init(rate: Double = 48_000, includesMic: Bool = true) { sampleRate = rate; self.includesMic = includesMic }

    /// Pushes `seconds` of audio at the current rate into both rings (aligned, like the IO block).
    func feed(seconds: Double, amplitude: Float = 0.5, micAmplitude: Float? = nil) {
        let n = Int(seconds * sampleRate)
        var sys = [Float](repeating: 0, count: n), mic = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(phase + i) / sampleRate
            sys[i] = amplitude * Float(sin(2 * .pi * 440 * t))
            mic[i] = (micAmplitude ?? amplitude) * Float(sin(2 * .pi * 220 * t))
        }
        phase += n
        sys.withUnsafeBufferPointer { _ = systemRing.write($0.baseAddress!, count: n) }
        if includesMic { mic.withUnsafeBufferPointer { _ = micRing.write($0.baseAddress!, count: n) } }
    }
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("em-chunks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func frames(_ url: URL) -> Int { Int((try? AVAudioFile(forReading: url))?.length ?? -1) }

@Suite("ChunkWriter", .serialized)
struct ChunkWriterTests {
    @Test func writesAlignedChunksAndManifest() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 1, warnBelowBytes: 0, stopBelowBytes: 0)
        for _ in 0..<5 { src.feed(seconds: 0.5); w.pump() }        // 2.5 s
        let m = w.finish()

        #expect(m.systemChunks.count == 3 && m.micChunks.count == 3)          // 1 s + 1 s + 0.5 s
        #expect(m.systemChunks.map(\.frames) == [48_000, 48_000, 24_000])
        #expect(m.micChunks.map(\.frames) == m.systemChunks.map(\.frames))    // tracks aligned
        #expect(m.durationMs == 2_500)
        #expect(m.markers.last?.type == "stop")
        for c in m.systemChunks + m.micChunks {
            let n = frames(dir.appendingPathComponent(c.file))
            #expect(abs(n - c.frames) < 2_048, "\(c.file): \(n) vs \(c.frames)")   // AAC priming tolerance
        }
        #expect(try RecordingManifest.load(from: dir) == m)
    }

    @Test func preRollKeepsOnlyTheLastSeconds() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .candidate(preRollSeconds: 2), chunkSeconds: 30, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 6); w.pump()                                 // candidate: trims to 2 s
        #expect(src.systemRing.availableToRead == 96_000)
        w.setMode(.persisting)                                         // pre-roll gets written
        src.feed(seconds: 1)
        let m = w.finish()
        #expect(m.totalFrames == 48_000 * 3)
        #expect(m.markers.map(\.type).first == "start")
    }

    /// Regression (Zoom call, chunks 20–29 unreadable): with the real 100 ms timer running for many rotations,
    /// every chunk listed in the on-disk manifest must already be a finalised, readable file — before finish().
    @Test func closedChunksAreReadableWhileRecording() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 0.5, warnBelowBytes: 0, stopBelowBytes: 0)
        w.start()
        for _ in 0..<40 {                                  // 20 s of audio → ~40 chunk rotations on the timer
            src.feed(seconds: 0.5)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(400))      // let the timer drain the rest
        let onDisk = try RecordingManifest.load(from: dir)
        #expect(onDisk.systemChunks.count >= 30)
        var unreadable: [String] = []
        for c in onDisk.systemChunks + onDisk.micChunks {
            let len = (try? AVAudioFile(forReading: dir.appendingPathComponent(c.file)))?.length ?? 0
            if len <= 0 { unreadable.append(c.file) }
        }
        #expect(unreadable.isEmpty, "unreadable while recording: \(unreadable)")
        #expect(w.persistedMs > 15_000)                    // lock-free mirror is updated by the timer
        w.finish()
        var errors: [ChunkWriter.Event] = []
        for await e in w.events { if case .error = e { errors.append(e) } }
        #expect(errors.isEmpty)
    }

    @Test func metersReportPeakLevels() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 30, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 0.5, amplitude: 0.5, micAmplitude: 0.05); w.pump()
        let l = w.levels
        #expect(abs(l.systemDB - -6) < 2.5)        // peak 0.5 ≈ −6 dBFS (one decay step applied before reading)
        #expect(abs(l.micDB - -26) < 2.5)          // peak 0.05 ≈ −26 dBFS
        w.finish()
    }

    @Test func pausedAudioIsDropped() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 30, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 1); w.pump()
        w.setMode(.paused); src.feed(seconds: 3); w.pump()
        w.setMode(.persisting); src.feed(seconds: 1)
        let m = w.finish()
        #expect(m.totalFrames == 96_000)
        #expect(m.markers.map(\.type) == ["pause", "resume", "stop"])
    }

    @Test func bluetoothRateChangeIsResampledTo48k() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource(rate: 48_000)
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 30, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 1); w.pump()
        src.sampleRate = 16_000                                        // headset switched to HFP
        src.feed(seconds: 2); w.pump()
        let m = w.finish()
        #expect(m.rateChanges == 1)
        #expect(abs(m.totalFrames - 48_000 * 3) < 2_000)               // 3 s at 48 kHz (converter latency tolerance)
        #expect(m.markers.contains { $0.type == "rateChange" && $0.detail == "48000→16000" })
    }

    @Test func clampsOverdrivenSamples() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource(includesMic: false)
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 30, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 1, amplitude: 3)                             // way above 0 dBFS
        let m = w.finish()
        #expect(m.micChunks.isEmpty && m.systemChunks.count == 1)
        let f = try AVAudioFile(forReading: dir.appendingPathComponent(m.systemChunks[0].file))
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let peak = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 0
        #expect(peak < 1.2)                                            // clamped (AAC may overshoot slightly)
    }

    @Test func stopsWhenDiskIsFull() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 1,
                                warnBelowBytes: .max, stopBelowBytes: .max)            // pretend disk is always full
        src.feed(seconds: 3); w.pump()
        let m = w.finish()
        #expect(m.totalFrames == 48_000)                               // stopped after first chunk
        #expect(m.markers.contains { $0.type == "diskFullStop" })
        var events: [ChunkWriter.Event] = []
        for await e in w.events { events.append(e) }
        #expect(events.contains { if case .diskFullStopped = $0 { true } else { false } })
    }
}

@Suite("AudioFinalizer", .serialized)
struct AudioFinalizerTests {
    @Test func buildsTracksMixAndWaveformThenDeletesChunks() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 1, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 2.5); w.pump(); w.finish()

        let r = try AudioFinalizer.finalize(sessionDirectory: dir)
        #expect(abs(r.durationMs - 2_500) < 100)
        for kind in [TrackKind.mic, .system, .mixed] {
            let url = try #require(r.tracks[kind])
            #expect(abs(frames(url) - 120_000) < 4_096, "\(kind)")
        }
        #expect(abs(r.waveformPeaks - 50) <= 2)                        // 2.5 s / 50 ms
        #expect(AudioFinalizer.loadWaveform(r.waveformURL).allSatisfy { $0 > 0.3 })   // sine is loud everywhere
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("chunks").path))
        #expect(try RecordingManifest.load(from: dir).finalized)
    }

    @Test func quietMicIsBoostedInTheMix() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 2, warnBelowBytes: 0, stopBelowBytes: 0,
                                devices: "out: Test Speakers, mic: Test Mic")
        src.feed(seconds: 4, amplitude: 0.15, micAmplitude: 0.01)    // others ≈ −19 dBFS, me ≈ −43 dBFS
        w.pump(); w.finish()

        _ = try AudioFinalizer.finalize(sessionDirectory: dir)
        let m = try RecordingManifest.load(from: dir)
        #expect(m.devices == "out: Test Speakers, mic: Test Mic")
        let mix = try #require(m.mix)
        let micLevel = try #require(mix.micLevelDB)
        let sysLevel = try #require(mix.systemLevelDB)
        #expect(abs(micLevel - -43) < 1.5)
        #expect(abs(sysLevel - -19.5) < 1.5)
        #expect(mix.micGainDB > 20)                                     // boosted (clamped at +24)
        #expect(abs(mix.systemGainDB) < 3)

        // Remixing the finished files gives the same result.
        let again = try AudioFinalizer.remix(sessionDirectory: dir)
        #expect(abs(again.micGainDB - mix.micGainDB) < 1)
    }

    @Test func levelerMath() {
        #expect(Leveler.gainDB(level: nil, maxBoostDB: 24) == 0)
        #expect(Leveler.gainDB(level: -38, maxBoostDB: 24) == 20)
        #expect(Leveler.gainDB(level: -60, maxBoostDB: 24) == 24)
        #expect(Leveler.gainDB(level: -3, maxBoostDB: 24) == -6)
        #expect(Leveler.softLimit(0.5) == 0.5)
        #expect(Leveler.softLimit(3) <= 1)
        #expect(Leveler.softLimit(-3) >= -1)
        #expect(Leveler.softLimit(0.95) > 0.89)
    }

    @Test func recoversFromClosedChunksIgnoringTheOpenOne() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource(includesMic: false)
        let w = try ChunkWriter(source: src, sessionDirectory: dir, mode: .persisting, chunkSeconds: 1, warnBelowBytes: 0, stopBelowBytes: 0)
        src.feed(seconds: 2.4); w.pump()                               // 2 closed chunks + 0.4 s open (simulated crash: no finish())
        let r = try AudioFinalizer.finalize(sessionDirectory: dir, deleteChunks: false)
        #expect(abs(r.durationMs - 2_000) < 100)                       // loses only the open chunk
        #expect(r.tracks[.mic] == nil)
    }
}
