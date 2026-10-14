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

    public static func decode(_ data: Data) throws -> DetectionRules { try JSONDecoder().decode(DetectionRules.self, from: data) }

    /// The watched app for an audio-process bundle ID, unless it is on the ignore list.
    public func app(forBundleID bundleID: String) -> App? {
        guard !ignoreBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) else { return nil }
        return apps.first { $0.matches(bundleID: bundleID) }
    }
}
