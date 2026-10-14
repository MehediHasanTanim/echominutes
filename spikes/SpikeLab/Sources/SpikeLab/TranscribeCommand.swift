import AVFoundation
import Foundation
import WhisperKit

/// EM-011 / EM-012 — Spike S3: local transcription with WhisperKit + benchmark.
///
/// Usage: run.sh transcribe <audio> [<audio> …] [--model <name>] [--lang <code>] [--no-vad]
///   <audio>   absolute path, or relative to the repo root, or a file name in spikes/SpikeLab/output/
///   --model   WhisperKit model, e.g. base | small | large-v3-v20240930_turbo (default) | large-v3
///   --lang    force language (en, bn, …); default auto-detect
/// Models are downloaded on first use into spikes/SpikeLab/models/ (git-ignored).
/// Writes output/transcript-<file>-<model>.txt and appends a row to output/stt-bench.csv.
enum TranscribeCommand {
    static func run(_ args: [String]) async -> Int32 {
        var files: [String] = [], model = "large-v3-v20240930_turbo", lang: String?, vad = true
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model": i += 1; if i < args.count { model = args[i] }
            case "--lang": i += 1; if i < args.count { lang = args[i] }
            case "--no-vad": vad = false
            default: files.append(args[i])
            }
            i += 1
        }
        guard !files.isEmpty else { Log.error("Give at least one audio file"); return 2 }

        let labDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()   // spikes/SpikeLab
        let repo = labDir.deletingLastPathComponent().deletingLastPathComponent()
        let outDir = labDir.appendingPathComponent("output")
        let modelsDir = labDir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let urls: [URL] = files.compactMap { f in
            let candidates = f.hasPrefix("/") ? [URL(fileURLWithPath: f)]
                : [repo.appendingPathComponent(f), outDir.appendingPathComponent(f)]
            if let u = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return u }
            Log.error("Not found: \(f)"); return nil
        }
        guard !urls.isEmpty else { return 2 }

        // 1. Load (and download on first use)
        Log.line("Model: \(model)  (first use downloads it into spikes/SpikeLab/models — may take minutes)")
        let t0 = Date()
        let whisper: WhisperKit
        do {
            whisper = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: modelsDir))
        } catch {
            Log.error("WhisperKit init failed: \(error)"); return 1
        }
        let loadSec = Date().timeIntervalSince(t0)
        Log.ok(String(format: "Model ready in %.1f s (includes download + Core ML specialization on first run)", loadSec))

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = lang
        options.detectLanguage = (lang == nil)
        options.usePrefillPrompt = (lang != nil)
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.temperature = 0
        if vad { options.chunkingStrategy = .vad }

        var failed = false
        for url in urls {
            let audioSec = audioDuration(url)
            Log.header("transcribe \(url.lastPathComponent)  (\(String(format: "%.1f", audioSec)) s audio)")
            let t1 = Date()
            do {
                let results = try await whisper.transcribe(audioPath: url.path, decodeOptions: options)
                let secs = Date().timeIntervalSince(t1)
                let rtf = audioSec > 0 ? secs / audioSec : 0
                let detected = results.first?.language ?? "?"
                var lines: [String] = []
                for r in results {
                    for seg in r.segments {
                        let text = seg.text.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }
                        lines.append(String(format: "[%@ → %@] %@", ts(Double(seg.start)), ts(Double(seg.end)), text))
                    }
                }
                lines.forEach { print("   \($0)") }
                Log.ok(String(format: "%.1f s audio in %.1f s → RTF %.3f (%.0f× real time), language=%@, peak RSS %.0f MB",
                              audioSec, secs, rtf, rtf > 0 ? 1 / rtf : 0, detected, peakRSSMB()))

                let base = url.deletingPathExtension().lastPathComponent
                let txt = outDir.appendingPathComponent("transcript-\(base)-\(model).txt")
                try? (lines.joined(separator: "\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
                appendBench(outDir, [iso(), url.lastPathComponent, model, lang ?? "auto", detected, vad ? "vad" : "novad",
                                     String(format: "%.2f", audioSec), String(format: "%.2f", secs), String(format: "%.4f", rtf),
                                     String(format: "%.1f", loadSec), String(format: "%.0f", peakRSSMB()), String(lines.count)])
                Log.line("Transcript: \(txt.path)")
            } catch {
                Log.error("Transcription failed: \(error)"); failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func ts(_ s: Double) -> String { String(format: "%02d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
    private static func iso() -> String { ISO8601DateFormatter().string(from: Date()) }

    private static func audioDuration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    private static func peakRSSMB() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576   // bytes on macOS
    }

    private static func appendBench(_ dir: URL, _ cols: [String]) {
        let url = dir.appendingPathComponent("stt-bench.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "timestamp,file,model,lang_option,detected_lang,chunking,audio_s,transcribe_s,rtf,model_load_s,peak_rss_mb,segments\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data((cols.joined(separator: ",") + "\n").utf8)); try? h.close()
        }
    }
}

