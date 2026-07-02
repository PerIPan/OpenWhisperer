import Foundation

/// Clamp/parse for the global `tts_volume` preference (Kokoro playback gain).
/// Pure and dependency-free so it unit-tests under CLT; shared by every read
/// site so the bounds/default can't drift. Bounds MUST equal the menubar
/// Slider's `in:` range (see MenuBarView).
public enum TTSVolume {
    public static let min: Float = 0.3
    public static let max: Float = 2.0
    public static let `default`: Float = 1.0

    /// Clamp any gain into `[min, max]`.
    public static func clamp(_ v: Float) -> Float {
        Swift.min(Swift.max(v, min), max)
    }

    /// Parse a stored pref string. `nil`/empty/unparseable → `default`; valid
    /// numbers are clamped into range (so a legacy discrete "4" → `max`).
    public static func parse(_ raw: String?) -> Float {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, let v = Float(s), v.isFinite else { return `default` }
        return clamp(v)
    }
}
