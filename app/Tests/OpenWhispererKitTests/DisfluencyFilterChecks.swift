import Foundation
import OpenWhispererKit

/// Checks for `DisfluencyFilter` — the post-transcription filler-word stripper
/// (um/uh-class tokens, comma cleanup, capitalization transfer).
func disfluencyFilterFailures() -> [String] {
    var failures: [String] = []
    func check(_ input: String, _ expected: String, _ name: String) {
        let got = DisfluencyFilter.apply(input)
        if got != expected {
            failures.append("DisfluencyFilter.\(name): got \"\(got)\"")
        }
    }

    // Capitalization transfer: a capitalized leading filler carries the
    // sentence's capital; stripping it promotes the next word.
    check("Um, so I think it works", "So I think it works", "leadingCapitalTransfer")
    // Transfer is idempotent when the next word is already capitalized.
    check("Um, I think so", "I think so", "transferOntoI")
    check("Um, Kokoro breaks", "Kokoro breaks", "transferOntoProperNoun")
    // A filler flanked by commas takes both pause-commas with it.
    check("and then, um, it fails", "and then it fails", "flankedCommas")
    // Filler with only a trailing comma.
    check("so um, yeah", "so yeah", "trailingCommaOnly")
    // Bare filler, no punctuation.
    check("the situation with uh I don't know", "the situation with I don't know", "bareFiller")
    // A chain of fillers collapses; the first carried the capital.
    check("Um, uh, so yes", "So yes", "fillerChain")
    // A filler-only utterance vanishes entirely.
    check("Um.", "", "fillerOnlyUtterance")
    // Sentence-final filler hands its terminal punctuation back, replacing
    // the stranded comma.
    check("I think, um.", "I think.", "terminalPunctuation")
    // Mid-text sentence start still transfers the capital.
    check("It fails. Um, then it works.", "It fails. Then it works.", "midTextSentenceStart")
    // An uppercase filler mid-sentence must NOT capitalize the next word.
    check("so UM yeah", "so yeah", "midSentenceCapsNoTransfer")
    // Whole-token matching: words merely containing a filler survive.
    check("the umbrella is uh here", "the umbrella is here", "wordBoundary")
    // "uh-huh" is an answer, not a filler.
    check("uh-huh, sounds good", "uh-huh, sounds good", "uhHuhKept")
    // Variant spellings.
    check("Erm, uhm, right", "Right", "variantSpellings")
    // No fillers -> input passes through untouched.
    check("nothing to see here.", "nothing to see here.", "noOp")
    check("", "", "emptyInput")

    return failures
}
