// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWhisperer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native in-process Whisper STT (CoreML / ANE). MIT. macOS 14+.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
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
    ]
)
