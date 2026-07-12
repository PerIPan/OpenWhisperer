import Foundation
import OpenWhispererKit

/// Checks for the `stt_engine` pref parsing (engine escape hatch).
func sttEngineFailures() -> [String] {
    var failures: [String] = []

    func expect(_ raw: String?, _ want: STTEngine, _ label: String) {
        let got = STTEngine.parse(raw)
        if got != want {
            failures.append("STTEngine.parse(\(raw.map { "\"\($0)\"" } ?? "nil")) [\(label)]: got .\(got.rawValue), want .\(want.rawValue)")
        }
    }

    expect("whisper", .whisper, "exact whisper")
    expect("parakeet", .parakeet, "exact parakeet")
    expect("  whisper\n", .whisper, "whitespace trimmed")
    expect("Whisper", .whisper, "case-insensitive")
    expect("PARAKEET", .parakeet, "case-insensitive")
    expect(nil, STTEngine.fallback, "missing file → fallback")
    expect("", STTEngine.fallback, "empty file → fallback")
    expect("nemotron", STTEngine.fallback, "unknown value → fallback")

    return failures
}
