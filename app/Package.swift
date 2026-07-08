// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWhisperer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native in-process Whisper STT (CoreML / ANE). MIT. macOS 14+.
        // v1.5: floor `0.9.0` → `1.0.0` (resolved 0.18.0 → 1.0.0, the stable milestone).
        // Pinned to a fork = v1.0.0 + one fix: upstream's decode loop aborts on an
        // EOT sampled during the forced promptTokens prefill, so ANY non-empty
        // stt_vocabulary made every dictation come back empty (bug present on
        // upstream main as of 2026-07-08; drop the pin once fixed upstream).
        .package(url: "https://github.com/hakanensari/WhisperKit.git", revision: "a1eb2f0183bb87ef1582a4e1c9325d2d71578ed0"),
        // Native in-process Kokoro TTS (CoreML / ANE). Apache-2.0. macOS 14+. No metallib.
        // Release 0.15.5+ contains the #730 fix ("Fix KokoroAne strided MLMultiArray handling")
        // which resolves issue #727 where 0.15.4 mis-read a *strided* MLMultiArray the Kokoro
        // chain returned on some Apple Silicon (e.g. M3/macOS 15), yielding fluent-but-WRONG words.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.15.5"),
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
