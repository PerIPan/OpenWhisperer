import Foundation

/// Overlay analyzer style pref (`overlay_style` flat file). Same parse-with-default
/// shape as `TTSSpeed`: bad/missing input never breaks the overlay.
public enum OverlayStyle: String, CaseIterable {
    case wave                       // 1.6.0 mirrored-line waveform + status dot (the default)
    case ledBars = "led_bars"
    case graph
    case curtain

    public static let defaultStyle: OverlayStyle = .wave

    /// Trims and parses a raw pref-file string; anything unrecognized → default.
    public static func parse(_ raw: String?) -> OverlayStyle {
        guard let raw else { return defaultStyle }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return OverlayStyle(rawValue: trimmed) ?? defaultStyle
    }
}
