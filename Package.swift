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
                    "-rpath", "@executable_path/../Frameworks",
                ]),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreData"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
