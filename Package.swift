// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path to the package directory. The vendored whisper.cpp/opus headers
// and static libs live under `vendor/` and are referenced below by absolute
// path. Relative `-I../../vendor` / `-Ivendor` flags resolve against the
// compiler's working directory, which the classic SwiftPM build system set to
// the package root but Xcode 26+'s build system sets to the parent directory —
// so the COpus/CWhisper modules failed to find their headers. Absolute paths
// build under both.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorDir = "\(packageDir)/vendor"

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
                .unsafeFlags([
                    "-I\(vendorDir)/whisper.cpp/include",
                    "-I\(vendorDir)/whisper.cpp/ggml/include",
                ]),
            ]
        ),
        // transcribe.cpp (GigaAM): a dylib with its ggml hidden inside, so it
        // cannot collide with whisper.cpp's static ggml.
        .target(
            name: "CTranscribe",
            path: "Sources/CTranscribe",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(vendorDir)/transcribe.cpp/include"]),
            ]
        ),
        .target(
            name: "COpus",
            path: "Sources/COpus",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I\(vendorDir)/opus-build/macos-universal/include",
                    "-I\(vendorDir)/opus-build/macos-universal/include/opus",
                ]),
            ]
        ),
        .executableTarget(
            name: "Corvin",
            dependencies: [
                "CWhisper",
                "CTranscribe",
                "COpus",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: ".",
            exclude: [
                "vendor", "build", "scripts", "docs", "logo",
                "Sources/CWhisper", "Sources/CTranscribe",
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
                    "-Xcc", "-I\(vendorDir)/whisper.cpp/include",
                    "-Xcc", "-I\(vendorDir)/whisper.cpp/ggml/include",
                    "-Xcc", "-I\(vendorDir)/transcribe.cpp/include",
                    "-Xcc", "-I\(vendorDir)/opus-build/macos-universal/include",
                    "-Xcc", "-I\(vendorDir)/opus-build/macos-universal/include/opus",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorDir)/whisper.cpp/build-universal",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                    // Copied into Contents/Frameworks by build-dmg.sh, found
                    // through the rpath below.
                    "-L\(vendorDir)/transcribe.cpp/build-universal",
                    "-ltranscribe",
                    // Development runs (`swift build`, `swift test`) load the
                    // dylib where it was built; build-dmg.sh deletes this rpath.
                    "-Xlinker", "-rpath", "-Xlinker", "\(vendorDir)/transcribe.cpp/build-universal",
                    "-L\(vendorDir)/opus-build/macos-universal/lib",
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
                    "-Xcc", "-I\(vendorDir)/whisper.cpp/include",
                    "-Xcc", "-I\(vendorDir)/whisper.cpp/ggml/include",
                    "-Xcc", "-I\(vendorDir)/transcribe.cpp/include",
                    "-Xcc", "-I\(vendorDir)/opus-build/macos-universal/include",
                    "-Xcc", "-I\(vendorDir)/opus-build/macos-universal/include/opus",
                ])
            ]
        ),
    ]
)
