import AVFoundation
import Foundation

/// Decodes an audio file to 16 kHz mono Float32 — Whisper's input format.
public enum AudioLoader {
    public static let sampleRate: Double = 16_000

    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscriptionError.audioUnreadable(url.lastPathComponent) }
        let inFmt = file.processingFormat
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFmt, to: outFmt) else { throw TranscriptionError.audioUnreadable(url.lastPathComponent) }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * sampleRate / inFmt.sampleRate) + 1024)
        let inBlock: AVAudioFrameCount = 48_000
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inBlock)!
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(inBlock) * sampleRate / inFmt.sampleRate) + 1024)!
        var reachedEnd = false

        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, inStatus in
                if reachedEnd { inStatus.pointee = .endOfStream; return nil }
                let remaining = file.length - file.framePosition
                guard remaining > 0, (try? file.read(into: inBuf, frameCount: min(inBlock, AVAudioFrameCount(remaining)))) != nil,
                      inBuf.frameLength > 0 else {
                    reachedEnd = true; inStatus.pointee = .endOfStream; return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error || (reachedEnd && outBuf.frameLength == 0) { break }
        }
        return out
    }
}
