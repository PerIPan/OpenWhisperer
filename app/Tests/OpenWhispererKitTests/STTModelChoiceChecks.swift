import OpenWhispererKit

/// Checks for `STTModelChoice` — the two-checkpoint mapping behind "Translate to English".
///
/// The load-bearing assertion is the large-v3 family guard: `SpeechTranscriber` hardcodes the
/// tokenizer folder, so a non-v3 variant would silently decode `<|translate|>` (50359) as
/// `<|transcribe|>` and emit untranslated text — the exact failure the swap exists to fix.
func sttModelChoiceFailures() -> [String] {
    var failures: [String] = []

    // The pref mapping, in both directions.
    if STTModelChoice.forTranslate(false) != .fast {
        failures.append("STTModelChoice.forTranslate(false): expected .fast")
    }
    if STTModelChoice.forTranslate(true) != .translating {
        failures.append("STTModelChoice.forTranslate(true): expected .translating")
    }

    // Only the translating build may claim translation — the whole point of the type.
    if STTModelChoice.fast.canTranslate {
        failures.append("STTModelChoice.fast.canTranslate: turbo cannot translate (measured 2026-09-29)")
    }
    if !STTModelChoice.translating.canTranslate {
        failures.append("STTModelChoice.translating.canTranslate: expected true")
    }

    // The default must be the fast path: translation is opt-in and costs a ~948 MB download.
    if STTModelChoice.default != .fast {
        failures.append("STTModelChoice.default: got \(STTModelChoice.default); expected .fast")
    }

    // GUARD: every variant must be large-v3 family, because loadWhisperKit pins
    // tokenizerFolder to openai/whisper-large-v3. A non-v3 vocabulary shifts the special
    // tokens by one (large-v3 added <|yue|>), so <|translate|> would decode as
    // <|transcribe|> and the model would silently emit untranslated source text.
    for choice in STTModelChoice.allCases where !choice.modelName.contains("large-v3") {
        failures.append("""
            STTModelChoice.\(choice).modelName: "\(choice.modelName)" is not a large-v3 variant. \
            SpeechTranscriber hardcodes tokenizerFolder to openai/whisper-large-v3; a non-v3 \
            vocabulary shifts <|translate|> onto <|transcribe|> and translation silently no-ops. \
            Make tokenizerFolder model-derived before adding this variant.
            """)
    }

    // The two variants must actually differ, or swapping is a no-op that looks like it works.
    if STTModelChoice.fast.modelName == STTModelChoice.translating.modelName {
        failures.append("STTModelChoice: fast and translating resolve to the same model name")
    }

    // Turbo is the one that cannot translate, so it must NOT be the translating variant.
    if STTModelChoice.translating.modelName.contains("turbo") {
        failures.append("""
            STTModelChoice.translating.modelName: "\(STTModelChoice.translating.modelName)" is a \
            turbo build. OpenAI excluded translation data from the turbo fine-tune — measured: \
            task=.translate returns byte-identical source text.
            """)
    }

    // Display names must be distinct and non-empty; they are shown in Advanced + General,
    // where a stale/blank model name has already shipped wrong once (see GeneralTab).
    for choice in STTModelChoice.allCases where choice.displayName.isEmpty {
        failures.append("STTModelChoice.\(choice).displayName: empty")
    }
    if STTModelChoice.fast.displayName == STTModelChoice.translating.displayName {
        failures.append("STTModelChoice: both variants share a displayName")
    }

    // Sanity on the copy figure — it drives a consent prompt asking for ~1 GB of the user's disk.
    for choice in STTModelChoice.allCases where choice.approximateDownloadMB <= 0 {
        failures.append("STTModelChoice.\(choice).approximateDownloadMB: must be positive")
    }

    // The size copy must be derived, not hardcoded — it feeds a consent prompt and the
    // launch status line, and a stale figure has already shipped once in this app.
    if STTModelChoice.translating.approximateDownloadDescription != "about 948 MB" {
        failures.append("""
            STTModelChoice.translating.approximateDownloadDescription: got \
            "\(STTModelChoice.translating.approximateDownloadDescription)"; expected "about 948 MB"
            """)
    }
    if STTModelChoice.fast.approximateDownloadDescription != "about 1.5 GB" {
        failures.append("""
            STTModelChoice.fast.approximateDownloadDescription: got \
            "\(STTModelChoice.fast.approximateDownloadDescription)"; expected "about 1.5 GB"
            """)
    }

    return failures
}
