import Foundation

/// Clamp/parse for the global `tts_speed` preference (Kokoro playback rate).
/// Pure and dependency-free so it unit-tests under CLT; shared by every read
/// site so the bounds/default can't drift. Bounds MUST equal the menubar
/// Slider's `in:` range (see VoiceTab).
public enum TTSSpeed {
    public static let min: Float = 0.7
    public static let max: Float = 1.5
    /// Our default is a slightly brisk 1.1× (upstream ships 1.0×) — replies feel
    /// snappier without losing clarity. Slider still spans [min, max].
    public static let `default`: Float = 1.1

    /// Clamp any rate into `[min, max]`.
    public static func clamp(_ v: Float) -> Float {
        Swift.min(Swift.max(v, min), max)
    }

    /// Parse a stored pref string. `nil`/empty/unparseable → `default`; valid
    /// numbers are clamped into range.
    public static func parse(_ raw: String?) -> Float {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, let v = Float(s), v.isFinite else { return `default` }
        return clamp(v)
    }
}
