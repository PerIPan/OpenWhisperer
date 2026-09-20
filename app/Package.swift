// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWhisperer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // STT: WhisperKit (CoreML / ANE). Restored 2026-07-30 at the owner's request,
        // reversing the 2026-07-13 migration to Parakeet.
        //
        // Un-forked 2026-09-02: argmaxinc shipped the fix, which was the one condition the
        // fork pin was waiting on.
        //
        // The bug: with `promptTokens` set, the decode loop force-feeds the prompt and the
        // completion check still honored an EOT sampled mid-prefill. large-v3 turbo predicts
        // <|endoftext|> there deterministically, so ANY non-empty stt_vocabulary made every
        // dictation return an EMPTY transcript — recording ran, nothing was typed. That is
        // why this was pinned to a fork of v1.0.0 carrying a one-line `!isPrefill` gate.
        //
        // Upstream PR #514 ("Fix empty transcription when promptTokens are set", co-authored
        // by the same person who wrote the fork patch) fixes it more thoroughly — a logits
        // filter plus a prefill rework, with ~200 lines of new unit tests — and shipped in
        // v1.1.0 (2026-08-06). Verified #514 is an ancestor of that tag before switching.
        //
        // Do NOT go back to hakanensari/WhisperKit's `main`: it is *diverged*, missing both
        // v1.0.0 and the EOT fix, so it is a downgrade, not an upgrade. The fork itself stays
        // reachable, but nothing here needs it any more.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        // TTS: native in-process Kokoro (CoreML / ANE). Apache-2.0. macOS 14+. No metallib.
        // Release 0.15.5+ contains the #730 fix ("Fix KokoroAne strided MLMultiArray handling")
        // which resolves issue #727 where 0.15.4 mis-read a *strided* MLMultiArray the Kokoro
        // chain returned on some Apple Silicon (e.g. M3/macOS 15), yielding fluent-but-WRONG words.
        // Release 0.15.6 adds #783: smart apostrophes (U+2019/U+2018/U+02BC) are folded to ASCII
        // before tokenizing, so "I’ll" no longer splits into "I" + "ll" and gets read as "I L".
        //
        // PINNED EXACTLY, not `from:` — upgrade deliberately, after measuring. 0.15.6 was
        // versioned as a patch but carried ~60 PRs and a new `binaryTarget`:
        // `NemoTextProcessing.xcframework`, a 56 MB static Rust library
        // (`FluidInference/text-processing-rs`, a Rust port of NVIDIA NeMo text normalization).
        // It added +9.1 MB to our binary — `__TEXT/__const` went 118 KB → 7.34 MB of compiled
        // FST grammars, and 0 → 1096 Rust-mangled symbols — taking the DMG from 5.4 to 12.7 MB.
        // We keep it because reverting would also drop upstream #816 (KokoroAne trapping on
        // non-finite PostAlbert durations — a hard crash on our path) and #792/#810 (model-cache
        // preservation and a stall watchdog on transient network errors, which matter behind a
        // firewall that blocks the Xet CDN). It does almost nothing for us either way:
        // `KokoroTTS.synthesize` runs `NumberNormalizer` first, so the digits are already words
        // before the FST sees them. On the next bump, diff `size -m` on the built binary.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"),
    ],
    targets: [
        // Pure, dependency-free logic that is unit-tested in isolation
        // (no AppKit / AVFoundation / FluidAudio), so it builds and runs fast.
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
