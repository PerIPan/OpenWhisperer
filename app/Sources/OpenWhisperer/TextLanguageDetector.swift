import Foundation
import NaturalLanguage
import OpenWhispererKit

/// On-device language identification for the text `speak` hands Supertonic, so the engine can
/// follow the language the model wrote rather than the one fused into the voice id. Apple's
/// `NLLanguageRecognizer` — no model download, no network. The decision (thresholds, code
/// normalization, "does Supertonic speak it") is `TTSLanguageFollow` in Kit, where it is tested.
enum TextLanguageDetector {
    /// Constrain the recognizer to what Supertonic can actually speak: fewer candidates means
    /// fewer confusions between close languages, and a language it can't use is no use to us.
    private static let constraints: [NLLanguage] =
        TTSVoiceRouter.supertonicLanguages.sorted().map { NLLanguage(rawValue: $0) }

    /// The recognizer's top hypothesis for `text`, or nil when it has none.
    static func guess(for text: String) -> TTSLanguageFollow.Guess? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else {
            return nil
        }
        return TTSLanguageFollow.Guess(language: language.rawValue, confidence: confidence)
    }

    /// The Supertonic language to synthesize `text` in for a voice whose own language is
    /// `voiceLanguage`.
    static func language(for text: String, voiceLanguage: String) -> String {
        TTSLanguageFollow.language(forVoiceLanguage: voiceLanguage, text: text, guess: guess(for: text))
    }
}
