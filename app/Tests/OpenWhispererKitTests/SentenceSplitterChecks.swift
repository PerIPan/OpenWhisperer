import OpenWhispererKit

/// Checks for `SentenceSplitter.split` — chunking spoken text for pipelined TTS synthesis.
/// Returns a list of human-readable failures (empty = all passed).
func sentenceSplitterFailures() -> [String] {
    var failures: [String] = []

    func expect(_ input: String, _ expected: [String], _ name: String) {
        let r = SentenceSplitter.split(input)
        if r != expected {
            failures.append(
                "SentenceSplitter.\(name): split(\(input.debugDescription)) -> "
                + "\(r); expected \(expected)"
            )
        }
    }

    expect("", [], "empty")
    expect("   \n  ", [], "whitespaceOnly")
    expect("Fixed the login bug.", ["Fixed the login bug."], "single")
    expect(
        "Fixed the login bug. Deployed to staging. All tests pass.",
        ["Fixed the login bug.", "Deployed to staging.", "All tests pass."],
        "threeSentences")
    expect(
        "The release is v1.4.2 and it works.",
        ["The release is v1.4.2 and it works."],
        "versionNoSplit")
    expect("Pi is about 3.14 today.", ["Pi is about 3.14 today."], "decimalNoSplit")
    expect(
        "Check the docs, e.g. the README, for the details.",
        ["Check the docs, e.g. the README, for the details."],
        "abbrevNoSplit")
    expect(
        "Hi. I fixed the bug and shipped it.",
        ["Hi. I fixed the bug and shipped it."],
        "tinyLeadingFragmentMerge")
    expect(
        "First line here.\nSecond line follows.",
        ["First line here.", "Second line follows."],
        "newlineSplit")
    expect("Does it work? Yes it does!", ["Does it work?", "Yes it does!"], "questionExclaim")
    expect("no terminal punctuation here", ["no terminal punctuation here"], "noPunctuation")
    expect("  Leading and trailing spaces.  ", ["Leading and trailing spaces."], "trimmed")

    return failures
}
