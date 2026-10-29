import Foundation

/// The text Pocket TTS is handed: what it reads right is left alone, what it measurably misreads is
/// rewritten. Deliberately **not** `NumberNormalizer` — that was written for Kokoro, and on Pocket
/// it would do harm: "2.0.8" would become "two point zero.eight", which Pocket reads correctly as
/// written.
///
/// Every rule here comes from a measurement (2026-10-29, Heart on the 100M model, read back through
/// WhisperKit turbo). Read **right** as written, so untouched: API, PR, CI, MCP, HTTP, TTS, ID, AI,
/// UI, UX, OS, IT, US, IO, ETA, CLI, SDK, GPU, CPU, DMG, TCC, OK, plurals (APIs, URLs), JSON, YAML,
/// README, GitHub, Xcode, macOS, iOS, "4.2", "340", "1,250", "12%", "2.0.8", and "7:30", "14:05",
/// "9:05 AM". Read **wrong**, so rewritten:
///
/// - `$5.99 a month` → heard "$5." — the rest of the sentence was **lost**. Now "5 dollars and 99 cents".
/// - `2:00 PM` → heard "2,000 p.m.". An on-the-hour time drops its ":00".
/// - `10-20` → heard "1020". A range of two numbers says "to".
/// - `WHO is it?` → heard "Oh is it?" (Estia found the same: "Though is it?"); "W-H-O" was right.
/// - `TODO` → heard "total"; "to-do" was right.
///
/// Then the pause guard (`paced`). Extend by measurement, not by guess: an all-caps word that reads
/// as an English word is the pattern to look for (WHO), not acronyms in general — Pocket reads those.
public enum PocketText {
    public static func spoken(_ text: String) -> String {
        paced(rewrite(oneLine(text)))
    }

