import OpenWhispererKit

/// Checks for `TTSVolume` — the clamp/parse shared by TTSPlaybackController.readVolume().
/// Bounds MUST match the menubar Slider's `in:` range.
func ttsVolumeFailures() -> [String] {
    var failures: [String] = []

    func expect(_ raw: String?, _ expected: Float, _ name: String) {
        let r = TTSVolume.parse(raw)
        if r != expected {
            failures.append("TTSVolume.\(name): parse(\(raw.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    // Absent / empty / garbage → default.
    expect(nil, 1.0, "nilDefault")
    expect("", 1.0, "emptyDefault")
    expect("   \n", 1.0, "whitespaceDefault")
    expect("loud", 1.0, "garbageDefault")
    // In-range values pass through (whitespace trimmed).
    expect("1.5", 1.5, "inRange")
    expect("  0.50\n", 0.50, "trimsWhitespace")
    // Out-of-range clamps to the bounds (legacy discrete "High" 4 → max, "Low" 0.3 = min).
    expect("4", 2.0, "clampHigh")
    expect("0.1", 0.3, "clampLow")
    // NaN parses as a Float but bypasses clamp (NaN comparisons are always false) → must default.
    expect("nan", 1.0, "nanDefault")
    expect("-nan", 1.0, "negNanDefault")

    // Constants are the agreed bounds.
    if TTSVolume.min != 0.3 { failures.append("TTSVolume.min: got \(TTSVolume.min); expected 0.3") }
    if TTSVolume.max != 2.0 { failures.append("TTSVolume.max: got \(TTSVolume.max); expected 2.0") }
    if TTSVolume.default != 1.0 { failures.append("TTSVolume.default: got \(TTSVolume.default); expected 1.0") }

    return failures
}
