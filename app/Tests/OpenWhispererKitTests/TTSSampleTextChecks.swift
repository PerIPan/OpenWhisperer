import Foundation
import OpenWhispererKit

/// Guards the preview samples. A test can prove a sample exists, is in the right script,
/// and is not silently the English fallback — it cannot judge whether the Ukrainian one is
/// idiomatic. Translation quality is a review concern, not a test concern.
func ttsSampleTextFailures() -> [String] {
    var failures: [String] = []
    func check(_ label: String, _ ok: Bool) {
        if !ok { failures.append("TTSSampleText: \(label)") }
    }

    // Every voice the picker offers must preview in its own language.
    for voice in TTSVoiceRegistry.allVoices {
        let sample = TTSSampleText.sample(forVoiceID: voice.id)
        check("\(voice.id) has a non-empty sample", !sample.isEmpty)

        guard let language = TTSSampleText.language(forVoiceID: voice.id) else {
            failures.append("TTSSampleText: \(voice.id) resolves to no language")
            continue
        }
        // The whole point of the feature: a Greek voice must not preview in English.
        if language != "en" {
            check("\(voice.id) (\(language)) does not fall back to English",
                  sample != TTSSampleText.fallback)
        }
    }

    // Voice id -> language, both engines
    check("Kokoro af_heart is English", TTSSampleText.language(forVoiceID: "af_heart") == "en")
    // "heart" would otherwise read as Kokoro's h prefix — the Hindi sample.
    check("Pocket Heart is English, not Hindi", TTSSampleText.language(forVoiceID: "pocket:heart") == "en")
    check("Pocket Vera is English", TTSSampleText.language(forVoiceID: "pocket:vera") == "en")
    check("Kokoro bm_george is English", TTSSampleText.language(forVoiceID: "bm_george") == "en")
    check("Kokoro ff_siwis is French", TTSSampleText.language(forVoiceID: "ff_siwis") == "fr")
    check("Kokoro jf_alpha is Japanese", TTSSampleText.language(forVoiceID: "jf_alpha") == "ja")
    check("Kokoro zm_yunxi is Chinese", TTSSampleText.language(forVoiceID: "zm_yunxi") == "zh")
    check("Supertonic Greek resolves to el",
          TTSSampleText.language(forVoiceID: "supertonic:el:F1") == "el")
    check("Supertonic Dutch resolves to nl",
          TTSSampleText.language(forVoiceID: "supertonic:nl:M1") == "nl")

    // Distinct languages get distinct samples — catches a copy-paste in the table.
    let greek = TTSSampleText.sample(forVoiceID: "supertonic:el:F1")
    let dutch = TTSSampleText.sample(forVoiceID: "supertonic:nl:F1")
    check("Greek and Dutch samples differ", greek != dutch)
    check("Greek sample is in Greek script", greek.unicodeScalars.contains { $0.value >= 0x370 && $0.value <= 0x3FF })

    // Fallbacks: an unknown or malformed id must still preview rather than fail.
    check("unknown voice falls back", TTSSampleText.sample(forVoiceID: "qq_nobody") == TTSSampleText.fallback)
    check("empty id falls back", TTSSampleText.sample(forVoiceID: "") == TTSSampleText.fallback)
    check("unsupported supertonic language falls back",
          TTSSampleText.sample(forVoiceID: "supertonic:xx:F1") == TTSSampleText.fallback)

    return failures
}
