import OpenWhispererKit

/// Behavioral parity checks for `SubmitTrigger.process`, mirroring the Python
/// `check_submit_trigger` (unified_server.py:134-147) + `_SUBMIT_PATTERNS`.
/// Returns a list of human-readable failures (empty = all passed).
func submitTriggerFailures() -> [String] {
    var failures: [String] = []

    func expect(_ input: String, cleaned: String, didMatch: Bool, _ name: String) {
        let r = SubmitTrigger.process(input)
        if r.cleaned != cleaned || r.didMatch != didMatch {
            failures.append(
                "SubmitTrigger.\(name): process(\(input.debugDescription)) -> "
                + "(\(r.cleaned.debugDescription), \(r.didMatch)); "
                + "expected (\(cleaned.debugDescription), \(didMatch))"
            )
        }
    }

    expect("type this and submit", cleaned: "type this and", didMatch: true, "stripsTrailingSubmit")
    expect("submit", cleaned: "", didMatch: true, "submitAlone")
    expect("draft the email send it", cleaned: "draft the email", didMatch: true, "multiWordSendIt")
    expect("let's go ahead", cleaned: "let's", didMatch: true, "goAhead")
    expect("enter", cleaned: "", didMatch: true, "enterAlone")
    expect("send", cleaned: "", didMatch: true, "sendAlone")
    expect("submit!", cleaned: "", didMatch: true, "trailingPunctuationSingleWord")
    expect("please send it.", cleaned: "please", didMatch: true, "trailingPunctuationMultiWord")
    expect("hello world", cleaned: "hello world", didMatch: false, "noTrigger")
    expect("I will send the file", cleaned: "I will send the file", didMatch: false, "midTextSend")
    expect("Type this SUBMIT", cleaned: "Type this", didMatch: true, "caseInsensitive")
    expect("send it", cleaned: "", didMatch: true, "longestTriggerWins")
    // Parity with the Python `rfind` fallback when `\b` defeats the regex.
    expect("presubmit", cleaned: "pre", didMatch: true, "wordBoundaryFallbackParity")
    expect("  hello there submit  ", cleaned: "hello there", didMatch: true, "whitespaceTrimmed")

    return failures
}
