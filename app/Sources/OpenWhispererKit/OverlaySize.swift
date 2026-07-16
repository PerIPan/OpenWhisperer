import Foundation

/// Parse/clamp/format for the overlay's persisted window size pref
/// (`overlay_size`, "220x84"). Same parse-with-default shape as `TTSSpeed`
/// and `OverlayStyle`: bad/missing input never breaks the overlay.
public struct OverlaySize: Equatable {
    public static let minWidth: Double = 180, minHeight: Double = 64
    public static let maxWidth: Double = 1_600, maxHeight: Double = 1_000
    public static let defaultSize = OverlaySize(width: 220, height: 84)

    public let width: Double
    public let height: Double

    /// Dimensions are clamped independently to the min/max bounds.
    public init(width: Double, height: Double) {
        self.width = min(max(width, Self.minWidth), Self.maxWidth)
        self.height = min(max(height, Self.minHeight), Self.maxHeight)
    }

    /// Trims and parses a "WxH" pref-file string; anything unrecognized → default.
    public static func parse(_ raw: String?) -> OverlaySize {
        guard let raw else { return defaultSize }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else {
            return defaultSize
        }
        return OverlaySize(width: w, height: h)
    }

    /// The canonical pref-file representation.
    public var fileValue: String { "\(Int(width))x\(Int(height))" }
}
