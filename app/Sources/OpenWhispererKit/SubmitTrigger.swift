import Foundation

/// Detects and strips a trailing "submit" phrase from a transcript.
///
/// Faithful Swift port of the Python server's `SUBMIT_TRIGGERS` / `check_submit_trigger`
/// (unified_server.py:134-147) + `_SUBMIT_PATTERNS`. A trailing trigger phrase
/// ("submit", "send it", "go ahead", "send", "enter") is removed, and whether one was
/// found is reported so callers can decide whether to press Enter. Matching is
/// case-insensitive, tolerant of trailing punctuation, and tries the longest triggers
/// first.
public enum SubmitTrigger {

    /// Longest-first, mirroring Python `sorted(..., key=len, reverse=True)`:
    /// "go ahead", "send it", "submit", "enter", "send".
    static let triggers: [String] = ["submit", "send it", "go ahead", "send", "enter"]
        .sorted { $0.count > $1.count }

    /// Trailing characters stripped before the `endsWith` pre-check
    /// (Python `lower.rstrip(" .,!?…")`).
    private static let trailingStripChars: Set<Character> = [" ", ".", ",", "!", "?", "…"]

    public static func process(_ text: String) -> (cleaned: String, didMatch: Bool) {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = rstrip(stripped.lowercased(), of: trailingStripChars)

        for trigger in triggers {
            guard lower.hasSuffix(trigger) else { continue }

            // Primary: regex removal of the trailing trigger (+ punctuation), anchored at end.
            let cleaned = regexStrip(trigger, from: stripped)
            if cleaned != stripped {
                return (rstripWhitespace(cleaned), true)
            }

            // Fallback (Python `lower.rfind(trigger)`): the `\b` boundary can defeat the
            // regex (e.g. "presubmit") even though the text ends with the trigger — strip
            // from the last case-insensitive occurrence.
            if let range = stripped.range(of: trigger, options: [.backwards, .caseInsensitive]) {
                return (rstripWhitespace(String(stripped[..<range.lowerBound])), true)
            }
        }
        return (text, false)
    }

    // MARK: - Helpers

    private static func rstrip(_ s: String, of chars: Set<Character>) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if chars.contains(s[prev]) { end = prev } else { break }
        }
        return String(s[..<end])
    }

    /// Python `str.rstrip()` — strip trailing whitespace only.
    private static func rstripWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace { end = prev } else { break }
        }
        return String(s[..<end])
    }

    /// Mirrors `_SUBMIT_PATTERNS[trigger].sub('', stripped)`: removes a trailing trigger
    /// plus any trailing punctuation, anchored at end, case-insensitive. Multi-word
    /// triggers use `\s*…[.!?,…]*$`; single words add a leading `\b`.
    private static func regexStrip(_ trigger: String, from stripped: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        let pattern = trigger.contains(" ")
            ? "\\s*\(escaped)[.!?,…]*$"
            : "\\s*\\b\(escaped)[.!?,…]*$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return stripped
        }
        let ns = stripped as NSString
        return re.stringByReplacingMatches(
            in: stripped,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }
}
