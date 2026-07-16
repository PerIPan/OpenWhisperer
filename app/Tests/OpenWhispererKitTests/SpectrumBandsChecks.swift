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

    // gainDb lifts band values (mic-vs-playback loudness compensation).
    let boosted = SpectrumBands.bands(samples: sine440, sampleRate: 16_000, gainDb: 14)
    expect(boosted[expected] > lit[expected], "gainBoosts",
           "boosted \(boosted[expected]) vs \(lit[expected])")

    // 96-band layout (overlay analyzer styles, 2026-07-16 spec)
    expect(SpectrumBands.bandCount == 96, "bandCount96", "got \(SpectrumBands.bandCount)")
    expect(abs(SpectrumBands.centerFrequencies.first! - 50) < 0.5, "lo50", "got \(SpectrumBands.centerFrequencies.first!)")
    expect(abs(SpectrumBands.centerFrequencies.last! - 7_500) < 0.5, "hi7500", "got \(SpectrumBands.centerFrequencies.last!)")
    expect(SpectrumBands.centerFrequencies.last! < 8_000, "underMicNyquist", "top center must stay below 8 kHz")
    expect(zip(SpectrumBands.centerFrequencies, SpectrumBands.centerFrequencies.dropFirst()).allSatisfy { $0 < $1 },
           "monotonic", "centers must ascend")

    // aggregate: max-pooling reducer
    let agg = SpectrumBands.aggregate([0.1, 0.9, 0.2, 0.3, 0.8, 0.1], into: 3)
    expect(agg == [0.9, 0.3, 0.8], "aggregateMax", "got \(agg)")
    let remainder = SpectrumBands.aggregate([1, 2, 3, 4, 5], into: 2)
    expect(remainder == [2, 5], "aggregateRemainder", "got \(remainder)")
    expect(SpectrumBands.aggregate([], into: 4) == [0, 0, 0, 0], "aggregateEmpty", "empty input → zeros")
    expect(SpectrumBands.aggregate([1, 2], into: 0) == [], "aggregateZero", "count 0 → []")
    let identity = SpectrumBands.aggregate([0.5, 0.6], into: 2)
    expect(identity == [0.5, 0.6], "aggregateIdentity", "got \(identity)")

    return failures
}
