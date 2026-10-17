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
    /// A web browser whose audio processes can carry a web meeting (EM-153).
    public struct Browser: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var bundlePrefixes: [String]
        public var notes: String?

        public init(id: String, name: String, bundlePrefixes: [String], notes: String? = nil) {
            self.id = id; self.name = name; self.bundlePrefixes = bundlePrefixes; self.notes = notes
        }

        public func matches(bundleID: String) -> Bool { bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }

    /// A meeting web app recognised by the browser window title (EM-153), e.g. Google Meet.
    public struct WebMeeting: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// Regular expressions (case-insensitive) matched against browser window titles.
        public var titlePatterns: [String]
        /// Removed from the window title to get a session title (browser suffixes are removed anyway).
        public var stripPatterns: [String]?
        public var debounceSec: Double
        public var graceSec: Double

        public init(id: String, name: String, titlePatterns: [String], stripPatterns: [String]? = nil,
                    debounceSec: Double = 5, graceSec: Double = 20) {
            self.id = id; self.name = name; self.titlePatterns = titlePatterns; self.stripPatterns = stripPatterns
            self.debounceSec = debounceSec; self.graceSec = graceSec
        }
    }

    public var version: Int
    public var status: String?
    public var pollIntervalMs: Int
    public var ignoreBundlePrefixes: [String]
    public var apps: [App]
    public var browsers: [Browser]
    /// Meeting web apps detected inside `browsers` (Phase 2). Missing in old rule files.
    public var webMeetings: [WebMeeting]?

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
