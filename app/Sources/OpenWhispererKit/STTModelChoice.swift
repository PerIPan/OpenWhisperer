import Foundation

/// Which Whisper checkpoint dictation loads, and why the app needs two of them.
///
/// **The default turbo checkpoint cannot translate.** OpenAI's `large-v3-turbo` fine-tune
/// deliberately excluded translation data, so `DecodingOptions.task = .translate` returns
/// byte-identical *source-language* text rather than English. Measured on hardware
/// 2026-09-29 — Spanish in, the same Spanish out, no error, no warning. The `<|translate|>`
/// token exists in its vocabulary; only the training is missing. So "Translate to English"
/// swaps the active model to a non-turbo build, which is ~2.4x slower to decode but does
/// translate. See `docs/superpowers/specs/2026-09-29-translate-to-english-design.md`.
///
/// Only ONE is ever resident: the app's model-status surfaces (`sttModelReady`, the menubar
/// hourglass, the overlay headline, Diagnostics) are all single-valued, and holding two
/// models would make every one of them misreport. Swapping costs ~1.7 s once both are
/// ANE-compiled.
public enum STTModelChoice: String, Sendable, Equatable, CaseIterable {
    /// large-v3 **turbo** — 4 decoder layers, ~0.8 s per clip. Cannot translate.
    case fast
    /// large-v3, quantized — 32 decoder layers, ~2.0 s per clip. Translates X→English.
    case translating

    /// WhisperKit variant id, as published under `argmaxinc/whisperkit-coreml`.
    ///
    /// **Both MUST stay in the large-v3 family.** `SpeechTranscriber.loadWhisperKit` hardcodes
    /// `tokenizerFolder` to `openai/whisper-large-v3`, and WhisperKit takes the first folder
    /// holding a `tokenizer.json` rather than consulting `tokenizerNameForVariant`. large-v3's
    /// vocabulary added `<|yue|>` = 50358, shifting every later special token: `<|translate|>`
    /// = 50359, `<|transcribe|>` = 50360. In a *non*-v3 vocabulary id 50359 IS `<|transcribe|>`,
    /// so prefill would request translate, the decoder would hear transcribe, and the output
    /// would be untranslated source text — silently reproducing the very bug this enum exists
    /// to fix, with nothing thrown (`download: false` never validates the tokenizer).
    /// Introducing e.g. `openai_whisper-small` requires making `tokenizerFolder` model-derived
    /// FIRST.
    public var modelName: String {
        switch self {
        case .fast: return "openai_whisper-large-v3-v20240930_turbo"
        case .translating: return "openai_whisper-large-v3_947MB"
        }
    }

    /// Shown in Settings → Advanced and the General tab's engine row. Kept short; the raw
    /// variant id is unreadable.
    public var displayName: String {
        switch self {
        case .fast: return "WhisperKit large-v3 turbo"
        case .translating: return "WhisperKit large-v3 (translating)"
        }
    }

    /// Approximate download size, for the consent prompt. Measured from the published repo
    /// 2026-09-29; used only in user-facing copy, never in logic.
    public var approximateDownloadMB: Int {
        switch self {
        case .fast: return 1500
        case .translating: return 948
        }
    }

    /// Human-readable download size for status copy ("about 1.5 GB"). Derived from
    /// `approximateDownloadMB` so the figure can never drift from it — the old copy
    /// hardcoded "~1.5 GB" in several places and was already wrong for a second model.
    public var approximateDownloadDescription: String {
        let mb = approximateDownloadMB
        if mb >= 1000 {
            let gb = Double(mb) / 1000.0
            return "about \(String(format: "%.1f", gb)) GB"
        }
        return "about \(mb) MB"
    }

    /// Whether `DecodingOptions.task = .translate` actually does anything on this checkpoint.
    public var canTranslate: Bool { self == .translating }

    /// The model the `stt_translate` pref selects. The single place that mapping lives.
    public static func forTranslate(_ translate: Bool) -> STTModelChoice {
        translate ? .translating : .fast
    }

    /// The model the app loads when nothing is stored.
    public static let `default`: STTModelChoice = .fast
}
