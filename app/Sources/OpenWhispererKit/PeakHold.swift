import Foundation

/// Per-band peak markers with a hold window then a constant-rate fall —
/// the classic analyzer "peak cap" physics. Pure state machine over
/// (bands, timestamp) so it stays CLT-testable; rendering owns the instance.
public struct PeakHold {
    private var peaks: [Float] = []
    private var heldAt: [Double] = []
    private let holdSeconds: Double
    private let fallPerSecond: Float

    public init(holdSeconds: Double = 0.5, fallPerSecond: Float = 1.5) {
        self.holdSeconds = holdSeconds
        self.fallPerSecond = fallPerSecond
    }

    /// Advance to `time` and fold in the live `bands`; returns current peak levels.
    public mutating func update(bands: [Float], at time: Double) -> [Float] {
        if peaks.count != bands.count {
            peaks = bands
            heldAt = [Double](repeating: time, count: bands.count)
            return peaks
        }
        for i in bands.indices {
            if bands[i] >= peaks[i] {
                peaks[i] = bands[i]
                heldAt[i] = time
            } else {
                let overdue = time - heldAt[i] - holdSeconds
                if overdue > 0 {
                    // Fall for the time elapsed past the hold window, then keep the
                    // fall continuous: advance heldAt so the next frame measures
                    // its overdue from now.
                    peaks[i] = max(bands[i], peaks[i] - fallPerSecond * Float(overdue))
                    heldAt[i] = time - holdSeconds
                }
            }
        }
        return peaks
    }
}