    /// Smart apostrophes plain (the config also maps them; doing it here keeps the rules below
    /// simple) and one line — a newline is a paragraph to us but nothing to the program.
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func rewrite(_ text: String) -> String {
        var s = text
        // Ranges of times and of money first: the rules below would otherwise rewrite each side
        // and leave a hyphen between them ("9 o'clock-17 hundred", "10 dollars-20").
        s = replace(s, #"(?<![0-9:.])([0-9]{1,2}:[0-9]{2})\s?[-–]\s?([0-9]{1,2}:[0-9]{2})(?![0-9:])"#) { g in
            "\(g[1] ?? "") to \(g[2] ?? "")"
        }
        s = replace(s, #"\$([0-9]+)\s?[-–]\s?\$?([0-9]+)(?![0-9]|[.,][0-9]|\p{L})"#) { g in
            "\(g[1] ?? "") to \(g[2] ?? "") dollars"
        }
        // Money with a scale ("$1.5M", "$2.5k", "$3B"): the number as written, the scale as a word.
        s = replace(s, #"\$([0-9]+(?:\.[0-9]+)?)\s?([kKmMbB])(?![\p{L}0-9])"#) { g in
            let scale = ["k": "thousand", "m": "million", "b": "billion"][(g[2] ?? "").lowercased()] ?? ""
            return "\(g[1] ?? "") \(scale) dollars"
        }
        // Money. Digits stay digits (Pocket reads them), only the shape changes. Thousands groups
        // are matched exactly and the amount must end there, so a comma or full stop after it
        // ("$20, billed") stays prose, and "$5.999" or "$0.5" are left alone rather than mangled.
        s = replace(s, #"\$([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.([0-9]{2}))?(?![0-9]|[.,][0-9]|\p{L})"#) { g in
            let whole = g[1] ?? ""
            let units = Int(whole.replacingOccurrences(of: ",", with: "")) ?? 0
            var out = "\(whole) dollar" + (units == 1 ? "" : "s")
            if let cents = g[2], let c = Int(cents), c > 0 {
                out += " and \(c) cent" + (c == 1 ? "" : "s")
            }
            return out
        }
        // On-the-hour times. With am/pm the hour alone ("2 PM"); without, a 12-hour hour says
        // o'clock and a 24-hour one hundred ("14 hundred"), the way people say them.
        s = replace(s, #"(?<![0-9:.])([0-9]{1,2}):00(?![0-9:])(\s*(?:[AaPp]\.?\s?[Mm]\.?))?"#) { g in
            let hour = g[1] ?? ""
            if let suffix = g[2] { return hour + suffix }
            let h = Int(hour) ?? 0
            return h >= 13 || hour.hasPrefix("0") ? "\(hour) hundred" : "\(hour) o'clock"
        }
        // A range of exactly two numbers — including at a sentence's end or before a colon, where
        // most of them are: a full stop or colon only blocks it when a digit follows (a version, a
        // time). Dates (2026-10-29), versions (3.10-3.12), sequences (1-2-3) and names with digits
        // (x86-64, COVID-19) stay out; so do a year-month (2026-10) and a phone number (555-1234).
        s = replace(s, #"(?<![\p{L}0-9:/\-]|[0-9]\.)([0-9]{1,4})\s?[-–]\s?([0-9]{1,4})(?![\p{L}0-9/\-]|[.:][0-9])"#) { g in
            let a = g[1] ?? "", b = g[2] ?? ""
            if a.count == 4, b.count == 2, let month = Int(b), (1...12).contains(month) { return g[0] ?? "" }
            if a.count == 3, b.count == 4 { return g[0] ?? "" }
            return "\(a) to \(b)"
        }
        // All-caps words Pocket reads as a different English word.
        s = replace(s, #"(?<![\p{L}\p{N}])WHO(?![\p{L}\p{N}])"#) { _ in "W-H-O" }
        s = replace(s, #"(?<![\p{L}\p{N}])TODO(s?)(?![\p{L}\p{N}])"#) { g in "to-do" + (g[1] ?? "") }
        return s
    }

    // MARK: - Pause guard

    /// The longest stretch left without a pause mark, in characters. A long run of words with no
    /// comma can make the model "run away" — the clip goes on to the program's time budget with
    /// its end garbled, and the run still exits cleanly, so nothing reports it (Estia, 25 Oct, on
    /// the 18M model, from ~400 characters). The 100M model Heart runs on read an 85-word,
    /// 489-character stretch word for word here (2026-10-29), so this is a margin, not a measured
    /// edge: well under where the small model failed, well over any sentence a summary contains.
    public static let paceLimit = 300

    /// Words a break sounds natural before.
    static let breakWords: Set<String> = [
        "and", "but", "or", "so", "then", "because", "which", "while", "when", "where", "although",
        "though", "unless", "until", "after", "before", "since",
    ]

    /// `text` with a comma inserted into any stretch longer than `paceLimit`, before a conjunction
    /// near the stretch's middle when there is one, else at the nearest word break. Unchanged when
    /// no stretch is that long — every ordinary sentence comes back byte for byte.
    public static func paced(_ text: String) -> String {
        var out = ""
        var stretch = ""
        for ch in text {
            stretch.append(ch)
            if ",;:.!?…—–()".contains(ch) {
                out += split(stretch)
                stretch = ""
            }
        }
        return out + split(stretch)
    }

    /// One stretch (ending at a pause mark or the text's end), cut until every piece fits.
    static func split(_ stretch: String) -> String {
        guard stretch.count > paceLimit else { return stretch }
        let chars = Array(stretch)
        let middle = chars.count / 2
        // Candidate breaks: the index of each space; prefer one before a break word.
        var best: Int?
        var bestCost = Int.max
        for i in chars.indices where chars[i] == " " && i > 0 && i < chars.count - 1 {
            let next = String(chars[(i + 1)...].prefix { $0.isLetter }).lowercased()
            let cost = abs(i - middle) + (breakWords.contains(next) ? 0 : paceLimit / 4)
            if cost < bestCost { bestCost = cost; best = i }
        }
        guard let cut = best else { return stretch }  // one enormous word: nothing to do
        let head = String(chars[..<cut])
        let tail = String(chars[cut...])
        return split(head + ",") + split(tail)
    }

    // MARK: -

    /// Regex replace with the replacement computed from capture groups (`g[0]` the whole match,
    /// nil for a group that took no part). Foundation-only so it builds under Command Line Tools.
    static func replace(_ s: String, _ pattern: String, _ transform: ([String?]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups: [String?] = (0..<m.numberOfRanges).map {
                let r = m.range(at: $0)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
