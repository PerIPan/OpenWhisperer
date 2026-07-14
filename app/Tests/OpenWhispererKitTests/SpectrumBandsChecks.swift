import Foundation
import OpenWhispererKit

/// Checks for `SpectrumBands` — the pure Goertzel filterbank behind the overlay's
/// segmented spectrum display.
func spectrumBandsFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("SpectrumBands.\(name): \(detail)") }
    }

    // Silence → all bands (near) zero.
    let silence = [Float](repeating: 0, count: 2048)
    let quiet = SpectrumBands.bands(samples: silence, sampleRate: 16_000)
    expect(quiet.count == SpectrumBands.bandCount, "count", "got \(quiet.count)")
    expect(quiet.allSatisfy { $0 <= 0.01 }, "silence", "got \(quiet)")

    // A 440 Hz sine lights the band whose range contains 440 Hz more than any other.
    let sine440: [Float] = (0..<2048).map { i in
        sin(2 * .pi * 440 * Float(i) / 16_000) * 0.5
    }
    let lit = SpectrumBands.bands(samples: sine440, sampleRate: 16_000)
    let expected = SpectrumBands.centerFrequencies.enumerated().min(by: {
        abs($0.element - 440) < abs($1.element - 440)
    })!.offset
    let actual = lit.enumerated().max(by: { $0.element < $1.element })!.offset
    expect(actual == expected, "sine440Band", "peak in band \(actual), expected \(expected); bands \(lit)")

    // Everything normalized 0…1.
    expect(lit.allSatisfy { $0 >= 0 && $0 <= 1 }, "normalized", "got \(lit)")

    // Empty input → all zeros, no crash.
    let empty = SpectrumBands.bands(samples: [], sampleRate: 16_000)
    expect(empty.count == SpectrumBands.bandCount && empty.allSatisfy { $0 == 0 }, "empty", "got \(empty)")

    return failures
}
