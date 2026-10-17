import AVFoundation
import CoreAudio
import EMCore
import Foundation

/// 5-second check of both capture paths (EM-131/132): plays a quiet test tone from this app and records it through
/// a process tap on itself (proves the "System Audio Recording" permission and the tap path work), while also
/// measuring the microphone. The first run triggers the macOS permission prompts.
public enum AudioSelfTest {
    public struct Result: Sendable, Equatable {
        public var systemPeakDB: Float
        public var micPeakDB: Float?
        public var device: String
        public var error: String?
        /// The tone came back through the tap → system-audio capture works.
        public var systemOK: Bool { error == nil && systemPeakDB > -50 }
        /// Something above the noise floor → the mic delivers audio (say something during the test).
        public var micOK: Bool { (micPeakDB ?? -120) > -70 }
    }

    public static func run(seconds: Double = 5, includeMic: Bool = true) async -> Result {
        // 1. Tone from this process (quiet, 660 Hz with fade in/out).
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let fade = min(1, Float(i) / 4_800, Float(Int(frames) - i) / 4_800)
            p[i] = 0.08 * fade * sinf(2 * .pi * 660 * Float(i) / 48_000)
        }
        do { try engine.start() } catch { return Result(systemPeakDB: -120, micPeakDB: nil, device: "", error: "Couldn't play the test tone: \(error.localizedDescription)") }
        player.scheduleBuffer(buf, at: nil)
        player.play()
        defer { player.stop(); engine.stop() }

        // 2. Our own audio process object appears once we produce output.
        var me: AudioProcessInfo?
        for _ in 0..<20 {
            me = AudioProcesses.current().first { $0.pid == getpid() }
            if me != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let me else { return Result(systemPeakDB: -120, micPeakDB: nil, device: "", error: "This app's audio process wasn't found") }

        // 3. Capture through the same aggregate path as a real recording.
        let cap = AggregateCapture(processObjectIDs: [me.objectID], includeMic: includeMic, bufferSeconds: seconds + 2)
        do { try cap.start() } catch {
            return Result(systemPeakDB: -120, micPeakDB: nil, device: "", error: "Capture failed: \(error.localizedDescription). Allow EchoMinutes under Privacy & Security ▸ Screen & System Audio Recording.")
        }
        defer { cap.stop() }
        try? await Task.sleep(for: .seconds(max(1, seconds - 0.5)))
        let sys = peakDB(cap.systemRing), mic = includeMic ? peakDB(cap.micRing) : nil
        Log.info(.audio, String(format: "Self-test: system %.0f dBFS, mic %@ dBFS, %@", sys, mic.map { String(format: "%.0f", $0) } ?? "n/a", cap.deviceSummary))
        return Result(systemPeakDB: sys, micPeakDB: mic, device: cap.deviceSummary, error: nil)
    }

    static func peakDB(_ ring: SPSCRingBuffer) -> Float {
        let samples = ring.read(maxCount: ring.availableToRead)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0 ? max(-120, 20 * log10(peak)) : -120
    }
}
