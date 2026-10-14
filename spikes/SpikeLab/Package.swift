// swift-tools-version: 6.0
// SpikeLab — throwaway experiment app for Sprint 0/1 spikes (NOT production code).
import PackageDescription

let package = Package(
    name: "SpikeLab",
    platforms: [.macOS("14.4")],
    dependencies: [
        // EM-011: local speech-to-text (Core ML Whisper)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMajor(from: "0.9.0")),
    ],
    targets: [
        // Tiny Objective-C shim: builds CATapDescription from NSNumber process IDs
        // (avoids depending on how the Swift overlay types the initializer).
        .target(
            name: "TapShim",
            path: "Sources/TapShim",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(
            name: "SpikeLab",
            dependencies: ["TapShim", .product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/SpikeLab",
            swiftSettings: [.swiftLanguageMode(.v5)]   // spike code: keep concurrency checking relaxed
        ),
    ]
)
