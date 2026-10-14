import Foundation

/// Decoded `Resources/DetectionRules.json` (Technical Design §6.2). Loading/overrides live in EMDetection.
public struct DetectionRules: Codable, Sendable, Equatable {
    public struct App: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var bundlePrefixes: [String]
        public var startSignal: String
        public var debounceSec: Double
        public var graceSec: Double
        public var notes: String?

        public init(id: String, name: String, bundlePrefixes: [String], startSignal: String = "mic",
                    debounceSec: Double = 5, graceSec: Double = 15, notes: String? = nil) {
            self.id = id; self.name = name; self.bundlePrefixes = bundlePrefixes; self.startSignal = startSignal
            self.debounceSec = debounceSec; self.graceSec = graceSec; self.notes = notes
        }

        /// True if an audio-process bundle ID belongs to this app (prefix match covers helpers/extensions).
        public func matches(bundleID: String) -> Bool { bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }
    public struct Browser: Codable, Sendable, Equatable {
        public var bundlePrefixes: [String]
        public var titlePatterns: [String]
        public var notes: String?
    }

    public var version: Int
    public var status: String?
    public var pollIntervalMs: Int
    public var ignoreBundlePrefixes: [String]
    public var apps: [App]
    public var browsers: [Browser]

    /// Rules bundled with the app (`DetectionRules.json` in the main bundle), or nil if missing/invalid.
    public static func bundled(_ bundle: Bundle = .main) -> DetectionRules? {
        guard let url = bundle.url(forResource: "DetectionRules", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    public static func decode(_ data: Data) throws -> DetectionRules { try JSONDecoder().decode(DetectionRules.self, from: data) }

    /// The watched app for an audio-process bundle ID, unless it is on the ignore list.
    public func app(forBundleID bundleID: String) -> App? {
        guard !ignoreBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) else { return nil }
        return apps.first { $0.matches(bundleID: bundleID) }
    }
}
