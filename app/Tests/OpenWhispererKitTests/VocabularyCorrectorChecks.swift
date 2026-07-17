import Foundation
import OpenWhispererKit

/// Checks for `VocabularyCorrector` — the custom-vocabulary glossary parser and
/// fuzzy post-transcription corrector (recase + Levenshtein tiers).
func vocabularyCorrectorFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("VocabularyCorrector.\(name): \(detail)") }
    }

    // parseGlossary: split on commas + newlines, trim, drop empties,
    // dedupe case-insensitively keeping the first casing.
    let parsed = VocabularyCorrector.parseGlossary("Kokoro, Codex\nAnthropic , ,kokoro")
    expect(parsed == ["Kokoro", "Codex", "Anthropic"], "parseSplitTrimDedupe", "got \(parsed)")
    expect(VocabularyCorrector.parseGlossary(nil).isEmpty, "parseNil",
           "got \(VocabularyCorrector.parseGlossary(nil))")
    let oversized = (1...201).map { "term\($0)" }.joined(separator: ",")
    let capped = VocabularyCorrector.parseGlossary(oversized)
    expect(capped.count == VocabularyCorrector.maxTerms, "parseCap", "got \(capped.count)")

    func check(_ input: String, _ glossary: [String], _ expected: String, _ name: String) {
        let got = VocabularyCorrector.apply(input, glossary: glossary)
        expect(got == expected, name, "got \"\(got)\"")
    }

    // Recase tier: case-insensitive exact match adopts the glossary casing.
    check("open codex now", ["Codex"], "open Codex now", "recase")
    // Fuzzy hit: "cocorro" ~ "kokoro" (length 6 -> threshold 2, geminate collapsed).
    check("the cocorro voice", ["Kokoro"], "the Kokoro voice", "fuzzyHit")
    // Principled miss: nothing is within threshold 1 of "test".
    check("six one two three", ["test"], "six one two three", "principledMiss")
    // Split absorption: the N+1 window rejoins "code x" -> "Codex".
    check("open code x now", ["Codex"], "open Codex now", "splitAbsorption")
    // Multi-word term recase.
    check("open whisperer is great", ["Open Whisperer"], "Open Whisperer is great", "multiWordTerm")
    // Short-term protection: recase fires, but no fuzzy for targets under 4 chars.
    check("pi in the sky", ["Pi"], "Pi in the sky", "shortTermRecase")
    check("pa in the sky", ["Pi"], "pa in the sky", "shortTermNoFuzzy")
    // Cross-term guard: each recased, neither fuzzy-captured by the other.
    check("codex and kokoro", ["Codex", "Kokoro"], "Codex and Kokoro", "crossTermGuard")
    // Punctuation and spacing survive byte-for-byte.
    check("run codex, then kokoro!", ["Codex", "Kokoro"], "run Codex, then Kokoro!", "punctuation")
    // Empty glossary is a no-op.
    check("anything", [], "anything", "emptyNoOp")

    return failures
}
