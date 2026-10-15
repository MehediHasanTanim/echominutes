import EMCore
import Foundation
@preconcurrency import WhisperKit

/// Local Whisper via WhisperKit / Core ML (EM-084). One instance per model variant; the job queue runs at most one
/// transcription at a time, the lock only guards the lazily-loaded pipeline.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    public let variant: String
    private let models: STTModelManager
    private let lock = NSLock()
    private var kit: WhisperKit?

    public init(variant: String, models: STTModelManager) {
        self.variant = variant
        self.models = models
    }

    public var identifier: String { "whisperkit:\(variant)" }

    private var loaded: WhisperKit? { lock.withLock { kit } }

    public func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws {
        if loaded != nil { status(.ready); return }
        if !models.isInstalled(variant) {
            status(.downloading(fraction: 0))
            do { try await models.download(variant) { status(.downloading(fraction: $0)) } }
            catch { throw TranscriptionError.modelUnavailable("download failed: \(error.localizedDescription)") }
        }
        status(.loading)
        let t0 = Date()
        let config = WhisperKitConfig(model: variant, downloadBase: models.modelsDir,
                                      modelFolder: models.folder(for: variant).path,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        let k: WhisperKit
        do { k = try await WhisperKit(config) }
        catch { throw TranscriptionError.modelUnavailable("load failed: \(error.localizedDescription)") }
        lock.withLock { kit = k }
        Log.info(.stt, String(format: "Model %@ loaded in %.1f s", variant, Date().timeIntervalSince(t0)))
        status(.ready)
    }

    public func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        guard let kit = loaded else { throw TranscriptionError.modelUnavailable("not loaded") }
        guard !samples.isEmpty else { return [] }

        var opts = DecodingOptions(verbose: false, task: .transcribe, language: options.language, temperature: 0,
                                   usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
                                   withoutTimestamps: false, chunkingStrategy: nil)
        if !options.vocabulary.isEmpty, let tok = kit.tokenizer {
            let prompt = " " + options.vocabulary.joined(separator: ", ") + "."
            opts.promptTokens = tok.encode(text: prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
        }

        let totalSeconds = Double(samples.count) / AudioLoader.sampleRate
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: opts) { _ in
            // Window progress: last decoded timestamp is not exposed directly; use WhisperKit's Progress.
            progress(min(1, max(0, kit.progress.fractionCompleted)))
            return Task.isCancelled ? false : nil
        }
        if Task.isCancelled { throw TranscriptionError.cancelled }
        progress(1)

        return results.flatMap(\.segments).map { s in
            RawSegment(start: Double(s.start), end: min(Double(s.end), totalSeconds), text: s.text,
                       avgLogprob: Double(s.avgLogprob), noSpeechProb: Double(s.noSpeechProb),
                       compressionRatio: Double(s.compressionRatio), temperature: Double(s.temperature))
        }
    }

    public func unload() async {
        let k = lock.withLock { () -> WhisperKit? in let k = kit; kit = nil; return k }
        await k?.unloadModels()
    }
}
