import Foundation

/// Which speech-to-text engine drives dictation. Selected by the `stt_engine`
/// flat file (see `Paths.sttEngine`), read per dictation so flipping the file
/// takes effect on the next recording — no restart, no rebuild.
///
/// This exists for the 2026-07-13 Parakeet feel-test (Turkish + macOS-14
/// constraints waived, see the engine-configurability spec addendum). It is a
/// deliberate two-value escape hatch, not a UI picker — PR #6 established that
/// a picker isn't worth its complexity here.
public enum STTEngine: String, CaseIterable, Sendable {
    case whisper
    case parakeet

    /// Feel-test default: Parakeet TDT v3. `echo whisper > stt_engine` reverts.
    public static let fallback: STTEngine = .parakeet

    /// Parse a raw pref-file string; unknown/empty/missing falls back to `fallback`.
    public static func parse(_ raw: String?) -> STTEngine {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return STTEngine(rawValue: trimmed) ?? fallback
    }
}
