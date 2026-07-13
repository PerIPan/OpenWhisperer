import Foundation

/// Plain-executable test runner for OpenWhispererKit (CLT has no XCTest/Testing module).
/// Aggregates every check-group's failures and exits non-zero if any fail.
@main
struct KitTestRunner {
    static func main() {
        var failures: [String] = []
        failures += submitTriggerFailures()
        failures += pcmConversionFailures()
        failures += voiceSignalFailures()
        failures += voiceMigrationFailures()
        failures += numberNormalizerFailures()
        failures += sentenceSplitterFailures()
        failures += appFilterFailures()
        failures += focusTargetFailures()
        failures += mcpServerFailures()
        failures += ttsSpeedFailures()
        failures += ttsVolumeFailures()
        failures += ttsVoiceRegistryFailures()
        failures += transcriptHistoryBufferFailures()
        failures += notchGeometryFailures()

        if failures.isEmpty {
            print("✅ OpenWhispererKit: all checks passed")
        } else {
            for f in failures {
                FileHandle.standardError.write(Data(("❌ " + f + "\n").utf8))
            }
            FileHandle.standardError.write(Data("\n\(failures.count) check(s) failed\n".utf8))
            exit(1)
        }
    }
}
