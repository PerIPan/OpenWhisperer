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
        failures += ttsVoiceRouterFailures()
        failures += voicePersonaFailures()
        failures += firstRunPaneFailures()
        failures += owThemeFailures()
        failures += transcriptHistoryBufferFailures()
        failures += spectrumBandsFailures()
        failures += dotMatrixFailures()
        failures += overlayStyleFailures()
        failures += diagLogTrimFailures()
        failures += axInsertionCheckFailures()
        failures += peakHoldFailures()
        failures += overlaySizeFailures()
        failures += vocabularyCorrectorFailures()
        failures += vocabularyPromptFailures()
        failures += disfluencyFilterFailures()
        failures += sttLanguageFailures()
        failures += pickerSearchFailures()
        failures += ttsSampleTextFailures()
        failures += hooksJSONFailures()
        failures += codexConfigTOMLFailures()

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
