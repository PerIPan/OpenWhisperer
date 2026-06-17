import Foundation

/// Expands numerics to spoken-form words *before* g2p, sidestepping the TTS
/// engine's weak number handling (FluidAudio Kokoro mangles `$5.99` → "X X").
/// Pure, dependency-free, unit-tested in isolation.
public enum NumberNormalizer {

    /// Returns `text` with money / percent / decimals / integers expanded to words.
    /// Non-numeric text is returned unchanged.
    public static func normalize(_ text: String) -> String {
        var s = text
        // Order matters: money first (it owns the `$` + decimal), then percent,
        // then bare decimals, then any remaining standalone integers.
        s = replace(s, #"\$([0-9][0-9,]*)(?:\.([0-9]{2}))?"#) { g in
            let dollars = intOf(g[1])
            let cents = g.count > 2 ? intOf(g[2]) : 0
            var out = cardinal(dollars) + " dollar" + (dollars == 1 ? "" : "s")
            if cents > 0 { out += " and " + cardinal(cents) + " cent" + (cents == 1 ? "" : "s") }
            return out
        }
        s = replace(s, #"([0-9][0-9,]*)%"#) { g in cardinal(intOf(g[1])) + " percent" }
        s = replace(s, #"([0-9]+)\.([0-9]+)"#) { g in
            let frac = g[2].compactMap { Int(String($0)) }.map { ones[$0] }.joined(separator: " ")
            return cardinal(intOf(g[1])) + " point " + frac
        }
        s = replace(s, #"[0-9][0-9,]*"#) { g in cardinal(intOf(g[0])) }
        return s
    }

    // MARK: - Number words

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    private static func cardinal(_ n: Int) -> String {
        if n < 0 { return "minus " + cardinal(-n) }
        if n < 20 { return ones[n] }
        if n < 100 { let o = n % 10; return o == 0 ? tens[n / 10] : tens[n / 10] + " " + ones[o] }
        if n < 1000 { let r = n % 100; return r == 0 ? ones[n / 100] + " hundred" : ones[n / 100] + " hundred " + cardinal(r) }
        if n < 1_000_000 { let r = n % 1000; return r == 0 ? cardinal(n / 1000) + " thousand" : cardinal(n / 1000) + " thousand " + cardinal(r) }
        return String(n)  // beyond range: leave as digits
    }

    private static func intOf(_ s: String) -> Int {
        Int(s.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    /// Regex replace where the replacement is computed from the match's capture groups
    /// (`g[0]` = whole match). Uses Foundation so it builds under Command Line Tools.
    private static func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }
}
