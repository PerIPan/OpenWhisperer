import Foundation

/// Parses the user's dictation vocabulary (`stt_vocabulary`) and sizes it to a
/// prompt-token budget. Pure logic — file I/O and tokenization stay in the app
/// target (`SpeechTranscriber`), so this builds and tests fast under CLT.
public enum VocabularyPrompt {
    /// One term per line; lines are trimmed, blank lines and #-comments skipped.
    public static func terms(from text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// "a, b, c" — Whisper reads the prompt as preceding transcript, so a plain
    /// comma list biases decoding toward these spellings. Nil when empty.
    public static func promptText(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// How many leading terms fit `budget` tokens, where `tokenCounts[i]` is the
    /// encoded length of term i and `separatorCount` the encoded length of ", ".
    /// Keep-first by design: WhisperKit trims prompt tokens with `.suffix`, which
    /// would silently drop the FRONT of the list instead.
    public static func fittingPrefixCount(tokenCounts: [Int], separatorCount: Int, budget: Int) -> Int {
        var total = 0
        for (i, count) in tokenCounts.enumerated() {
            total += count + (i > 0 ? separatorCount : 0)
            if total > budget { return i }
        }
        return tokenCounts.count
    }
}
