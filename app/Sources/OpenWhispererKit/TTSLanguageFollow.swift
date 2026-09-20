import Foundation

/// Which language Supertonic should synthesize a piece of text in.
///
/// A Supertonic voice id fuses a language into itself (`supertonic:de:M1`), but the text the
/// model hands `speak` need not be in that language — the user may have asked for English, or
/// the conversation may simply be in English. Phonemizing English through the German front end
/// is unintelligible, so the engine follows the *text*: when an on-device language detector is
/// confident, and the detected language is one Supertonic speaks, that language wins over the
/// voice's own. Style (`M1`) is untouched, so the speaker sounds the same either way.
///
/// Pure and dependency-free so it unit-tests under Command Line Tools; the detector itself
/// (`NLLanguageRecognizer`) lives in the app target and feeds its top hypothesis in as a `Guess`.
public enum TTSLanguageFollow {
    /// A detector's best hypothesis for the language of some text.
    public struct Guess: Sendable, Equatable {
        /// The detector's tag, BCP-47-ish (`de`, `pt-BR`, `zh-Hans`). Case and region are
        /// normalized away here.
        public let language: String
        /// 0…1.
        public let confidence: Double

        public init(language: String, confidence: Double) {
            self.language = language
            self.confidence = confidence
        }
    }

    /// Below this the guess is ignored. Short or mixed text can score anywhere; a wrong switch
    /// (German voice suddenly phonemizing German as Dutch) is worse than no switch.
    public static let minimumConfidence = 0.6

    /// Fewer letters than this and detectors are guessing ("Ja.", "OK.", "Nein!") — keep the
    /// voice's language. Letters, not characters: digits and punctuation carry no language.
    public static let minimumLetters = 12

    /// The Supertonic language code to synthesize `text` in.
    public static func language(forVoiceLanguage voiceLanguage: String, text: String, guess: Guess?) -> String {
        guard let guess, guess.confidence >= minimumConfidence else { return voiceLanguage }
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= minimumLetters else {
            return voiceLanguage
        }
        let code = guess.language
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { $0.lowercased() } ?? ""
        guard TTSVoiceRouter.supertonicLanguages.contains(code) else { return voiceLanguage }
        return code
    }
}
