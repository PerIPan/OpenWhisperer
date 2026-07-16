import Foundation

/// Pure Goertzel filterbank: reduces an audio buffer to `bandCount` normalized
/// band energies at log-spaced voice-range center frequencies. Pure Swift (no
/// Accelerate) so it stays CLT-testable; ~12 × N multiplies per call is trivial
/// at tap cadence.
public enum SpectrumBands {
    /// One shared analysis resolution for every overlay style (styles that render
    /// fewer columns reduce via `aggregate`). 96 log-spaced centers, 50 Hz … 7.5 kHz —
    /// the top center stays under the 16 kHz mic feed's 8 kHz Nyquist.
    public static let bandCount = 96
    public static let centerFrequencies: [Float] = {
        let lo: Float = 50, hi: Float = 7_500
        let ratio = pow(hi / lo, 1 / Float(bandCount - 1))
        return (0..<bandCount).map { lo * pow(ratio, Float($0)) }
    }()

    /// Max-pool `bands` down to `count` columns (e.g. 96 → 24 for LED bars).
    /// Group boundaries are proportional, so non-divisible counts distribute evenly.
    public static func aggregate(_ bands: [Float], into count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { i in
            let j0 = i * bands.count / count
            let j1 = max(j0 + 1, (i + 1) * bands.count / count)
            return bands[j0..<min(j1, bands.count)].max() ?? 0
        }
    }

    /// Normalized (0…1) energy per band, log-scaled so speech reads well.
    /// - parameter gainDb: Per-source loudness compensation (dB); default 0 for TTS playback, ~14 for mic input.
    public static func bands(samples: [Float], sampleRate: Float, gainDb: Float = 0) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else {
            return [Float](repeating: 0, count: bandCount)
        }
        let n = Float(samples.count)
        return centerFrequencies.map { freq in
            guard freq < sampleRate / 2 else { return 0 }
            // Goertzel at the band center.
            let k = round(n * freq / sampleRate)
            let w = 2 * Float.pi * k / n
            let coeff = 2 * cos(w)
            var s0: Float = 0, s1: Float = 0, s2: Float = 0
            for sample in samples {
                s0 = sample + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
            let magnitude = sqrt(max(power, 0)) / (n / 2)
            // Log scaling: -60 dBFS … 0 dBFS → 0 … 1.
            let db = 20 * log10(max(magnitude, 1e-9)) + gainDb
            return min(1, max(0, (db + 60) / 60))
        }
    }
}
