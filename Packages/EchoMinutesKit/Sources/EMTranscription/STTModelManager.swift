import EMCore
import Foundation
@preconcurrency import WhisperKit

/// Known WhisperKit models (Technical Design §9.2). Sizes are approximate download sizes.
public enum STTModelCatalog {
    public struct Entry: Sendable, Identifiable, Equatable {
        public let variant: String
        public let title: String
        public let sizeMB: Int
        public let note: String
        public var id: String { variant }
    }
    public static let defaultVariant = "large-v3-v20240930_turbo"
    public static let all: [Entry] = [
        Entry(variant: "large-v3-v20240930_turbo", title: "Large v3 Turbo (recommended)", sizeMB: 1600, note: "Best quality/speed balance; ~7× real time on M-series"),
        Entry(variant: "large-v3", title: "Large v3", sizeMB: 3100, note: "Most accurate, slowest"),
        Entry(variant: "small", title: "Small", sizeMB: 480, note: "Fast; weaker on accents and Bengali"),
        Entry(variant: "base", title: "Base", sizeMB: 145, note: "Fastest; for quick tests only"),
    ]
    public static func entry(_ variant: String) -> Entry? { all.first { $0.variant == variant } }
}

/// Download-on-first-use model storage in `<library>/Models` (EM-083). WhisperKit's downloader keeps its
/// Hugging Face layout: `Models/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>/`.
public struct STTModelManager: Sendable {
    public static let repo = "argmaxinc/whisperkit-coreml"
    public let modelsDir: URL

    public init(modelsDir: URL) { self.modelsDir = modelsDir }

    var repoDir: URL { modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true) }

    public func folder(for variant: String) -> URL {
        repoDir.appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    /// Installed = the three Core ML models are present.
    public func isInstalled(_ variant: String) -> Bool {
        let f = folder(for: variant)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: f.appendingPathComponent($0).path)
        }
    }

    public struct Installed: Sendable, Equatable, Identifiable {
        public let variant: String
        public let bytes: Int64
        public var id: String { variant }
    }

    public func installed() -> [Installed] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) else { return [] }
        return names.filter { $0.hasPrefix("openai_whisper-") }.map { String($0.dropFirst("openai_whisper-".count)) }
            .filter(isInstalled).sorted()
            .map { Installed(variant: $0, bytes: Self.size(of: folder(for: $0))) }
    }

    /// Downloads (or resumes) a model. `progress` gets 0…1.
    @discardableResult
    public func download(_ variant: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        Log.info(.stt, "Downloading model \(variant)…")
        let url = try await WhisperKit.download(variant: variant, downloadBase: modelsDir, from: Self.repo) { p in
            progress(p.fractionCompleted)
        }
        Log.info(.stt, "Model \(variant) downloaded to \(url.path)")
        return url
    }

    public func delete(_ variant: String) throws {
        try FileManager.default.removeItem(at: folder(for: variant))
        Log.info(.stt, "Deleted model \(variant)")
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
