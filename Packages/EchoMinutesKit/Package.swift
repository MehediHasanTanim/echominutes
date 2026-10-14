// swift-tools-version: 6.0
// EchoMinutesKit — all EchoMinutes modules (Technical Design §4). Swift 6 language mode.
import PackageDescription

let modules: [(name: String, deps: [String])] = [
    ("EMCore", []),
    ("EMStorage", ["EMCore"]),
    ("EMDetection", ["EMCore"]),
    ("EMAudio", ["EMCore"]),
    ("EMSession", ["EMCore", "EMDetection", "EMAudio", "EMStorage"]),
    ("EMTranscription", ["EMCore"]),
    ("EMSummarization", ["EMCore"]),
    ("EMJobs", ["EMCore", "EMStorage"]),
    ("EMExport", ["EMCore"]),
    ("EMUI", ["EMCore"]),
]

let package = Package(
    name: "EchoMinutesKit",
    platforms: [.macOS("14.4")],
    products: modules.map { .library(name: $0.name, targets: [$0.name]) },
    targets: modules.flatMap { m -> [Target] in
        [
            .target(name: m.name, dependencies: m.deps.map { .target(name: $0) }),
            .testTarget(name: "\(m.name)Tests", dependencies: [.target(name: m.name)]),
        ]
    }
)
