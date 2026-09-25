// swift-tools-version: 6.2
import PackageDescription

// Built separately from Corvin (macOS 11): FluidAudio needs macOS 14. See
// Sources/corvin-diarize/main.swift for why this is a process.
let package = Package(
    name: "CorvinDiarizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "corvin-diarize", targets: ["corvin-diarize"]),
    ],
    dependencies: [
        // traits: [] drops the NeMo text-normalization engine (~8 MB per slice),
        // which diarization never uses.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.4", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "corvin-diarize",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
