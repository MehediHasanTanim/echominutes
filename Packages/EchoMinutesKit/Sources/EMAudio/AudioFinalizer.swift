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
        func writer(_ name: String) throws -> AVAudioFile {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            return try AVAudioFile(forWriting: url, settings: TrackWriter.aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        var sysOut: AVAudioFile? = try writer("system.m4a")
        var micOut: AVAudioFile? = manifest.includesMic ? try writer("mic.m4a") : nil
        var mixOut: AVAudioFile? = try writer("mixed.m4a")
        var peaks: [UInt8] = []
        let window = Int(rate * waveformWindowSeconds)
        var windowPeak: Float = 0, windowFill = 0
        var totalFrames = 0

        for (i, sysChunk) in manifest.systemChunks.enumerated() {
            guard let sys = read(dir.appendingPathComponent(sysChunk.file), format: fmt) else {
                Log.error(.audio, "Unreadable chunk \(sysChunk.file) — skipped"); continue
            }
            var mic: AVAudioPCMBuffer?
            if manifest.includesMic, i < manifest.micChunks.count {
                mic = read(dir.appendingPathComponent(manifest.micChunks[i].file), format: fmt)
            }
            let n = Int(sys.frameLength)
            try sysOut?.write(from: sys)
            if let mic { try micOut?.write(from: mic) }

            guard let mixed = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { continue }
            mixed.frameLength = AVAudioFrameCount(n)
            let s = sys.floatChannelData![0], m = mic?.floatChannelData?[0], out = mixed.floatChannelData![0]
            let micN = Int(mic?.frameLength ?? 0)
            for k in 0..<n {
                let v = min(1, max(-1, 0.7 * s[k] + (k < micN ? 0.7 * m![k] : 0)))
                out[k] = v
                windowPeak = max(windowPeak, abs(v)); windowFill += 1
                if windowFill == window { peaks.append(UInt8(min(255, windowPeak * 255))); windowPeak = 0; windowFill = 0 }
            }
            try mixOut?.write(from: mixed)
            totalFrames += n
        }
        if windowFill > 0 { peaks.append(UInt8(min(255, windowPeak * 255))) }
        sysOut = nil; micOut = nil; mixOut = nil            // finalise files

        let waveformURL = dir.appendingPathComponent("waveform.bin")
        try Data(peaks).write(to: waveformURL, options: .atomic)

        let expected = manifest.totalFrames
        if abs(totalFrames - expected) > Int(rate) {
            Log.error(.audio, "Finalize: decoded \(totalFrames) frames, manifest says \(expected)")
        }
        manifest.finalized = true
        try manifest.save(to: dir)
        if deleteChunks { try? FileManager.default.removeItem(at: dir.appendingPathComponent("chunks")) }

        var tracks: [TrackKind: URL] = [.system: dir.appendingPathComponent("system.m4a"), .mixed: dir.appendingPathComponent("mixed.m4a")]
        if manifest.includesMic { tracks[.mic] = dir.appendingPathComponent("mic.m4a") }
        return Result(durationMs: Int(Double(totalFrames) / rate * 1000), tracks: tracks, waveformURL: waveformURL, waveformPeaks: peaks.count)
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
