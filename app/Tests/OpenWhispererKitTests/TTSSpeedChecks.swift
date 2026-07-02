import OpenWhispererKit

/// Checks for `TTSSpeed` — the clamp/parse used wherever the app reads the `tts_speed` pref
/// (TTSHTTPServer.userSpeed() + the `/v1/audio/play` and `speak` clamp sites). Bounds MUST
/// match the menubar Slider's `in:` range.
func ttsSpeedFailures() -> [String] {
    var failures: [String] = []

    func expect(_ raw: String?, _ expected: Float, _ name: String) {
        let r = TTSSpeed.parse(raw)
        if r != expected {
            failures.append("TTSSpeed.\(name): parse(\(raw.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    // Absent / empty / garbage → default.
    expect(nil, 1.0, "nilDefault")
    expect("", 1.0, "emptyDefault")
    expect("   \n", 1.0, "whitespaceDefault")
    expect("fast", 1.0, "garbageDefault")
    // In-range values pass through (whitespace trimmed).
    expect("1.15", 1.15, "inRange")
    expect("  0.90\n", 0.90, "trimsWhitespace")
    // Out-of-range clamps to the bounds.
    expect("9", 1.5, "clampHigh")
    expect("0.1", 0.7, "clampLow")
    // NaN parses as a Float but bypasses clamp (NaN comparisons are always false) → must default.
    expect("nan", 1.0, "nanDefault")
    expect("-nan", 1.0, "negNanDefault")

    // Constants are the agreed bounds.
    if TTSSpeed.min != 0.7 { failures.append("TTSSpeed.min: got \(TTSSpeed.min); expected 0.7") }
    if TTSSpeed.max != 1.5 { failures.append("TTSSpeed.max: got \(TTSSpeed.max); expected 1.5") }
    if TTSSpeed.default != 1.0 { failures.append("TTSSpeed.default: got \(TTSSpeed.default); expected 1.0") }

    return failures
}
