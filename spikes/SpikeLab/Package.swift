// swift-tools-version: 6.0
// SpikeLab — throwaway experiment app for Sprint 0/1 spikes (NOT production code).
import PackageDescription

let package = Package(
    name: "SpikeLab",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "SpikeLab",
            path: "Sources/SpikeLab",
            swiftSettings: [.swiftLanguageMode(.v5)]   // spike code: keep concurrency checking relaxed
        )
    ]
)
