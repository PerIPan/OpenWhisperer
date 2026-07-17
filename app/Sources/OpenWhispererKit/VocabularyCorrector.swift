import Foundation

/// Post-transcription glossary correction for dictation transcripts.
///
/// The user maintains an optional glossary of words/phrases (`stt_vocabulary`);
/// every transcript is corrected against it before being typed into the target
/// app. Two tiers per term: **recase** (case-insensitive exact match adopts the
/// glossary casing) and **fuzzy** (Levenshtein within a length-scaled threshold,
/// terms under 4 chars excluded). Punctuation and spacing survive byte-for-byte;
/// an empty glossary makes the whole thing a no-op.
public enum VocabularyCorrector {
    public static let maxTerms = 200

    /// Split raw glossary text on commas and newlines, trim each piece, drop
    /// empties, dedupe case-insensitively keeping the FIRST casing, cap at
    /// `maxTerms`. nil (no file) parses to an empty glossary.
    public static func parseGlossary(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var seenKeys = Set<String>()
        var terms: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seenKeys.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxTerms { break }
        }
        return terms
    }

    /// Correct `text` against `glossary`. Terms are matched longest-first over
    /// word n-grams: windows of the term's own word count N (recase + fuzzy)
    /// and N+1 (fuzzy only — absorbs splits like "code x" -> "Codex"). A
    /// replacement consumes its window; consumed words can't match again.
    public static func apply(_ text: String, glossary: [String]) -> String {
        guard !text.isEmpty, !glossary.isEmpty else { return text }

        var tokens = tokenize(text)
        let wordPositions = tokens.indices.filter { tokens[$0].isWord }
        guard !wordPositions.isEmpty else { return text }

        // Per word position: true once a replacement consumed it.
        var consumed = [Bool](repeating: false, count: wordPositions.count)
        let allTermsLowered = Set(glossary.map { $0.lowercased() })

        /// The window's words joined with single spaces, lowercased — or nil when
        /// the window is invalid (out of range, contains a consumed word, or spans
        /// a non-whitespace separator).
        func candidate(at start: Int, size: Int) -> String? {
            let end = start + size
            guard end <= wordPositions.count else { return nil }
            for pos in start..<end where consumed[pos] { return nil }
            if size > 1 {
                for pos in start..<(end - 1) {
                    for i in (wordPositions[pos] + 1)..<wordPositions[pos + 1]
                    where !tokens[i].text.allSatisfy(\.isWhitespace) {
                        return nil
                    }
                }
            }
            return (start..<end).map { tokens[wordPositions[$0]].text }
                .joined(separator: " ").lowercased()
        }

        /// The original text spanned by the window, verbatim (words + internal separators).
        func originalText(at start: Int, size: Int) -> String {
            tokens[wordPositions[start]...wordPositions[start + size - 1]]
                .map(\.text).joined()
        }

        /// Replace the window with `term`: the first word token carries the term;
        /// the remaining word tokens and the separators between them are dropped.
        /// Every word token in the window is consumed.
        func replace(at start: Int, size: Int, with term: String) {
            let lo = wordPositions[start]
            let hi = wordPositions[start + size - 1]
            tokens[lo].text = term
            if hi > lo {
                for i in (lo + 1)...hi { tokens[i].text = "" }
            }
            for pos in start..<(start + size) { consumed[pos] = true }
        }

        // Longest terms first (word count, then character count) so multi-word
        // phrases win over their own sub-words.
        let orderedTerms = glossary.sorted { a, b in
            let (aw, bw) = (wordCount(a), wordCount(b))
            if aw != bw { return aw > bw }
            return a.count > b.count
        }

        for term in orderedTerms {
            let termWords = term.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !termWords.isEmpty else { continue }
            let n = termWords.count
            let target = termWords.joined(separator: " ").lowercased()

            // Recase tier (window size N): exact case-insensitive match whose
            // original text differs from the term adopts the term verbatim.
            var start = 0
            while start + n <= wordPositions.count {
                if candidate(at: start, size: n) == target,
                   originalText(at: start, size: n) != term {
                    replace(at: start, size: n, with: term)
                    start += n
                } else {
                    start += 1
                }
            }

            // Fuzzy tier: only for targets >= 4 chars; threshold scales with the
            // target's length. Distance is measured on geminate-collapsed strings
            // ("cocorro" -> "cocoro") — dictation noise doubles letters, and plain
            // Levenshtein would put the spec's canonical miss-hear ("cocorro" ->
            // Kokoro, collapsed distance 2) just past the 6-char threshold.
            guard target.count >= 4 else { continue }
            let threshold = target.count <= 5 ? 1 : (target.count <= 9 ? 2 : 3)
            let collapsedTarget = collapseRepeats(target)
            // Size N+1 before N so a split term ("code x") is absorbed whole
            // before the N window could fuzzy-grab its first half alone.
            for size in [n + 1, n] {
                var start = 0
                while start + size <= wordPositions.count {
                    guard let cand = candidate(at: start, size: size),
                          cand != target,
                          !allTermsLowered.contains(cand),  // never fuzzy-capture another term
                          levenshtein(collapseRepeats(cand), collapsedTarget, limit: threshold)
                              <= threshold
                    else {
                        start += 1
                        continue
                    }
                    replace(at: start, size: size, with: term)
                    start += size
                }
            }
        }

        return tokens.map(\.text).joined()
    }

    // MARK: - Internals

    private struct Token {
        var text: String
        let isWord: Bool
    }

    /// Tokenize preserving separators: runs of letters/digits/apostrophes are
    /// word tokens; every other run passes through untouched, so reassembly
    /// reproduces the input byte-for-byte when nothing matches.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}"
            if current.isEmpty || isWord == currentIsWord {
                current.append(ch)
            } else {
                tokens.append(Token(text: current, isWord: currentIsWord))
                current = String(ch)
            }
            currentIsWord = isWord
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord)) }
        return tokens
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).count
    }

    /// Collapse runs of the same character ("cocorro" -> "cocoro") before
    /// measuring distance, so geminate dictation noise doesn't count as an edit.
    private static func collapseRepeats(_ s: String) -> String {
        var out = ""
        var last: Character?
        for ch in s where ch != last {
            out.append(ch)
            last = ch
        }
        return out
    }

    /// Classic two-row DP Levenshtein, with an early exit returning `limit + 1`
    /// when the length difference alone already exceeds `limit`.
    private static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
