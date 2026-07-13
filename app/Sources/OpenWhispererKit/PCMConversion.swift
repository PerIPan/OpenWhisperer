import Foundation

/// Converts 16-bit signed PCM samples to normalized Float32 in [-1, 1),
/// the format the STT model expects (16 kHz mono Float array).
public enum PCMConversion {
    /// Divides by 32768 so Int16.min (-32768) maps to exactly -1.0 and the
    /// positive range approaches (but never reaches) +1.0.
    public static func normalizeInt16(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768.0 }
    }
}
