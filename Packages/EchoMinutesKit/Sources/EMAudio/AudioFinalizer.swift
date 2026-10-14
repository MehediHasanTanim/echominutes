import AVFoundation
import EMCore
import Foundation

/// Turns a session's chunks into `mic.m4a`, `system.m4a`, `mixed.m4a` and `waveform.bin` (EM-054).
/// Works from the manifest only, so it also recovers sessions interrupted by a crash (EM-056).
public enum AudioFinalizer {
    public struct Result: Sendable, Equatable {
        public var durationMs: Int
        public var tracks: [TrackKind: URL]
        public var waveformURL: URL
        public var waveformPeaks: Int
    }

    /// Waveform resolution: one peak (0…255) per 50 ms of mixed audio.
    public static let waveformWindowSeconds = 0.05

    public static func finalize(sessionDirectory dir: URL, deleteChunks: Bool = true) throws -> Result {
        var manifest = try RecordingManifest.load(from: dir)
        let rate = manifest.sampleRate
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

        // Pass 1: concatenate chunks into the per-track files.
        var sysOut: AVAudioFile? = try writer(dir, "system.m4a")
        var micOut: AVAudioFile? = manifest.includesMic ? try writer(dir, "mic.m4a") : nil
        var totalFrames = 0
        for (i, sysChunk) in manifest.systemChunks.enumerated() {
            guard let sys = read(dir.appendingPathComponent(sysChunk.file), format: fmt) else {
                Log.error(.audio, "Unreadable chunk \(sysChunk.file) — skipped"); continue
            }
            try sysOut?.write(from: sys)
            if manifest.includesMic {
                // Keep the tracks aligned even if a mic chunk is missing: write silence of the same length.
                let mic = i < manifest.micChunks.count ? read(dir.appendingPathComponent(manifest.micChunks[i].file), format: fmt) : nil
                if let mic, mic.frameLength == sys.frameLength { try micOut?.write(from: mic) }
                else { try micOut?.write(from: aligned(mic, to: Int(sys.frameLength), format: fmt)) }
            }
            totalFrames += Int(sys.frameLength)
        }
        sysOut = nil; micOut = nil                          // finalise files

        // Pass 2: level-matched mix + waveform.
        let mix = try buildMix(sessionDirectory: dir, includesMic: manifest.includesMic, sampleRate: rate)

        let expected = manifest.totalFrames
        if abs(totalFrames - expected) > Int(rate) {
            Log.error(.audio, "Finalize: decoded \(totalFrames) frames, manifest says \(expected)")
        }
        manifest.mix = mix.info
        manifest.finalized = true
        try manifest.save(to: dir)
        if deleteChunks { try? FileManager.default.removeItem(at: dir.appendingPathComponent("chunks")) }

        var tracks: [TrackKind: URL] = [.system: dir.appendingPathComponent("system.m4a"), .mixed: dir.appendingPathComponent("mixed.m4a")]
        if manifest.includesMic { tracks[.mic] = dir.appendingPathComponent("mic.m4a") }
        return Result(durationMs: Int(Double(totalFrames) / rate * 1000), tracks: tracks,
                      waveformURL: dir.appendingPathComponent("waveform.bin"), waveformPeaks: mix.peaks)
    }

    /// Rebuilds `mixed.m4a` + `waveform.bin` from the finished `mic.m4a` / `system.m4a` (e.g. for recordings
    /// made before level matching existed). Updates the manifest's mix info.
    @discardableResult
    public static func remix(sessionDirectory dir: URL) throws -> RecordingManifest.MixInfo {
        var manifest = try RecordingManifest.load(from: dir)
        let hasMic = FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.m4a").path)
        let mix = try buildMix(sessionDirectory: dir, includesMic: hasMic, sampleRate: manifest.sampleRate)
        manifest.mix = mix.info
        try manifest.save(to: dir)
        return mix.info
    }

    static let block = 48_000 * 2

    /// Measures both tracks, applies per-track gain, sums with a soft limiter, writes mixed.m4a and waveform.bin.
    static func buildMix(sessionDirectory dir: URL, includesMic: Bool, sampleRate rate: Double) throws -> (info: RecordingManifest.MixInfo, peaks: Int) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let sysURL = dir.appendingPathComponent("system.m4a"), micURL = dir.appendingPathComponent("mic.m4a")

