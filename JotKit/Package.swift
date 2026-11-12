// swift-tools-version: 6.0
import PackageDescription

// JotKit: the transcription pipeline shared by the jot CLI, the Mac worker and (later) the apps.
// No third-party Swift packages. whisper.cpp comes in as a prebuilt XCFramework (the one outside dependency);
// fetch it with `scripts/fetch-whisper.sh` since Frameworks/ is gitignored.
let package = Package(
    name: "JotKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "JotCore", targets: ["JotCore"]),
        .library(name: "JotInbox", targets: ["JotInbox"]),
        .executable(name: "jot", targets: ["jot"]),
    ],
    targets: [
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),
        .target(name: "JotCore", dependencies: ["whisper", "JotInbox"]),
        // Tiny and dependency-free so the share extension can use it without loading whisper.
        .target(name: "JotInbox"),
        .executableTarget(name: "jot", dependencies: ["JotCore"]),
        .testTarget(name: "JotCoreTests", dependencies: ["JotCore"]),
    ]
)
