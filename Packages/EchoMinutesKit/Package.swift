// swift-tools-version: 6.0
// EchoMinutesKit — all EchoMinutes modules (Technical Design §4). Swift 6 language mode.
import PackageDescription

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

/// (module, internal deps, external deps)
let modules: [(name: String, deps: [String], external: [Target.Dependency])] = [
    ("EMCore", [], []),
    ("EMStorage", ["EMCore"], [grdb]),
    ("EMDetection", ["EMCore"], []),
    ("EMAudio", ["EMCore"], []),
    ("EMSession", ["EMCore", "EMDetection", "EMAudio", "EMStorage"], []),
    ("EMTranscription", ["EMCore"], []),
    ("EMSummarization", ["EMCore"], []),
    ("EMJobs", ["EMCore", "EMStorage"], []),
    ("EMExport", ["EMCore"], []),
    ("EMUI", ["EMCore"], []),
]

let package = Package(
    name: "EchoMinutesKit",
    platforms: [.macOS("14.4")],
    products: modules.map { .library(name: $0.name, targets: [$0.name]) },
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: modules.flatMap { m -> [Target] in
        [
            .target(name: m.name, dependencies: m.deps.map { .target(name: $0) } + m.external),
            .testTarget(name: "\(m.name)Tests", dependencies: [.target(name: m.name)] + m.external),
        ]
    }
)
