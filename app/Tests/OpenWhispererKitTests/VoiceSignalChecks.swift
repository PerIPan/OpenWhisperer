import OpenWhispererKit

/// Checks for `VoiceSignal`. Parity-critical: these hashes MUST equal what
/// `shasum -a 256` produces for the same trimmed bytes (see the former tests/test_voice_context.py).
func voiceSignalFailures() -> [String] {
    var failures: [String] = []

    func expectHash(_ input: String, _ expected: String, _ name: String) {
        let r = VoiceSignal.canonicalHash(input)
        if r != expected {
            failures.append("VoiceSignal.\(name): canonicalHash(\(input.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    // Known SHA-256 vectors (verify: `printf '%s' 'hello' | shasum -a 256`).
    expectHash("hello", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "knownVectorHello")
    // Surrounding whitespace/newlines must not change the hash.
    expectHash("  hello\n", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "trimsWhitespace")
    // Empty after trim → SHA-256 of "".
    expectHash("   \n  ", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "emptyAfterTrim")

    // signalContents formatting.
    let body = VoiceSignal.signalContents(hash: "abc", timestamp: 1700000000)
    if body != "abc\n1700000000\n" {
        failures.append("VoiceSignal.signalContents: got \(body.debugDescription); expected \"abc\\n1700000000\\n\"")
    }

    return failures
}
