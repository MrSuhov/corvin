// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Corvin",
    defaultLocalization: "en",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "Corvin", targets: ["Corvin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../vendor/whisper.cpp/include"),
                .headerSearchPath("../../vendor/whisper.cpp/ggml/include"),
            ]
        ),
        .target(
            name: "COpus",
            path: "Sources/COpus",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../vendor/opus-build/macos-universal/include"),
                .headerSearchPath("../../vendor/opus-build/macos-universal/include/opus"),
            ]
        ),
        .executableTarget(
            name: "Corvin",
            dependencies: [
                "CWhisper",
                "COpus",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: ".",
            exclude: [
                "vendor", "build", "scripts", "docs", "logo",
                "Sources/CWhisper",
                "iOS",  "CorvinKeyboard", "Tests",
                "macOS/Bridge/README.md", "macOS/Bridge/whisper-bridge.h",
                "macOS/Resources",
            ],
            sources: [
                "Shared/Core",
                "Shared/Networking",
                "Shared/UI",
                "macOS/App",
                "macOS/Services",
                "macOS/UI",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I../../vendor/whisper.cpp/include",
                    "-Xcc", "-I../../vendor/whisper.cpp/ggml/include",
                    "-Xcc", "-Ivendor/opus-build/macos-universal/include",
                    "-Xcc", "-Ivendor/opus-build/macos-universal/include/opus",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Lvendor/whisper.cpp/build-universal",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                    "-Lvendor/opus-build/macos-universal/lib",
                    "-lopusfile",
                    "-lopus",
                    "-logg",
                    // Let the executable find the embedded Sparkle.framework that
                    // build-dmg.sh copies into Corvin.app/Contents/Frameworks.
                    // Must go through -Xlinker: the Swift driver rejects a bare
                    // -rpath ("error: unknown argument").
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // Call recording on macOS 13–14.1. Weak, because Corvin
                    // still launches on 11 where the framework does not exist.
                    "-Xlinker", "-weak_framework", "-Xlinker", "ScreenCaptureKit",
                ]),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreData"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Pure logic of call recording and its file format; no model, no audio
        // devices. `swift test`.
        .testTarget(
            name: "CorvinTests",
            dependencies: ["Corvin"],
            path: "Tests/CorvinTests",
            // Importing Corvin pulls in the CWhisper and COpus modules, whose
            // headers only the app target's own -Xcc flags point at.
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-Ivendor/whisper.cpp/include",
                    "-Xcc", "-Ivendor/whisper.cpp/ggml/include",
                    "-Xcc", "-Ivendor/opus-build/macos-universal/include",
                    "-Xcc", "-Ivendor/opus-build/macos-universal/include/opus",
                ])
            ]
        ),
    ]
)
