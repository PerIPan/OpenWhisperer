import Foundation

/// Splits spoken text (the markdown-stripped first paragraph, or whole reply in full mode) into sentence-sized
/// chunks for pipelined TTS synthesis: chunk 1 plays while chunk 2+ are still synthesizing.
///
/// Pure and deterministic with no `NaturalLanguage` dependency, so it builds and unit-tests under
/// Command Line Tools beside `SubmitTrigger` / `NumberNormalizer`. A wrong split only costs a tiny
/// extra synth call or a micro-gap — never wrong audio — so the boundary rules stay deliberately
/// simple: break on `.` / `!` / `?` followed by whitespace or end-of-text, and on newlines,
/// skipping decimals / version numbers (digit·digit) and a small set of abbreviations. Fragments
/// shorter than `minChunkChars` are folded into a neighbor so short replies don't over-fragment.
public enum SentenceSplitter {

    /// Trimmed chunks shorter than this are merged into an adjacent chunk.
    private static let minChunkChars = 5

    /// Lowercased trailing tokens (letters + dots) that must not end a sentence.
    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "dr.", "mr.", "mrs.", "ms.",
        "jr.", "sr.", "st.", "fig.", "no.", "vol.", "approx.",
    ]

    /// Break `text` into sentence chunks. Returns `[]` for blank input.
    public static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var chunks: [String] = []
        var buffer: [Character] = []

        func flush() {
            let s = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { chunks.append(s) }
            buffer.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                flush()
                i += 1
                continue
            }
            buffer.append(c)
            if c == "." || c == "!" || c == "?" {
                let atEnd = i + 1 >= chars.count
                let nextIsBoundary = atEnd || chars[i + 1].isWhitespace
                if nextIsBoundary, !isDecimalDot(chars, i), !endsWithAbbreviation(buffer) {
                    flush()
                }
            }
            i += 1
        }
        flush()

        return merged(chunks)
    }

    /// True when the `.` at `idx` sits between two digits (decimal or version number).
    private static func isDecimalDot(_ chars: [Character], _ idx: Int) -> Bool {
        guard chars[idx] == "." else { return false }
        let prev = idx - 1 >= 0 ? chars[idx - 1] : " "
        let next = idx + 1 < chars.count ? chars[idx + 1] : " "
        return prev.isNumber && next.isNumber
    }

    /// True when `buffer` (ending at the candidate punctuation) ends with a known abbreviation —
    /// e.g. the final dot of "e.g." or "Dr.".
    private static func endsWithAbbreviation(_ buffer: [Character]) -> Bool {
        var tail: [Character] = []
        var j = buffer.count - 1
        while j >= 0, buffer[j].isLetter || buffer[j] == "." {
            tail.insert(buffer[j], at: 0)
            j -= 1
        }
        return abbreviations.contains(String(tail).lowercased())
    }

    /// Fold chunks shorter than `minChunkChars` into a neighbor (previous, or the next when the
    /// short chunk leads).
    private static func merged(_ chunks: [String]) -> [String] {
        guard chunks.count > 1 else { return chunks }
        var out: [String] = []
        for chunk in chunks {
            if chunk.count < minChunkChars, let last = out.last {
                out[out.count - 1] = last + " " + chunk
            } else {
                out.append(chunk)
            }
        }
        if out.count > 1, out[0].count < minChunkChars {
            out[1] = out[0] + " " + out[1]
            out.removeFirst()
        }
        return out
    }
}
