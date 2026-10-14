// swift-tools-version: 6.0
// SpikeLab — throwaway experiment app for Sprint 0/1 spikes (NOT production code).
import PackageDescription

let package = Package(
    name: "SpikeLab",
    platforms: [.macOS("14.4")],
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
            dependencies: ["TapShim"],
            path: "Sources/SpikeLab",
            swiftSettings: [.swiftLanguageMode(.v5)]   // spike code: keep concurrency checking relaxed
        ),
    ]
)
