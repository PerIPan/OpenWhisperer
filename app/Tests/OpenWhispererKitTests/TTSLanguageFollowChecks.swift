import Foundation
import OpenWhispererKit

/// `TTSLanguageFollow` decides which Supertonic language a piece of text is synthesized in:
/// the language the text is written in when a detector is confident, else the voice's own.
/// The detector itself (NaturalLanguage) lives in the app target; this is the pure decision.
func ttsLanguageFollowFailures() -> [String] {
    var failures: [String] = []

    func expect(_ voice: String, _ text: String, _ guess: TTSLanguageFollow.Guess?, _ want: String, _ label: String) {
        let got = TTSLanguageFollow.language(forVoiceLanguage: voice, text: text, guess: guess)
        if got != want {
            failures.append("TTSLanguageFollow [\(label)]: expected \(want), got \(got)")
        }
    }
    let english = "I'll be there in ten minutes, don't worry about it."
    let german = "Ich bin in zehn Minuten da, mach dir keine Sorgen."

    // The bug this exists to fix: a German voice handed English text used to phonemize it as
    // German. A confident English guess routes the sentence through Supertonic's English.
    expect("de", english, .init(language: "en", confidence: 0.95), "en", "german voice, english text")
    // The voice's own language stays the voice's own language.
    expect("de", german, .init(language: "de", confidence: 0.98), "de", "german voice, german text")
    // No guess at all → the voice's language, never a crash or an empty code.
    expect("de", english, nil, "de", "no guess")
    // A shaky guess is not worth switching on.
    expect("de", english, .init(language: "en", confidence: 0.4), "de", "low confidence")
    // Short text ("Ja.", "OK.") is where detectors are least reliable — keep the voice's language.
    expect("de", "Ja.", .init(language: "en", confidence: 0.9), "de", "too short to trust")
    // A detected language Supertonic can't speak keeps the voice's language (no Mandarin).
    expect("de", "这是一个足够长的中文句子来测试。", .init(language: "zh-Hans", confidence: 0.99), "de", "unsupported detected")
    // Detector tags carry regions and case; Supertonic wants the bare lowercase code.
    expect("nl", "Eu vou estar lá em dez minutos, não se preocupe.", .init(language: "pt-BR", confidence: 0.9), "pt", "region subtag stripped")
    expect("nl", german, .init(language: "DE", confidence: 0.9), "de", "uppercase tag")
    // Letters, not characters, decide "too short": punctuation and digits don't count.
    expect("de", "12345 !!! ... ???", .init(language: "en", confidence: 0.9), "de", "digits and punctuation aren't letters")

    return failures
}
