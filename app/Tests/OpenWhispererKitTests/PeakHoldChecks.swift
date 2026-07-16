import Foundation
import OpenWhispererKit

/// Checks for `PeakHold` — per-band peak markers with hold + gravity fall
/// (LED bar caps, graph peak line).
func peakHoldFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("PeakHold.\(name): \(detail)") }
    }

    var hold = PeakHold(holdSeconds: 0.5, fallPerSecond: 1.0)

    // Rising band sets the peak immediately.
    var peaks = hold.update(bands: [0.8, 0.2], at: 0)
    expect(peaks == [0.8, 0.2], "rise", "got \(peaks)")

    // Within the hold window the peak stays even though the band dropped.
    peaks = hold.update(bands: [0.1, 0.1], at: 0.3)
    expect(peaks[0] == 0.8, "holds", "got \(peaks[0])")

    // After the hold window the peak falls at fallPerSecond.
    peaks = hold.update(bands: [0.1, 0.1], at: 0.7)   // 0.2 s past hold → fell ~0.2
    expect(abs(peaks[0] - 0.6) < 0.011, "falls", "got \(peaks[0])")

    // The peak never falls below the live band.
    peaks = hold.update(bands: [0.55, 0.1], at: 0.8)
    expect(peaks[0] == 0.55, "floorsAtBand", "got \(peaks[0])")

    // A new maximum re-arms the hold.
    peaks = hold.update(bands: [0.9, 0.1], at: 1.0)
    expect(peaks[0] == 0.9, "rearm", "got \(peaks[0])")
    peaks = hold.update(bands: [0.0, 0.0], at: 1.4)
    expect(peaks[0] == 0.9, "rearmHolds", "got \(peaks[0])")

    // Band-count changes (style switch mid-flight) reset cleanly.
    peaks = hold.update(bands: [0.3], at: 2.0)
    expect(peaks == [0.3], "resize", "got \(peaks)")

    return failures
}
