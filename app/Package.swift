// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWhisperer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native in-process Whisper STT (CoreML / ANE). MIT. macOS 14+.
        // v1.5: floor `0.9.0` → `1.0.0` (resolved 0.18.0 → 1.0.0, the stable milestone). The
        // transcribe/config APIs we use are unchanged; 1.0.0's breaking changes were to
        // deprecated APIs we don't call. To revert: set the floor back AND re-resolve
        // (`swift package resolve`) — Package.resolved is pinned, so editing this line alone
        // won't downgrade.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // Native in-process Kokoro TTS (CoreML / ANE). Apache-2.0. macOS 14+. No metallib.
        // Pinned PAST the 0.15.4 release to the #730 fix ("Fix KokoroAne strided MLMultiArray
        // handling") — 0.15.4 mis-reads a *strided* MLMultiArray the Kokoro chain returns on some
        // Apple Silicon (e.g. M3/macOS 15), yielding fluent-but-WRONG words (issue #727). Code-only
        // fix; existing model assets are unchanged. Revisit when a release ≥ this lands.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "313feb4bd692780a9a5b5fa9048fdb119486dde8"),
    ],
    targets: [
        // Pure, dependency-free logic that is unit-tested in isolation
        // (no AppKit / AVFoundation / WhisperKit), so it builds and runs fast.
        .target(
            name: "OpenWhispererKit",
            path: "Sources/OpenWhispererKit"
        ),
        .executableTarget(
            name: "OpenWhisperer",
            dependencies: [
                "OpenWhispererKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/OpenWhisperer"
        ),
        // Test harness as a plain executable: this machine has Command Line Tools
        // only (no XCTest / swift-testing module). Run with: `swift run OpenWhispererKitTests`
        // (exits non-zero on any failure). Swap for an XCTest target once full Xcode is installed.
        .executableTarget(
            name: "OpenWhispererKitTests",
            dependencies: ["OpenWhispererKit"],
            path: "Tests/OpenWhispererKitTests"
        ),
        // Integration tests for the bash hooks (UserPromptSubmit for Claude/Codex,
        // PreInvocation for Antigravity CLI). Shells out to ../../hooks/*.sh in an isolated
        // temp HOME with a stubbed curl — the Swift port of the deleted pytest suite.
        // Run with: `swift run HookTests`.
        .executableTarget(
            name: "HookTests",
            dependencies: ["OpenWhispererKit"],
            path: "Tests/HookTests"
        ),
    ]
)