        var sysMeter = LevelMeter(sampleRate: rate), micMeter = LevelMeter(sampleRate: rate)
        try forEachBlock(sysURL, format: fmt) { p, n in sysMeter.add(p, count: n) }
        if includesMic { try forEachBlock(micURL, format: fmt) { p, n in micMeter.add(p, count: n) } }

        let sysLevel = sysMeter.speechLevelDB, micLevel = includesMic ? micMeter.speechLevelDB : nil
        let sysGainDB = Leveler.gainDB(level: sysLevel, maxBoostDB: 12)
        let micGainDB = Leveler.gainDB(level: micLevel, maxBoostDB: 24)
        let gs = Leveler.linear(sysGainDB), gm = Leveler.linear(micGainDB)
        Log.info(.audio, String(format: "Mix levels: system %@ dBFS → %+.1f dB, mic %@ dBFS → %+.1f dB",
                                sysLevel.map { String(format: "%.1f", $0) } ?? "n/a", sysGainDB,
                                micLevel.map { String(format: "%.1f", $0) } ?? "n/a", micGainDB))

        var mixOut: AVAudioFile? = try writer(dir, "mixed.m4a")
        let sysIn = try AVAudioFile(forReading: sysURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let micIn = includesMic ? try? AVAudioFile(forReading: micURL, commonFormat: .pcmFormatFloat32, interleaved: false) : nil
        let sysBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(block))!
        let micBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(block))!
        let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(block))!

        var peaks: [UInt8] = []
        let window = Int(rate * waveformWindowSeconds)
        var windowPeak: Float = 0, windowFill = 0
        while true {
            try sysIn.read(into: sysBuf, frameCount: AVAudioFrameCount(block))
            let n = Int(sysBuf.frameLength)
            if n == 0 { break }
            var micN = 0
            if let micIn { try micIn.read(into: micBuf, frameCount: AVAudioFrameCount(n)); micN = Int(micBuf.frameLength) }
            outBuf.frameLength = AVAudioFrameCount(n)
            let s = sysBuf.floatChannelData![0], m = micBuf.floatChannelData![0], out = outBuf.floatChannelData![0]
            for k in 0..<n {
                let v = Leveler.softLimit(gs * s[k] + (k < micN ? gm * m[k] : 0))
                out[k] = v
                windowPeak = max(windowPeak, abs(v)); windowFill += 1
                if windowFill == window { peaks.append(UInt8(min(255, windowPeak * 255))); windowPeak = 0; windowFill = 0 }
            }
            try mixOut?.write(from: outBuf)
        }
        if windowFill > 0 { peaks.append(UInt8(min(255, windowPeak * 255))) }
        mixOut = nil
        try Data(peaks).write(to: dir.appendingPathComponent("waveform.bin"), options: .atomic)

        let info = RecordingManifest.MixInfo(systemLevelDB: sysLevel, micLevelDB: micLevel,
                                             systemGainDB: sysGainDB, micGainDB: micGainDB,
                                             micActiveSeconds: includesMic ? micMeter.activeSeconds : nil)
        return (info, peaks.count)
    }

    private static func forEachBlock(_ url: URL, format: AVAudioFormat, _ body: (UnsafePointer<Float>, Int) -> Void) throws {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
        while true {
            try f.read(into: buf, frameCount: AVAudioFrameCount(block))
            if buf.frameLength == 0 { break }
            body(buf.floatChannelData![0], Int(buf.frameLength))
        }
    }

    private static func writer(_ dir: URL, _ name: String) throws -> AVAudioFile {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return try AVAudioFile(forWriting: url, settings: TrackWriter.aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// `buf` padded/truncated to `frames` (silence where missing).
    private static func aligned(_ buf: AVAudioPCMBuffer?, to frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        out.frameLength = AVAudioFrameCount(frames)
        let dst = out.floatChannelData![0]
        dst.initialize(repeating: 0, count: frames)
        if let buf { dst.update(from: buf.floatChannelData![0], count: min(frames, Int(buf.frameLength))) }
        return out
    }

    /// Decodes a whole chunk to Float32 at `format` (nil if missing/corrupt, e.g. the open chunk at a crash).
    static func read(_ url: URL, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        do { try f.read(into: buf) } catch { return nil }
        return buf
    }

    /// Reads `waveform.bin` back as 0…1 values.
    public static func loadWaveform(_ url: URL) -> [Float] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return d.map { Float($0) / 255 }
    }
}
