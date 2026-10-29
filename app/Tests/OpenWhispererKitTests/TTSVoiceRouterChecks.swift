import Foundation
import OpenWhispererKit

func ttsVoiceRouterFailures() -> [String] {
    var failures: [String] = []

    func expect(_ id: String, _ engine: TTSEngineKind, _ voice: String, _ language: String?, _ label: String) {
        let route = TTSVoiceRouter.route(id)
        if route.engine != engine || route.voice != voice || route.language != language {
            failures.append(
                "TTSVoiceRouter.route(\"\(id)\") [\(label)]: expected "
                    + "(\(engine), \(voice), \(language ?? "nil")), got "
                    + "(\(route.engine), \(route.voice), \(route.language ?? "nil"))")
        }
    }

    // Bare ids stay on Kokoro verbatim — every existing tts_voice pref keeps working with no
    // migration, which is the whole reason Supertonic ids carry an explicit prefix.
    expect("af_heart", .kokoro, "af_heart", nil, "kokoro default")
    expect("bf_emma", .kokoro, "bf_emma", nil, "kokoro uk")
    expect("zm_yunyang", .kokoro, "zm_yunyang", nil, "kokoro mandarin stays kokoro")

    // Well-formed Supertonic ids.
    expect("supertonic:nl:F1", .supertonic, "F1", "nl", "dutch female")
    expect("supertonic:uk:M5", .supertonic, "M5", "uk", "ukrainian male")

    // Case is normalized on both axes so a hand-edited pref or per-project override still routes.
    expect("supertonic:NL:f1", .supertonic, "F1", "nl", "uppercase language")
    expect("SUPERTONIC:de:m2", .supertonic, "M2", "de", "uppercase prefix")

    // Whitespace is trimmed — the pref files are written with trailing newlines.
    expect("  supertonic:pl:F3  \n", .supertonic, "F3", "pl", "surrounding whitespace")

    // Unknown or missing style clamps to F1 rather than failing the turn's audio.
    expect("supertonic:nl:Q9", .supertonic, "F1", "nl", "unknown style clamps")
    expect("supertonic:nl", .supertonic, "F1", "nl", "missing style clamps")
    expect("supertonic:nl:", .supertonic, "F1", "nl", "empty style clamps")

    // An unsupported language can't be guessed at, so it falls back to the default Kokoro voice.
    // `zh` specifically: Supertonic was not trained on Mandarin, so it must NOT claim it.
    expect("supertonic:zh:F1", .kokoro, "af_heart", nil, "mandarin unsupported by supertonic")
    expect("supertonic:xx:F1", .kokoro, "af_heart", nil, "nonsense language")
    expect("supertonic:", .kokoro, "af_heart", nil, "prefix only")
    // Unset means the default: Heart on Pocket TTS (owner, 2026-10-29).
    expect("", .pocket, "heart", nil, "empty id is the default")
    expect("   ", .pocket, "heart", nil, "whitespace only is the default")
    // Pocket ids: a known name routes to Pocket (case-insensitive); an unknown one can't be
    // spoken by it, so Kokoro's af_heart — Heart's own original — takes it.
    expect("pocket:heart", .pocket, "heart", nil, "pocket heart")
    expect("POCKET:Jane", .pocket, "jane", nil, "pocket case")
    expect("pocket:nobody", .kokoro, "af_heart", nil, "unknown pocket voice")
    expect("pocket:", .kokoro, "af_heart", nil, "pocket prefix only")
    if TTSVoiceRouter.defaultVoice != "pocket:heart" { failures.append("TTSVoiceRouter.defaultVoice: expected pocket:heart") }
    if !TTSVoiceRouter.isPocket("") || TTSVoiceRouter.isPocket("af_heart") { failures.append("TTSVoiceRouter.isPocket") }

    // isSupertonic must agree with route() — call sites rely on the shortcut.
    for id in ["supertonic:nl:F1", "af_heart", "supertonic:zh:F1", ""] {
        if TTSVoiceRouter.isSupertonic(id) != (TTSVoiceRouter.route(id).engine == .supertonic) {
            failures.append("TTSVoiceRouter.isSupertonic(\"\(id)\") disagrees with route()")
        }
    }

    // supertonicID must produce ids route() accepts — the registry builds every multilingual
    // entry through it, so drift here would break the whole picker at once.
    for language in TTSVoiceRouter.supertonicLanguages {
        for style in TTSVoiceRouter.supertonicStyles {
            let id = TTSVoiceRouter.supertonicID(language: language, style: style)
            let route = TTSVoiceRouter.route(id)
            if route.engine != .supertonic || route.language != language || route.voice != style {
                failures.append("TTSVoiceRouter.supertonicID round-trip failed for \(id)")
            }
        }
    }

    // Mandarin is Kokoro's alone; Supertonic's roster must not list it.
    if TTSVoiceRouter.supertonicLanguages.contains("zh") {
        failures.append("TTSVoiceRouter.supertonicLanguages must not contain 'zh' (not trained)")
    }
    // 31 = Supertonic3Constants.availableLanguages (32) minus the "na" language-agnostic entry.
    // Assert the specific tail codes too: a bare count let `vi` go missing once already, which
    // silently degraded Vietnamese to an English voice — the exact bug this feature fixes.
    if TTSVoiceRouter.supertonicLanguages.count != 31 {
        failures.append(
            "TTSVoiceRouter.supertonicLanguages: expected 31 codes, got "
                + "\(TTSVoiceRouter.supertonicLanguages.count)")
    }
    for code in ["vi", "uk", "tr", "sv", "en", "nl"] where !TTSVoiceRouter.supertonicLanguages.contains(code) {
        failures.append("TTSVoiceRouter.supertonicLanguages: missing '\(code)'")
    }
    if TTSVoiceRouter.supertonicLanguages.contains("na") {
        failures.append("TTSVoiceRouter.supertonicLanguages must not contain 'na' (not a language)")
    }
    if TTSVoiceRouter.supertonicStyles.count != 10 {
        failures.append("TTSVoiceRouter.supertonicStyles: expected 10 styles")
    }

    return failures
}
