import Foundation

/// Strips filler words (um/uh-class disfluencies) from dictation transcripts.
///
/// Parakeet transcribes literally, fillers included. This pass removes them
/// after transcription, cleans up the pause-commas they strand, and — because
/// Parakeet capitalizes properly — transfers a stripped sentence-initial
/// filler's capital letter onto the next word. The filler's own casing is the
/// sentence-start signal: a capitalized filler mid-sentence (rare, e.g. "UM")
/// only transfers when it follows terminal punctuation or opens the text.
public enum DisfluencyFilter {
    /// Whole-token, case-insensitive matches. Conservative on purpose:
    /// "er"/"ah"/"hmm" can be real words or deliberate; "uh-huh" is an answer.
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm"]

    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "…"]

    public static func apply(_ text: String) -> String {
        let chunks = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard chunks.contains(where: { fillerTrailing($0) != nil }) else { return text }

        var out: [String] = []
        var pendingCapital = false
        for chunk in chunks {
            guard let trailing = fillerTrailing(chunk) else {
                var word = chunk
                if pendingCapital, let i = word.firstIndex(where: \.isLetter) {
                    word.replaceSubrange(i...i, with: word[i].uppercased())
                    pendingCapital = false
                }
                out.append(word)
                continue
            }
            if chunk.first?.isUppercase == true, out.isEmpty || endsSentence(out[out.count - 1]) {
                pendingCapital = true
            }
            if trailing == "," {
                // A comma-trailed filler also flanked by a comma takes both
                // pause-commas with it ("then, um, it" -> "then it").
                if let last = out.last, last.hasSuffix(",") {
                    out[out.count - 1] = String(last.dropLast())
                }
            } else if !trailing.isEmpty {
                // Sentence-final filler: its terminal punctuation belongs to the
                // sentence, so it replaces a stranded comma on the previous word.
                if var last = out.last {
                    if last.hasSuffix(",") { last.removeLast() }
                    if !endsSentence(last) { last += trailing }
                    out[out.count - 1] = last
                }
            }
        }
        return out.joined(separator: " ")
    }

    /// If `chunk` is a filler token, its trailing punctuation ("" / "," / a
    /// terminal run); nil otherwise. Any other adjacent character — a hyphen
    /// ("uh-huh"), a quote, a semicolon — disqualifies the chunk, keeping the
    /// match conservative.
    private static func fillerTrailing(_ chunk: String) -> String? {
        let letters = chunk.prefix(while: \.isLetter)
        guard fillers.contains(letters.lowercased()) else { return nil }
        let trailing = chunk[letters.endIndex...]
        guard trailing.isEmpty
            || trailing == ","
            || trailing.allSatisfy({ terminalPunctuation.contains($0) })
        else { return nil }
        return String(trailing)
    }

    private static func endsSentence(_ s: String) -> Bool {
        s.last.map(terminalPunctuation.contains) == true
    }
}
