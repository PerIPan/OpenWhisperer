import OpenWhispererKit

/// Checks for `VocabularyPrompt` — glossary parsing + prompt-token budgeting
/// for the WhisperKit promptTokens accuracy lever.
/// Returns a list of human-readable failures (empty = all passed).
func vocabularyPromptFailures() -> [String] {
    var failures: [String] = []

    func expectTerms(_ input: String, _ expected: [String], _ name: String) {
        let r = VocabularyPrompt.terms(from: input)
        if r != expected {
            failures.append(
                "VocabularyPrompt.\(name): terms(\(input.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    func expectPrompt(_ terms: [String], _ expected: String?, _ name: String) {
        let r = VocabularyPrompt.promptText(terms)
        if r != expected {
            failures.append(
                "VocabularyPrompt.\(name): promptText(\(terms)) -> "
                + "\(String(describing: r)); expected \(String(describing: expected))")
        }
    }

    func expectCount(_ counts: [Int], _ sep: Int, _ budget: Int, _ expected: Int, _ name: String) {
        let r = VocabularyPrompt.fittingPrefixCount(tokenCounts: counts, separatorCount: sep, budget: budget)
        if r != expected {
            failures.append(
                "VocabularyPrompt.\(name): fittingPrefixCount(\(counts), sep: \(sep), "
                + "budget: \(budget)) -> \(r); expected \(expected)")
        }
    }

    // terms(from:)
    expectTerms("WhisperKit\nCodex CLI\nKokoro", ["WhisperKit", "Codex CLI", "Kokoro"], "basicLines")
    expectTerms("  WhisperKit  \n\tKokoro\t", ["WhisperKit", "Kokoro"], "trimsWhitespace")
    expectTerms("WhisperKit\n\n\nKokoro", ["WhisperKit", "Kokoro"], "skipsBlankLines")
    expectTerms("# comment\nWhisperKit\n  # indented\nKokoro", ["WhisperKit", "Kokoro"], "skipsComments")
    expectTerms("WhisperKit\r\nCodex CLI\r\n", ["WhisperKit", "Codex CLI"], "handlesCRLF")
    expectTerms("", [], "emptyInput")
    expectTerms("# only\n# comments\n   \n", [], "onlyCommentsAndBlanks")
    expectTerms("Codex CLI", ["Codex CLI"], "keepsInnerSpaces")

    // promptText(_:)
    expectPrompt(["WhisperKit", "Codex CLI", "Kokoro"], "WhisperKit, Codex CLI, Kokoro", "joinsWithCommas")
    expectPrompt(["WhisperKit"], "WhisperKit", "singleTerm")
    expectPrompt([], nil, "emptyIsNil")

    // fittingPrefixCount(tokenCounts:separatorCount:budget:)
    expectCount([3, 3, 3], 1, 100, 3, "allFit")
    expectCount([3, 3, 3], 1, 7, 2, "partialFit")       // 3, then 3+1+3=7 fits, then 11 > 7
    expectCount([3, 3, 3], 1, 6, 1, "separatorCounts")  // 3 fits; 3+1+3=7 > 6
    expectCount([3, 3], 1, 0, 0, "zeroBudget")
    expectCount([120], 1, 96, 0, "firstTermOverBudget")
    expectCount([3, 4], 1, 8, 2, "exactFit")            // 3 + 1 + 4 = 8
    expectCount([], 1, 96, 0, "noTerms")

    return failures
}
